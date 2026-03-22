#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# cleanup_chart.sh
# Prunes old packaged versions of a Helm chart, removes their git tags
# (local and remote), updates index.yaml, and pushes to git.
#
# Usage:
#   ./cleanup_chart.sh --chart-name <name> [OPTIONS]
#
# Options:
#   --chart-name <name>   Chart folder name under charts/  (required)
#   --keep <n>            Number of most recent versions to retain (default: 2)
#   --base-branch <b>     Branch to commit against (default: develop)
#   --no-push             Skip git push
#   --dry-run             Show what would be done without making any changes
#   -h, --help            Show this help
#
# Examples:
#   ./cleanup_chart.sh --chart-name kserve-model-serving-helm-chart
#   ./cleanup_chart.sh --chart-name kserve-model-serving-helm-chart --keep 3
#   ./cleanup_chart.sh --chart-name itineris-helm-chart --keep 1 --dry-run
# ==============================================================================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# --- Defaults -----------------------------------------------------------------
CHART_NAME=""
KEEP=2
BASE_BRANCH="develop"
DO_PUSH=true
DRY_RUN=false

# --- Helpers ------------------------------------------------------------------
log()     { echo "$1"; }
info()    { echo "ℹ️  $1"; }
success() { echo "✅ $1"; }
warn()    { echo "⚠️  $1"; }
error()   { echo "❌ $1" >&2; exit 1; }
dry()     { echo "🔬 [DRY-RUN] $1"; }

usage() {
  sed -n '/^# Usage:/,/^# ==/p' "${BASH_SOURCE[0]}" \
    | sed 's/^# \?//' \
    | head -n -1
  exit 0
}

# --- Parse args ---------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --chart-name)  CHART_NAME="$2"; shift 2 ;;
    --keep)        KEEP="$2";        shift 2 ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --no-push)     DO_PUSH=false;    shift   ;;
    --dry-run)     DRY_RUN=true;     shift   ;;
    -h|--help)     usage ;;
    *) error "Unknown parameter: $1" ;;
  esac
done

# --- Validate -----------------------------------------------------------------
[[ -z "$CHART_NAME" ]] && error "--chart-name is required"
[[ "$KEEP" -lt 1 ]]   && error "--keep must be >= 1"

CHART_DIR="${SCRIPT_DIR}/charts/${CHART_NAME}"
[[ -d "$CHART_DIR" ]] || error "Chart directory not found: ${CHART_DIR}"

# --- Abort on uncommitted changes ---------------------------------------------
log ""
log "🔍 Checking git working tree..."
cd "$SCRIPT_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  error "Uncommitted changes detected. Please commit or stash before running cleanup."
fi

# Also check for untracked files in the chart directory specifically
if [[ -n "$(git ls-files --others --exclude-standard "${CHART_DIR}")" ]]; then
  error "Untracked files found in ${CHART_DIR}. Please commit or stash before running cleanup."
fi

success "Working tree is clean."

if $DRY_RUN; then
  log ""
  log "🔬 DRY RUN — no files will be modified, no git operations will be performed"
fi

# --- Discover chart name (from Chart.yaml) ------------------------------------
CHART_YAML="${CHART_DIR}/helm-chart-sources/Chart.yaml"
[[ -f "$CHART_YAML" ]] || error "Chart.yaml not found at: ${CHART_YAML}"

CHART_RELEASE_NAME=$(grep "^name:" "$CHART_YAML" | awk '{print $2}' | tr -d '"' | xargs)
[[ -z "$CHART_RELEASE_NAME" ]] && error "Could not extract chart name from Chart.yaml"

# --- Discover all packaged .tgz files for this chart -------------------------
log ""
log "📦 Discovering packaged versions of '${CHART_RELEASE_NAME}'..."

# Find all .tgz files matching <chart-release-name>-<semver>.tgz
mapfile -t ALL_TGZ < <(
  find "${CHART_DIR}" -maxdepth 1 -name "${CHART_RELEASE_NAME}-*.tgz" \
    | sort -t'-' -k1,1 -V \
    | sort -V
)

