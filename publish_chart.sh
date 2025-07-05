#!/usr/bin/env bash
set -eo pipefail

# === CONFIG ===
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CHART_NAME=""
REPO_URL=${REPO_URL:-"https://forwardmeasure.github.io/helm-charts/charts"}
DO_TAG=true
DO_PUSH=true
DO_BRANCH=true
BASE_BRANCH="develop"

# === PARSE ARGS ===
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --chart-name) CHART_NAME="$2"; shift ;;
    --version) VERSION_OVERRIDE="$2"; shift ;;
    --message) COMMIT_MSG="$2"; shift ;;
    --base-branch) BASE_BRANCH="$2"; shift ;;
    --no-tag) DO_TAG=false ;;
    --no-push) DO_PUSH=false ;;
    --no-branch) DO_BRANCH=false ;;
    *) echo "❌ Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "$CHART_NAME" ]]; then
  echo "❌ --chart-name is required"
  exit 1
fi

CHART_PARENT_DIR="${SCRIPT_DIR}/charts/${CHART_NAME}"
CHART_SOURCE_DIR="${CHART_PARENT_DIR}/helm-chart-sources"
CHART_FILE="${CHART_SOURCE_DIR}/Chart.yaml"
VALUES_FILE="${CHART_SOURCE_DIR}/values.yaml"

# === Extract image tag from values.yaml ===
IMAGE_TAG=$(yq e '.image.tag' "${VALUES_FILE}")

if [[ -z "$IMAGE_TAG" ]]; then
  echo "❌ Could not extract image tag from values.yaml"
  exit 1
fi

# === Determine new version ===
CURRENT_VERSION=$(grep "^version:" "$CHART_FILE" | awk '{print $2}' | tr -d '
' | xargs)

if [[ -z "$CURRENT_VERSION" ]]; then
  echo "❌ Could not extract version from Chart.yaml"
  exit 1
fi

if [[ -n "$VERSION_OVERRIDE" ]]; then
  NEW_VERSION="$VERSION_OVERRIDE"
else
  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
  PATCH=$((PATCH + 1))
  NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

echo "🧪 CURRENT_VERSION=$CURRENT_VERSION"
echo "🧪 NEW_VERSION=$NEW_VERSION"
echo "🧪 IMAGE_TAG=$IMAGE_TAG"

# === Update Chart.yaml ===
if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "⚠️  Version unchanged ($NEW_VERSION). Skipping version bump."
else
  echo "🔧 Updating Chart.yaml: version=${NEW_VERSION}, appVersion=${IMAGE_TAG}"
  sed -i'' -E "s/^version: .*/version: \"$NEW_VERSION\"/" "$CHART_FILE"
  sed -i'' -E "s/^appVersion: .*/appVersion: \"$IMAGE_TAG\"/" "$CHART_FILE"
fi

# === Commit metadata ===
COMMIT_MSG=${COMMIT_MSG:-"Release chart version ${NEW_VERSION}"}
RELEASE_BRANCH="release/${CHART_NAME}/v${NEW_VERSION}"
RELEASE_TAG="${CHART_NAME}-v${NEW_VERSION}"

cd "$CHART_PARENT_DIR"

echo "🔍 Linting Helm chart..."
helm lint "${CHART_SOURCE_DIR}"

echo "📦 Packaging Helm chart version ${NEW_VERSION}..."
helm package "${CHART_SOURCE_DIR}"

CHART_PACKAGE_FILE=$(ls "${CHART_PARENT_DIR}"/*.tgz | tail -n1)

echo "⬇️ Fetching latest index.yaml from ${BASE_BRANCH}..."
cd "$SCRIPT_DIR"
git fetch origin "${BASE_BRANCH}"
TMP_INDEX=$(mktemp)
git show origin/${BASE_BRANCH}:charts/${CHART_NAME}/index.yaml > "$TMP_INDEX" || touch "$TMP_INDEX"

echo "🧾 Merging new chart into index.yaml..."
helm repo index "charts/${CHART_NAME}" --url "${REPO_URL}" --merge "$TMP_INDEX"
rm -f "$TMP_INDEX"

echo "📂 Committing changes to Git..."
git add "$CHART_PACKAGE_FILE" index.yaml "$SCRIPT_DIR/publish_chart.sh" "$CHART_FILE"
git commit -m "${COMMIT_MSG}"

if $DO_BRANCH; then
  echo "🌿 Creating release branch: ${RELEASE_BRANCH}"
  git checkout -b "${RELEASE_BRANCH}"
fi

if $DO_TAG; then
  echo "🏷️  Tagging release as: ${RELEASE_TAG}"
  git tag "${RELEASE_TAG}"
fi

if $DO_PUSH; then
  echo "🚀 Pushing branch and tag to remote..."
  git config push.default current
  if $DO_BRANCH; then git push -u origin "${RELEASE_BRANCH}"; fi
  if $DO_TAG; then git push origin "${RELEASE_TAG}"; fi
else
  echo "⚠️  Push skipped (--no-push was set)"
fi

echo "✅ Helm chart '${CHART_NAME}' version ${NEW_VERSION} packaged and index updated!"