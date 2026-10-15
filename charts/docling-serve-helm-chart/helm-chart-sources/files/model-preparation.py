#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements. See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Prepare and verify immutable Docling bundles on a POSIX model volume."""

import argparse
import contextlib
import fcntl
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
import time
import uuid


class InvalidModel(ValueError):
    """An incomplete, inconsistent or corrupt model inventory."""


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def safe_path(root, name):
    relative = PurePosixPath(name)
    if (not name or relative.is_absolute() or ".." in relative.parts
            or "\\" in name or relative == PurePosixPath(".")):
        raise InvalidModel("Model inventory contains an unsafe relative path")
    result = root.joinpath(*relative.parts)
    for part in (result, *result.parents):
        if part == root.parent:
            break
        if part.is_symlink():
            raise InvalidModel("Model inventory contains a symbolic link")
    return result


def model_name(spec):
    if "repo" in spec:
        if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", spec["repo"]):
            raise InvalidModel("Invalid model repository")
        if not re.fullmatch(r"[a-f0-9]{40}", spec.get("revision", "")):
            raise InvalidModel("A model repository must use an immutable commit")
        return spec["repo"].replace("/", "--")
    name = spec.get("directory", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        raise InvalidModel("Invalid bundled model directory")
    return name


def load_config(path):
    raw = path.read_text().strip()
    config = json.loads(raw)
    if config.get("formatVersion") != 1 or not config.get("repositories"):
        raise InvalidModel("The model inventory must select at least one model")
    names = [model_name(spec) for spec in config["repositories"]]
    if len(names) != len(set(names)):
        raise InvalidModel("The model inventory repeats a model directory")
    for spec in config["repositories"]:
        if not spec.get("requiredFiles"):
            raise InvalidModel("Each model needs an explicit required-file inventory")
    return config, hashlib.sha256(raw.encode()).hexdigest()


def validate_model(directory, spec):
    if not directory.is_dir() or directory.is_symlink():
        raise InvalidModel("Missing model directory: " + directory.name)
    for name in spec["requiredFiles"]:
        path = safe_path(directory, name)
        if not path.is_file() or not path.stat().st_size:
            raise InvalidModel("Missing or empty model file: " + name)
        if name.endswith(".index.json"):
            index = json.loads(path.read_text())
            shards = set(index.get("weight_map", {}).values())
            if not shards:
                raise InvalidModel("Model weight index has no shards")
            for shard in shards:
                target = safe_path(directory, shard)
                if not target.is_file() or not target.stat().st_size:
                    raise InvalidModel("Missing or empty weight shard: " + shard)
    for name, expected in spec.get("sha256", {}).items():
        path = safe_path(directory, name)
        if not re.fullmatch(r"[a-f0-9]{64}", expected):
            raise InvalidModel("Invalid expected model checksum")
        if not path.is_file() or digest(path) != expected:
            raise InvalidModel("Model checksum mismatch: " + name)
    weights = [p for p in directory.rglob("*")
               if p.suffix in {".safetensors", ".bin", ".onnx", ".pth", ".pt"}
               and p.is_file() and not p.is_symlink() and p.stat().st_size]
    if not weights:
        raise InvalidModel("A model directory must contain weights, not just configuration")


def selected_files(root, config):
    files = {}
    for spec in config["repositories"]:
        directory = safe_path(root, model_name(spec))
        validate_model(directory, spec)
        for path in sorted(directory.rglob("*")):
            if path.is_symlink():
                raise InvalidModel("Published models must not contain symbolic links")
            if path.is_file():
                name = path.relative_to(root).as_posix()
                files[name] = {"sha256": digest(path), "size": path.stat().st_size}
    return files


def verify_bundle(root, config, identity):
    marker = root / ".complete.json"
    try:
        if root.is_symlink() or not marker.is_file() or marker.is_symlink():
            return False
        manifest = json.loads(marker.read_text())
        if manifest.get("configSha256") != identity or manifest.get("config") != config:
            return False
        recorded = manifest.get("files", {})
        if not recorded:
            return False
        # Recompute the selected inventory: detect removed, changed AND extra files.
        return selected_files(root, config) == recorded
    except (OSError, ValueError, TypeError, KeyError):
        return False


@contextlib.contextmanager
def bundle_lock(cache, timeout):
    cache.mkdir(parents=True, exist_ok=True)
    lock_path = cache / ".model-preparation.lock"
    if lock_path.is_symlink():
        raise InvalidModel("The model preparation lock is a symbolic link")
    # Advisory OS locking is released on process death. Never unlink another owner's lock.
    with lock_path.open("a+b") as lock:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise InvalidModel("Timed out waiting for the active model preparer")
                time.sleep(min(1, max(0, deadline - time.monotonic())))
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def copy_model(source, target):
    # Copy content without chmod/chown/copy2; only staging data is ever copied.
    # copytree follows symlinks by default: reject them before copying any bytes.
    if source.is_symlink() or any(path.is_symlink() for path in source.rglob("*")):
        raise InvalidModel("Model sources must not contain symbolic links")
    shutil.copytree(
        source, target, copy_function=shutil.copyfile,
        ignore=shutil.ignore_patterns(".cache", ".git", "*.lock", ".download.lock"),
    )


def fetch_model(spec, target):
    from huggingface_hub import snapshot_download

    snapshot_download(
        repo_id=spec["repo"], revision=spec["revision"], local_dir=str(target),
        allow_patterns=spec.get("allowPatterns"),
        token=os.environ.get("HF_TOKEN") or False,
    )


def prepare(cache, bundled, staging, config, identity, timeout, fetcher=fetch_model):
    cache = cache.resolve()
    staging.mkdir(parents=True, exist_ok=True)
    bundles = cache / ".bundles"
    with bundle_lock(cache, timeout):
        bundles.mkdir(exist_ok=True)
        if bundles.is_symlink():
            raise InvalidModel("Bundle storage is a symbolic link")
        final = bundles / identity
        if verify_bundle(final, config, identity):
            print("Verified model bundle already present; no download required.", flush=True)
            return final
        if final.is_symlink():
            raise InvalidModel("Published bundle is a symbolic link")
        if (final / ".complete.json").exists():
            raise InvalidModel("Published bundle is corrupt; preserve it for explicit repair")
        if final.exists():
            quarantine = cache / ".incomplete"
            quarantine.mkdir(exist_ok=True)
            if quarantine.is_symlink():
                raise InvalidModel("Quarantine storage is a symbolic link")
            final.rename(quarantine / (identity + "-" + uuid.uuid4().hex))
        # Temporary destination is on the same filesystem, making final rename atomic.
        with tempfile.TemporaryDirectory(prefix=".preparing-", dir=bundles) as pending:
            pending_root = Path(pending)
            origins = {}
            for spec in config["repositories"]:
                name = model_name(spec)
                source = safe_path(bundled, name)
                target = pending_root / name
                try:
                    validate_model(source, spec)
                    copy_model(source, target)
                    origins[name] = {"source": "image", "image": config["image"]}
                    print("Copied qualified image model: " + name, flush=True)
                except (InvalidModel, FileNotFoundError):
                    if "repo" not in spec:
                        raise InvalidModel("Pinned preparation image lacks required OCR assets: " + name)
                    with tempfile.TemporaryDirectory(prefix="download-", dir=staging) as download:
                        downloaded = Path(download) / name
                        fetcher(spec, downloaded)
                        validate_model(downloaded, spec)
                        copy_model(downloaded, target)
                    origins[name] = {"source": "huggingface", "repo": spec["repo"],
                                     "revision": spec["revision"]}
                    print("Prepared pinned repository: " + name, flush=True)
            packages = {}
            for package in ["docling-serve", "docling-slim", "docling-core",
                            "docling-ibm-models", "docling-parse", "huggingface-hub"]:
                try:
                    packages[package] = importlib.metadata.version(package)
                except importlib.metadata.PackageNotFoundError:
                    continue
            manifest = {
                "configSha256": identity, "config": config,
                "packages": packages, "origins": origins,
                "files": selected_files(pending_root, config),
            }
            marker = pending_root / ".complete.json"
            with marker.open("w") as stream:
                json.dump(manifest, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            # Do not delete or overwrite any existing completed bundle.
            pending_root.rename(final)
        print("Published complete model bundle: " + identity, flush=True)
        return final


def verify_legacy(root, config):
    # Existing externally prepared claims are read only; never rewrite their manifest.
    for spec in config["repositories"]:
        validate_model(safe_path(root, model_name(spec)), spec)
    legacy = root / ".docling-serve.manifest"
    if legacy.is_file():
        for line in legacy.read_text().splitlines():
            expected, name = line.split(maxsplit=1)
            path = safe_path(root, name.lstrip("*"))
            if not re.fullmatch(r"[a-f0-9]{64}", expected):
                raise InvalidModel("Invalid legacy manifest checksum")
            if not path.is_file() or digest(path) != expected:
                raise InvalidModel("Legacy manifest checksum mismatch")
    print("Verified externally prepared model files.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "verify"])
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--bundled", type=Path)
    parser.add_argument("--staging", type=Path)
    parser.add_argument("--lock-timeout", type=float, default=600)
    parser.add_argument("--wait-timeout", type=float, default=0)
    parser.add_argument("--legacy", action="store_true")
    args = parser.parse_args()
    config, identity = load_config(args.config)
    if args.action == "prepare":
        if not args.bundled or not args.staging:
            parser.error("prepare requires --bundled and --staging")
        prepare(args.cache, args.bundled, args.staging, config, identity, args.lock_timeout)
    elif args.legacy:
        verify_legacy(args.cache, config)
    else:
        root = args.cache / ".bundles" / identity
        deadline = time.monotonic() + args.wait_timeout
        while not (root / ".complete.json").is_file() and time.monotonic() < deadline:
            time.sleep(min(5, max(0, deadline - time.monotonic())))
        if not verify_bundle(root, config, identity):
            raise InvalidModel("Required complete model bundle is absent or corrupt: " + identity)
        print("Verified prepared model bundle.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except InvalidModel as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # Avoid propagating credential-bearing external exception text into Kubernetes logs.
        print("Model preparation failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
