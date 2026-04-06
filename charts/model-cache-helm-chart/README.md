# model-cache

## Overview

The `model-cache` chart provisions shared storage infrastructure for model-serving workloads.

It supports both cluster-scoped infrastructure and namespace-scoped resources in a single chart, allowing flexible deployment patterns.

This chart is intentionally cloud-agnostic and supports CSI-based storage backends such as:

- GCP (GCS FUSE CSI)
- AWS (EFS, S3 Mountpoint)
- NFS / on-prem storage

---

## Supported Modes

### 1. Cluster-Artifacts Mode

Creates only cluster-scoped resources:

- `StorageClass`
- `PersistentVolume`

Use this mode when provisioning shared storage centrally.

```yaml
persistentVolumeClaim:
  create: false

serviceAccount:
  create: false