TOTAL=${#ALL_TGZ[@]}

if [[ "$TOTAL" -eq 0 ]]; then
  warn "No packaged .tgz files found for '${CHART_RELEASE_NAME}' in ${CHART_DIR}. Nothing to do."
  exit 0
fi

log "   Found ${TOTAL} packaged version(s):"
for f in "${ALL_TGZ[@]}"; do
  log "     - $(basename "$f")"
done

# --- Determine what to keep and what to delete --------------------------------
if [[ "$TOTAL" -le "$KEEP" ]]; then
  warn "Only ${TOTAL} version(s) found — at or below the keep threshold of ${KEEP}. Nothing to remove."
  exit 0
fi

# Sort by version — keep the KEEP most recent
mapfile -t SORTED_TGZ < <(
  for f in "${ALL_TGZ[@]}"; do
    basename "$f"
  done \
  | sort -V
)

TOTAL_SORTED=${#SORTED_TGZ[@]}
KEEP_START=$(( TOTAL_SORTED - KEEP ))

KEEP_LIST=("${SORTED_TGZ[@]:$KEEP_START}")
DELETE_LIST=("${SORTED_TGZ[@]:0:$KEEP_START}")

log ""
log "📋 Retention plan (keeping ${KEEP} most recent):"
log "   KEEP:"
for f in "${KEEP_LIST[@]}";   do log "     ✅ $f"; done
log "   DELETE:"
for f in "${DELETE_LIST[@]}"; do log "     🗑️  $f"; done

# --- Extract versions to delete -----------------------------------------------
# Version is everything after <chart-release-name>- and before .tgz
extract_version() {
  local filename="$1"
  local prefix="${CHART_RELEASE_NAME}-"
  echo "${filename#$prefix}" | sed 's/\.tgz$//'
}

# --- Fetch remote tags --------------------------------------------------------
log ""
log "🔄 Fetching remote tags..."
if ! $DRY_RUN; then
  git fetch --tags --prune origin
fi

# --- Process deletions --------------------------------------------------------
DELETED_COUNT=0
SKIPPED_TAGS=()

for tgz in "${DELETE_LIST[@]}"; do
  VERSION=$(extract_version "$tgz")
  TAG="${CHART_NAME}-v${VERSION}"
  TGZ_PATH="${CHART_DIR}/${tgz}"

  log ""
  log "🗑️  Processing: ${tgz} (version ${VERSION})"

  # Remove .tgz file
  if [[ -f "$TGZ_PATH" ]]; then
    if $DRY_RUN; then
      dry "Would remove: ${TGZ_PATH}"
    else
      rm -f "$TGZ_PATH"
      success "Removed: ${TGZ_PATH}"
    fi
  else
    warn "  .tgz not found (already removed?): ${TGZ_PATH}"
  fi

  # Remove local git tag if it exists
  if git tag -l | grep -qx "$TAG"; then
    if $DRY_RUN; then
      dry "Would delete local tag: ${TAG}"
    else
      git tag -d "$TAG"
      success "Deleted local tag: ${TAG}"
    fi
  else
    info "Local tag not found (skipping): ${TAG}"
  fi

  # Remove remote git tag if it exists
  if git ls-remote --tags origin | grep -q "refs/tags/${TAG}$"; then
    if $DRY_RUN; then
      dry "Would delete remote tag: ${TAG}"
    else
      git push origin ":refs/tags/${TAG}"
      success "Deleted remote tag: ${TAG}"
    fi
  else
    info "Remote tag not found (skipping): ${TAG}"
    SKIPPED_TAGS+=("$TAG")
  fi

  (( DELETED_COUNT++ )) || true
done

# --- Rebuild index.yaml -------------------------------------------------------
log ""
log "🧾 Rebuilding index.yaml from retained versions..."

if $DRY_RUN; then
  dry "Would rebuild index.yaml retaining: ${KEEP_LIST[*]}"
else
  # Fetch base branch index for merge baseline
  git fetch origin "$BASE_BRANCH"
  TMP_INDEX=$(mktemp)
  git show "origin/${BASE_BRANCH}:index.yaml" > "$TMP_INDEX" 2>/dev/null || touch "$TMP_INDEX"

  # Rebuild from the chart directory (only retained .tgz files remain now)
  REPO_URL="https://forwardmeasure.github.io/helm-charts/charts/${CHART_NAME}"
  helm repo index "${CHART_DIR}" \
    --url "${REPO_URL}" \
    --merge "$TMP_INDEX"

  mv "${CHART_DIR}/index.yaml" "${SCRIPT_DIR}/index.yaml"
  rm -f "$TMP_INDEX"

  success "index.yaml rebuilt."
fi

# --- Git commit and push ------------------------------------------------------
if $DRY_RUN; then
  dry "Would git add and commit: 'chore(${CHART_RELEASE_NAME}): prune ${DELETED_COUNT} old packaged version(s), retain ${KEEP}'"
  dry "Would push to origin/${BASE_BRANCH}"
  log ""
  log "🔬 Dry run complete. ${DELETED_COUNT} version(s) would have been removed."
  exit 0
fi

cd "$SCRIPT_DIR"

# Only commit if there are actual changes
if git diff --quiet && git diff --cached --quiet; then
  warn "No git changes detected after cleanup — nothing to commit."
else
  git add .
  git commit -m "chore(${CHART_RELEASE_NAME}): prune ${DELETED_COUNT} old packaged version(s), retain ${KEEP}"
  success "Changes committed."

  if $DO_PUSH; then
    log "🚀 Pushing to origin/${BASE_BRANCH}..."
    git push origin "HEAD:${BASE_BRANCH}"
    success "Pushed to origin/${BASE_BRANCH}."
  else
    warn "Push skipped (--no-push was set)."
  fi
fi

# --- Summary ------------------------------------------------------------------
log ""
log "╔══════════════════════════════════════════════════════╗"
log "║           Chart Cleanup Complete                     ║"
log "╠══════════════════════════════════════════════════════╣"
printf "║  %-24s %-28s ║\n" "Chart:"          "${CHART_RELEASE_NAME}"
printf "║  %-24s %-28s ║\n" "Versions removed:"  "${DELETED_COUNT}"
printf "║  %-24s %-28s ║\n" "Versions retained:" "${KEEP}"
printf "║  %-24s %-28s ║\n" "Retained versions:" "${KEEP_LIST[*]}"
if [[ ${#SKIPPED_TAGS[@]} -gt 0 ]]; then
printf "║  %-24s %-28s ║\n" "Tags not on remote:" "${#SKIPPED_TAGS[@]} skipped"
fi
log "╚══════════════════════════════════════════════════════╝"