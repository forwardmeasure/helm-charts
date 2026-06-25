#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

DO_TAG=true
DO_PUSH=true
DO_BRANCH=true
DRY_RUN=false
BASE_BRANCH="develop"
REPO_URL=""
VERSION_OVERRIDE=""
COMMIT_MSG=""
CHART_NAMES=()

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

if [[ ${#CHART_NAMES[@]} -eq 0 ]]; then
  echo "❌ At least one --chart-name is required"
  exit 1
fi

if $DRY_RUN; then
  echo "🔬 DRY RUN — no files will be modified, no git operations will be performed"
fi

release_chart() {
  local CHART_NAME="$1"

  local CHART_PARENT_DIR="${SCRIPT_DIR}/charts/${CHART_NAME}"
  local CHART_SOURCE_DIR="${CHART_PARENT_DIR}/helm-chart-sources"
  local CHART_PACKAGE_DIR="${CHART_PARENT_DIR}"
  local CHART_FILE="${CHART_SOURCE_DIR}/Chart.yaml"
  local VALUES_FILE="${CHART_SOURCE_DIR}/values.yaml"
  local CHART_REPO_URL="${REPO_URL:-https://forwardmeasure.github.io/helm-charts/charts/${CHART_NAME}}"

  [[ -f "$CHART_FILE" ]] || { echo "❌ Missing $CHART_FILE"; exit 1; }
  [[ -f "$VALUES_FILE" ]] || echo "⚠️  Missing $VALUES_FILE, falling back to appVersion/version logic"

  local CURRENT_VERSION
  CURRENT_VERSION=$(grep "^version:" "$CHART_FILE" | awk '{print $2}' | tr -d '"' | tr -d '\r\n' | xargs)

  if [[ -z "$CURRENT_VERSION" ]]; then
    echo "❌ Could not extract version from $CHART_FILE"
    exit 1
  fi

  local NEW_VERSION
  if [[ -n "$VERSION_OVERRIDE" ]]; then
    NEW_VERSION="$VERSION_OVERRIDE"
  else
    local MAJOR MINOR PATCH
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
    if [[ -z "${MAJOR:-}" || -z "${MINOR:-}" || -z "${PATCH:-}" ]]; then
      echo "❌ Failed to parse semantic version from $CURRENT_VERSION"
      exit 1
    fi
    PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
  fi

  local IMAGE_TAG=""
  if [[ -f "$VALUES_FILE" ]]; then
    IMAGE_TAG=$(yq e '.image.tag' "${VALUES_FILE}" 2>/dev/null || true)
  fi

  if [[ -z "$IMAGE_TAG" || "$IMAGE_TAG" == "null" ]]; then
    IMAGE_TAG=$(grep "^appVersion:" "$CHART_FILE" | awk '{print $2}' | tr -d '"' | tr -d '\r\n' | xargs || true)
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
  helm lint --strict "${CHART_SOURCE_DIR}"
  echo "✅ [$CHART_NAME] Lint passed."

  if $DRY_RUN; then
    echo "🔬 [$CHART_NAME] Would bump Chart.yaml: version ${CURRENT_VERSION} → ${NEW_VERSION}, appVersion ${IMAGE_TAG}"
    echo "🔬 [$CHART_NAME] Would package chart to ${CHART_PACKAGE_DIR}"
    echo "🔬 [$CHART_NAME] Would merge into index.yaml"
    return 0
  fi

  if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "🔧 [$CHART_NAME] Updating Chart.yaml: version=${NEW_VERSION}, appVersion=${IMAGE_TAG}"
    sed -i'' -E "s/^version: .*/version: \"$NEW_VERSION\"/" "$CHART_FILE"
    sed -i'' -E "s/^appVersion: .*/appVersion: \"$IMAGE_TAG\"/" "$CHART_FILE"
  else
    echo "⚠️  [$CHART_NAME] Version unchanged ($NEW_VERSION). Skipping version bump."
  fi

  echo "📦 [$CHART_NAME] Packaging Helm chart version ${NEW_VERSION}..."
  (
    cd "$CHART_PARENT_DIR"
    helm package "${CHART_SOURCE_DIR}" --destination "${CHART_PACKAGE_DIR}"
  )
}

git fetch origin "${BASE_BRANCH}"

TMP_INDEX=$(mktemp)
git show "origin/${BASE_BRANCH}:index.yaml" > "$TMP_INDEX" || touch "$TMP_INDEX"

for chart in "${CHART_NAMES[@]}"; do
  release_chart "$chart"
done

if $DRY_RUN; then
  echo ""
  echo "🔬 Dry run complete. Charts:"
  printf '   - %s\n' "${CHART_NAMES[@]}"
  echo "   - Merge all packaged charts into index.yaml"
  echo "   - git commit: '${COMMIT_MSG:-Release charts}'"
  if $DO_BRANCH; then
    echo "   - create release branch"
  fi
  if $DO_TAG; then
    echo "   - create release tag(s)"
  fi
  if $DO_PUSH; then
    echo "   - push branch and tag(s) to remote"
  fi
  rm -f "$TMP_INDEX"
  exit 0
fi

echo "🧾 Merging charts into root-level index.yaml..."
helm repo index "${SCRIPT_DIR}" --url "https://forwardmeasure.github.io/helm-charts" --merge "$TMP_INDEX"
rm -f "$TMP_INDEX"

COMMIT_MSG=${COMMIT_MSG:-"Release charts: ${CHART_NAMES[*]}"}
RELEASE_BRANCH="release/charts/$(date +%Y%m%d%H%M%S)"

cd "$SCRIPT_DIR"
git add .
git commit -m "${COMMIT_MSG}"

if $DO_BRANCH; then
  echo "🌿 Creating release branch: ${RELEASE_BRANCH}"
  git checkout -b "${RELEASE_BRANCH}"
fi

if $DO_TAG; then
  for chart in "${CHART_NAMES[@]}"; do
    chart_file="${SCRIPT_DIR}/charts/${chart}/helm-chart-sources/Chart.yaml"
    chart_version=$(grep "^version:" "$chart_file" | awk '{print $2}' | tr -d '"' | tr -d '\r\n' | xargs)
    release_tag="${chart}-v${chart_version}"
    echo "🏷️  Tagging release as: ${release_tag}"
    git tag "${release_tag}"
  done
fi

if $DO_PUSH; then
  echo "🚀 Pushing branch and tag(s) to remote..."
  git config push.default current
  if $DO_BRANCH; then
    git push -u origin "${RELEASE_BRANCH}"
  fi
  if $DO_TAG; then
    for chart in "${CHART_NAMES[@]}"; do
      chart_file="${SCRIPT_DIR}/charts/${chart}/helm-chart-sources/Chart.yaml"
      chart_version=$(grep "^version:" "$chart_file" | awk '{print $2}' | tr -d '"' | tr -d '\r\n' | xargs)
      git push origin "${chart}-v${chart_version}"
    done
  fi
  if $DO_BRANCH; then
    echo "🧹 Deleting local release branch: ${RELEASE_BRANCH}"
    git checkout "${BASE_BRANCH}"
    git branch -D "${RELEASE_BRANCH}"
  fi
else
  echo "⚠️  Push skipped (--no-push was set)"
fi

echo "✅ Charts released: ${CHART_NAMES[*]}"