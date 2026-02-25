#!/usr/bin/env bash
set -eo pipefail

# === CONFIG ===
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# === DEFAULTS ===
DO_TAG=true
DO_PUSH=true
DO_BRANCH=true
BASE_BRANCH="develop"
CHART_NAME=""
REPO_URL=""

# === PARSE ARGS ===
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --chart-name) CHART_NAME="$2"; shift ;;
    --version) VERSION_OVERRIDE="$2"; shift ;;
    --message) COMMIT_MSG="$2"; shift ;;
    --base-branch) BASE_BRANCH="$2"; shift ;;
    --repo-url) REPO_URL="$2"; shift ;;
    --no-tag) DO_TAG=false ;;
    --no-push) DO_PUSH=false ;;
    --no-branch) DO_BRANCH=false ;;
    *) echo "❌ Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

# === Validate chart name ===
if [[ -z "$CHART_NAME" ]]; then
  echo "❌ --chart-name is required"
  exit 1
fi

CHART_PARENT_DIR="${SCRIPT_DIR}/charts/${CHART_NAME}"
CHART_SOURCE_DIR="${CHART_PARENT_DIR}/helm-chart-sources"
CHART_PACKAGE_DIR="${CHART_PARENT_DIR}"
CHART_FILE="${CHART_SOURCE_DIR}/Chart.yaml"
VALUES_FILE="${CHART_SOURCE_DIR}/values.yaml"
REPO_URL=${REPO_URL:-"https://forwardmeasure.github.io/helm-charts/charts/${CHART_NAME}"}

# === Extract image tag from values.yaml ===
IMAGE_TAG=$(yq e '.image.tag' "${VALUES_FILE}")
if [[ -z "$IMAGE_TAG" ]]; then
  echo "❌ Could not extract image tag from values.yaml"
  exit 1
fi

# === Determine current and new version ===
CURRENT_VERSION=$(grep "^version:" "$CHART_FILE" | awk '{print $2}' | tr -d '\r\n' | xargs)
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "❌ Could not extract version from Chart.yaml"
  exit 1
fi

if [[ -n "$VERSION_OVERRIDE" ]]; then
  NEW_VERSION="$VERSION_OVERRIDE"
else
  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
  if [[ -z "$MAJOR" || -z "$MINOR" || -z "$PATCH" ]]; then
    echo "❌ Failed to parse semantic version from $CURRENT_VERSION"
    exit 1
  fi
  PATCH=$((PATCH + 1))
  NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

echo "🧪 CURRENT_VERSION=$CURRENT_VERSION"
echo "🧪 NEW_VERSION=$NEW_VERSION"
echo "🧪 IMAGE_TAG=$IMAGE_TAG"

# === Lint BEFORE making any changes ===
# We lint against the current version so that a failure leaves Chart.yaml untouched
# and the working tree clean.
echo "🔍 Linting Helm chart (pre-bump)..."
if ! helm lint "${CHART_SOURCE_DIR}"; then
  echo "❌ Lint failed. Chart.yaml has NOT been modified. Fix the errors above and retry."
  exit 1
fi
echo "✅ Lint passed."

# === Update Chart.yaml (only reached if lint succeeded) ===
if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "⚠️  Version unchanged ($NEW_VERSION). Skipping version bump."
else
  echo "🔧 Updating Chart.yaml: version=${NEW_VERSION}, appVersion=${IMAGE_TAG}"
  sed -i'' -E "s/^version: .*/version: \"$NEW_VERSION\"/" "$CHART_FILE"
  sed -i'' -E "s/^appVersion: .*/appVersion: \"$IMAGE_TAG\"/" "$CHART_FILE"
fi

# === Set commit message and release labels ===
COMMIT_MSG=${COMMIT_MSG:-"Release chart version ${NEW_VERSION}"}
RELEASE_BRANCH="release/${CHART_NAME}/v${NEW_VERSION}"
RELEASE_TAG="${CHART_NAME}-v${NEW_VERSION}"

cd "$CHART_PARENT_DIR"

echo "📦 Packaging Helm chart version ${NEW_VERSION}..."
helm package "${CHART_SOURCE_DIR}" --destination "${CHART_PACKAGE_DIR}"

# === Update root-level index.yaml ===
echo "⬇️ Fetching latest index.yaml from ${BASE_BRANCH}..."
git fetch origin "${BASE_BRANCH}"
TMP_INDEX=$(mktemp)
git show origin/${BASE_BRANCH}:index.yaml > "$TMP_INDEX" || touch "$TMP_INDEX"

echo "🧾 Merging chart into root-level index.yaml..."
helm repo index "${CHART_PACKAGE_DIR}" \
  --url "${REPO_URL}" \
  --merge "$TMP_INDEX"

# === Sync root index to top-level ===
mv "${CHART_PACKAGE_DIR}/index.yaml" "${SCRIPT_DIR}/index.yaml"
rm -f "$TMP_INDEX"

# === Git commit and push ===
cd "$SCRIPT_DIR"
echo "📂 Committing changes to Git..."
git add .
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
  # === Delete local release branch after pushing
  echo "🧹 Deleting local release branch: ${RELEASE_BRANCH}"
  git checkout "${BASE_BRANCH}"
  git branch -D "${RELEASE_BRANCH}"
else
  echo "⚠️  Push skipped (--no-push was set)"
fi

echo "✅ Helm chart '${CHART_NAME}' version ${NEW_VERSION} packaged and index updated!"