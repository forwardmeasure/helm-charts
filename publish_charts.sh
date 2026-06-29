#!/usr/bin/env bash
set -euo pipefail

# === CONFIG ===
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# === DEFAULTS ===
DO_TAG=true
DO_PUSH=true
DO_BRANCH=true
DRY_RUN=false
BASE_BRANCH="develop"
CHART_NAMES=()
REPO_URL=""
VERSION_OVERRIDE=""
COMMIT_MSG=""

# === PARSE ARGS ===
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --chart-name)
      [[ -n "${2:-}" ]] || { echo "❌ --chart-name requires a value"; exit 1; }
      CHART_NAMES+=("$2")
      shift 2
      ;;
    --version)
      VERSION_OVERRIDE="${2:-}"
      [[ -n "$VERSION_OVERRIDE" ]] || { echo "❌ --version requires a value"; exit 1; }
      shift 2
      ;;
    --message)
      COMMIT_MSG="${2:-}"
      [[ -n "$COMMIT_MSG" ]] || { echo "❌ --message requires a value"; exit 1; }
      shift 2
      ;;
    --base-branch)
      BASE_BRANCH="${2:-}"
      [[ -n "$BASE_BRANCH" ]] || { echo "❌ --base-branch requires a value"; exit 1; }
      shift 2
      ;;
    --repo-url)
      REPO_URL="${2:-}"
      [[ -n "$REPO_URL" ]] || { echo "❌ --repo-url requires a value"; exit 1; }
      shift 2
      ;;
    --no-tag)
      DO_TAG=false
      shift
      ;;
    --no-push)
      DO_PUSH=false
      shift
      ;;
    --no-branch)
      DO_BRANCH=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "❌ Unknown parameter passed: $1"
      exit 1
      ;;
  esac
done

# === Validate chart names ===
if [[ ${#CHART_NAMES[@]} -eq 0 ]]; then
  echo "❌ At least one --chart-name is required"
  exit 1
fi

# === Deduplicate chart names while preserving order ===
UNIQUE_CHART_NAMES=()
declare -A _seen_charts=()
for chart in "${CHART_NAMES[@]}"; do
  if [[ -z "${_seen_charts[$chart]+x}" ]]; then
    UNIQUE_CHART_NAMES+=("$chart")
    _seen_charts["$chart"]=1
  fi
done
CHART_NAMES=("${UNIQUE_CHART_NAMES[@]}")
unset UNIQUE_CHART_NAMES _seen_charts

if $DRY_RUN; then
  echo "🔬 DRY RUN — no files will be modified, no git operations will be performed"
fi

RELEASE_BRANCH=""
RELEASE_TAGS=()
STAGED_PATHS=()
TMP_INDEX=""

cleanup() {
  [[ -n "$TMP_INDEX" && -f "$TMP_INDEX" ]] && rm -f "$TMP_INDEX"
}
trap cleanup EXIT

append_unique_staged_path() {
  local path="$1"
  local existing
  for existing in "${STAGED_PATHS[@]:-}"; do
    if [[ "$existing" == "$path" ]]; then
      return 0
    fi
  done
  STAGED_PATHS+=("$path")
}

release_chart() {
  local CHART_NAME="$1"

  local CHART_PARENT_DIR="${SCRIPT_DIR}/charts/${CHART_NAME}"
  local CHART_SOURCE_DIR="${CHART_PARENT_DIR}/helm-chart-sources"
  local CHART_PACKAGE_DIR="${CHART_PARENT_DIR}"
  local CHART_FILE="${CHART_SOURCE_DIR}/Chart.yaml"
  local VALUES_FILE="${CHART_SOURCE_DIR}/values.yaml"
  local CHART_REPO_URL="${REPO_URL:-https://forwardmeasure.github.io/helm-charts/charts/${CHART_NAME}}"

  if [[ ! -d "$CHART_SOURCE_DIR" ]]; then
    echo "❌ Chart source directory not found: $CHART_SOURCE_DIR"
    exit 1
  fi

  if [[ ! -f "$CHART_FILE" ]]; then
    echo "❌ Chart.yaml not found: $CHART_FILE"
    exit 1
  fi

  local CURRENT_VERSION
  CURRENT_VERSION=$(grep '^version:' "$CHART_FILE" | awk '{print $2}' | tr -d '"' | tr -d '\r\n' | xargs)
  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "❌ Could not extract version from Chart.yaml for chart '$CHART_NAME'"
    exit 1
  fi

  local NEW_VERSION
  if [[ -n "$VERSION_OVERRIDE" ]]; then
    NEW_VERSION="$VERSION_OVERRIDE"
  else
    local MAJOR MINOR PATCH
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
    if [[ -z "${MAJOR:-}" || -z "${MINOR:-}" || -z "${PATCH:-}" ]]; then
      echo "❌ Failed to parse semantic version from $CURRENT_VERSION for chart '$CHART_NAME'"
      exit 1
    fi
    PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
  fi

  local IMAGE_TAG=""
  if [[ -f "$VALUES_FILE" ]]; then
    IMAGE_TAG=$(yq e '.image.tag' "$VALUES_FILE" 2>/dev/null || true)
  fi

  if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "null" ]]; then
    IMAGE_TAG=$(grep '^appVersion:' "$CHART_FILE" | awk '{print $2}' | tr -d '"' | tr -d '\r\n' | xargs || true)
    if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "null" ]]; then
      IMAGE_TAG="$NEW_VERSION"
      echo "ℹ️  [$CHART_NAME] No image.tag or appVersion found — using chart version as appVersion: ${IMAGE_TAG}"
    else
      echo "ℹ️  [$CHART_NAME] No image.tag in values.yaml — using existing appVersion: ${IMAGE_TAG}"
    fi
  fi

  echo "🧪 [$CHART_NAME] CURRENT_VERSION=$CURRENT_VERSION"
  echo "🧪 [$CHART_NAME] NEW_VERSION=$NEW_VERSION"
  echo "🧪 [$CHART_NAME] IMAGE_TAG=$IMAGE_TAG"

  echo "🔍 [$CHART_NAME] Linting Helm chart..."
  if ! helm lint --strict "$CHART_SOURCE_DIR"; then
    echo "❌ [$CHART_NAME] Lint failed. Fix the errors above and retry."
    exit 1
  fi
  echo "✅ [$CHART_NAME] Lint passed."

  if $DRY_RUN; then
    echo "🔬 [$CHART_NAME] Would bump Chart.yaml: version ${CURRENT_VERSION} → ${NEW_VERSION}, appVersion ${IMAGE_TAG}"
    echo "🔬 [$CHART_NAME] Would package chart to ${CHART_PACKAGE_DIR}"
    echo "🔬 [$CHART_NAME] Would merge packaged chart into root index.yaml using ${CHART_REPO_URL}"
    append_unique_staged_path "index.yaml"
    append_unique_staged_path "charts/${CHART_NAME}/helm-chart-sources"
    append_unique_staged_path "charts/${CHART_NAME}/*.tgz"
    RELEASE_TAGS+=("${CHART_NAME}-v${NEW_VERSION}")
    return 0
  fi

  if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
    echo "⚠️  [$CHART_NAME] Version unchanged ($NEW_VERSION). Skipping version bump."
  else
    echo "🔧 [$CHART_NAME] Updating Chart.yaml: version=${NEW_VERSION}, appVersion=${IMAGE_TAG}"
    sed -i'' -E "s/^version: .*/version: \"$NEW_VERSION\"/" "$CHART_FILE"
    if grep -q '^appVersion:' "$CHART_FILE"; then
      sed -i'' -E "s/^appVersion: .*/appVersion: \"$IMAGE_TAG\"/" "$CHART_FILE"
    else
      printf '\nappVersion: "%s"\n' "$IMAGE_TAG" >> "$CHART_FILE"
    fi
  fi

  echo "📦 [$CHART_NAME] Packaging Helm chart version ${NEW_VERSION}..."
  helm package "$CHART_SOURCE_DIR" --destination "$CHART_PACKAGE_DIR" >/dev/null

  echo "⬇️ [$CHART_NAME] Fetching latest index.yaml from ${BASE_BRANCH}..."
  git fetch origin "$BASE_BRANCH" >/dev/null
  TMP_INDEX=$(mktemp)
  git show "origin/${BASE_BRANCH}:index.yaml" > "$TMP_INDEX" || touch "$TMP_INDEX"

  echo "🧾 [$CHART_NAME] Merging chart into root-level index.yaml..."
  helm repo index "$CHART_PACKAGE_DIR" \
    --url "$CHART_REPO_URL" \
    --merge "$TMP_INDEX" >/dev/null

  mv "${CHART_PACKAGE_DIR}/index.yaml" "${SCRIPT_DIR}/index.yaml"
  rm -f "$TMP_INDEX"
  TMP_INDEX=""

  append_unique_staged_path "index.yaml"
  append_unique_staged_path "charts/${CHART_NAME}/helm-chart-sources"
  append_unique_staged_path "charts/${CHART_NAME}/*.tgz"
  RELEASE_TAGS+=("${CHART_NAME}-v${NEW_VERSION}")
}

stage_release_files() {
  git reset >/dev/null

  local chart package_paths
  for chart in "${CHART_NAMES[@]}"; do
    if [[ -d "charts/${chart}/helm-chart-sources" ]]; then
      git add "charts/${chart}/helm-chart-sources"
    fi

    if [[ -d "charts/${chart}/images" ]]; then
      git add "charts/${chart}/images"
    fi

    shopt -s nullglob
    package_paths=("charts/${chart}"/*.tgz)
    shopt -u nullglob
    if [[ ${#package_paths[@]} -gt 0 ]]; then
      git add "${package_paths[@]}"
    fi
  done

  if [[ -f "index.yaml" ]]; then
    git add index.yaml
  fi
}

# === Process charts ===
for chart in "${CHART_NAMES[@]}"; do
  release_chart "$chart"
done

# === Dry-run output ===
if $DRY_RUN; then
  echo
  echo "🔬 Dry run complete. The following charts would have been processed:"
  printf '   - %s\n' "${CHART_NAMES[@]}"
  echo "   - Root index.yaml would be regenerated using each chart package directory"
  echo "   - Only files pertaining to the named charts would be staged:"
  printf '     - %s\n' "${STAGED_PATHS[@]}"
  echo "   - git commit: '${COMMIT_MSG:-Release charts: ${CHART_NAMES[*]}}'"
  if $DO_BRANCH; then echo "   - git checkout -b release/charts/$(date +%Y%m%d%H%M%S)"; fi
  if $DO_TAG; then
    for tag in "${RELEASE_TAGS[@]}"; do
      echo "   - git tag ${tag}"
    done
  fi
  if $DO_PUSH; then echo "   - git push branch and tag(s) to remote"; fi
  exit 0
fi

# === Set commit and release metadata ===
COMMIT_MSG=${COMMIT_MSG:-"Release charts: ${CHART_NAMES[*]}"}
RELEASE_BRANCH="release/charts/$(date +%Y%m%d%H%M%S)"

# === Git commit and push ===
cd "$SCRIPT_DIR"
echo "📂 Staging only files pertaining to the named charts..."
stage_release_files

echo "📋 Files staged for commit:"
git diff --cached --name-only

if git diff --cached --quiet; then
  echo "❌ No files staged for commit. Aborting."
  exit 1
fi

echo "📝 Creating commit..."
git commit -m "$COMMIT_MSG"

if $DO_BRANCH; then
  echo "🌿 Creating release branch: ${RELEASE_BRANCH}"
  git checkout -b "$RELEASE_BRANCH"
fi

if $DO_TAG; then
  for tag in "${RELEASE_TAGS[@]}"; do
    echo "🏷️  Tagging release as: ${tag}"
    git tag "$tag"
  done
fi

if $DO_PUSH; then
  echo "🚀 Pushing branch and tag(s) to remote..."
  git config push.default current
  if $DO_BRANCH; then
    git push -u origin "$RELEASE_BRANCH"
  else
    git push origin HEAD
  fi
  if $DO_TAG; then
    for tag in "${RELEASE_TAGS[@]}"; do
      git push origin "$tag"
    done
  fi
  if $DO_BRANCH; then
    echo "🧹 Deleting local release branch: ${RELEASE_BRANCH}"
    git checkout "$BASE_BRANCH"
    git branch -D "$RELEASE_BRANCH"
  fi
else
  echo "⚠️  Push skipped (--no-push was set)"
fi

echo "✅ Helm chart(s) released: ${CHART_NAMES[*]}"
