#!/usr/bin/env bash

# common.sh - Shared library for xataio sync scripts
#
# This file is meant to be sourced, not executed directly.
# Usage: source "$SCRIPT_DIR/lib/common.sh"

# Guard against double-sourcing
if [ -n "${_XATA_COMMON_SOURCED:-}" ]; then
  return 0
fi
_XATA_COMMON_SOURCED=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration (can be overridden by scripts before calling detect functions)
UPSTREAM_ORG="${UPSTREAM_ORG:-openebs}"
XATA_ORG="${XATA_ORG:-xataio}"
DEFAULT_UPSTREAM_REMOTE_NAME="upstream"

# Detected values (set by detect functions, used by calling scripts)
DETECTED_XATA_REMOTE=""
DETECTED_UPSTREAM_REMOTE=""
REPO_NAME=""

# Utility functions
log() {
  echo -e "${BLUE}[INFO]${NC} $*" >&2
}

success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
  local exit_code="${2:-1}"
  error "$1"
  exit "$exit_code"
}

# Extract org name from git URL
get_org_from_url() {
  local git_url="$1"
  if echo "$git_url" | grep -q "^git@github.com:"; then
    # git@github.com:xataio/repo.git => xataio
    echo "$git_url" | sed -E 's|^git@github\.com:([^/]+)/.*|\1|'
  elif echo "$git_url" | grep -q "^https://github.com/"; then
    # https://github.com/xataio/repo.git => xataio
    echo "$git_url" | sed -E 's|^https://github\.com/([^/]+)/.*|\1|'
  else
    echo ""
  fi
}

# Extract repo name from git URL
get_repo_from_url() {
  local git_url="$1"
  local repo=""

  if echo "$git_url" | grep -q "^git@github.com:"; then
    # git@github.com:xataio/mayastor-dependencies.git => mayastor-dependencies
    repo=$(echo "$git_url" | sed -E 's|^git@github\.com:[^/]+/(.+)$|\1|')
  elif echo "$git_url" | grep -q "^https://github.com/"; then
    # https://github.com/xataio/mayastor-dependencies.git => mayastor-dependencies
    repo=$(echo "$git_url" | sed -E 's|^https://github\.com/[^/]+/(.+)$|\1|')
  else
    echo ""
    return
  fi

  # Remove .git suffix if present
  echo "$repo" | sed 's/\.git$//'
}

# Find remote by organization
# Args: org_name, preferred_names...
# Returns: remote name via stdout (empty if not found)
find_remote_by_org() {
  local target_org="$1"
  shift
  local preferred_names=("$@")

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    return 1
  fi

  # Get all remotes and their URLs
  local remotes
  remotes=$(git remote -v | grep '(fetch)' | awk '{print $1}')

  local found_remotes=()

  # Find all remotes pointing to the target org
  for remote in $remotes; do
    local url
    url=$(git config --get remote."$remote".url || true)
    if [ -n "$url" ]; then
      local org
      org=$(get_org_from_url "$url")
      if [ "$org" = "$target_org" ]; then
        found_remotes+=("$remote")
      fi
    fi
  done

  # If none found, return empty
  if [ ${#found_remotes[@]} -eq 0 ]; then
    return 1
  fi

  # If only one found, return it
  if [ ${#found_remotes[@]} -eq 1 ]; then
    echo "${found_remotes[0]}"
    return 0
  fi

  # Multiple found - use preference order
  for preferred in "${preferred_names[@]}"; do
    for found in "${found_remotes[@]}"; do
      if [ "$found" = "$preferred" ]; then
        echo "$found"
        return 0
      fi
    done
  done

  # No preferred name matched, return first found
  echo "${found_remotes[0]}"
  return 0
}

# Generic remote detection and verification
# Args: org_name, user_specified_remote, preferred_names...
# Returns: remote name via stdout, exits on error if user-specified is invalid
find_or_verify_remote() {
  local org="$1"
  local user_specified="$2"
  shift 2
  local preferred_names=("$@")

  if [ -n "$user_specified" ]; then
    # User specified - verify it exists and points to correct org
    local url
    url=$(git config --get remote."$user_specified".url 2>/dev/null || true)
    if [ -z "$url" ]; then
      die "Specified remote '$user_specified' does not exist" 4
    fi

    local remote_org
    remote_org=$(get_org_from_url "$url")
    if [ "$remote_org" != "$org" ]; then
      die "Specified remote '$user_specified' does not point to $org (found: $remote_org). Use --org $remote_org to override." 4
    fi

    echo "$user_specified"
    return 0
  else
    # Auto-detect with preferred names
    local detected
    detected=$(find_remote_by_org "$org" "${preferred_names[@]}" || true)
    echo "$detected"
    return 0
  fi
}

# Apply org override if specified
# Call this before detect_xata_remote() to override the expected organization
# Requires: XATA_ORG_OVERRIDE (optional, from script's --org flag)
# Sets: XATA_ORG
apply_org_override() {
  if [ -n "${XATA_ORG_OVERRIDE:-}" ]; then
    XATA_ORG="$XATA_ORG_OVERRIDE"
    log "Using custom organization: $XATA_ORG"
  fi
}

# Resolve branch or commit to a commit SHA
# Args: branch_value (optional), commit_value (optional)
# Returns: "branch_name commit_sha" via stdout
# Example: resolve_branch_or_commit "$BRANCH" "$COMMIT"
resolve_branch_or_commit() {
  local branch_value="${1:-}"
  local commit_value="${2:-}"

  local target_ref target_name

  # Determine target ref and name
  # If both commit and branch are specified, use branch name but commit SHA
  # Priority for ref: explicit commit > explicit branch > current HEAD
  # Priority for name: explicit branch > current branch > commit SHA
  if [ -n "$commit_value" ]; then
    target_ref="$commit_value"
    if [ -n "$branch_value" ]; then
      target_name="$branch_value"
      log "Using specified commit: $commit_value (from branch: $branch_value)"
    else
      target_name="$commit_value"
      log "Using specified commit: $commit_value"
    fi
  elif [ -n "$branch_value" ]; then
    target_ref="$branch_value"
    target_name="$branch_value"
    log "Using specified branch: $branch_value"
  else
    target_ref="HEAD"
    target_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
    if [ "$target_name" = "HEAD" ]; then
      die "Not on a named branch (detached HEAD state). Use --branch to specify a branch." 1
    fi
    log "Using current branch: $target_name"
  fi

  # Resolve to commit SHA
  local target_sha
  target_sha=$(git rev-parse "$target_ref" 2>/dev/null) || die "Invalid ref: $target_ref" 1

  # Return both name and SHA
  echo "$target_name $target_sha"
}

# Detect xataio remote
# Requires: XATA_REMOTE (optional, user-specified)
# Sets: DETECTED_XATA_REMOTE, REPO_NAME
detect_xata_remote() {
  DETECTED_XATA_REMOTE=$(find_or_verify_remote "$XATA_ORG" "${XATA_REMOTE:-}" "origin" "xata" "xataio")

  if [ -z "$DETECTED_XATA_REMOTE" ]; then
    die "No remote found pointing to github.com/$XATA_ORG/. Please specify with --xata-remote" 4
  fi

  if [ -n "${XATA_REMOTE:-}" ]; then
    log "Using specified xata remote: $DETECTED_XATA_REMOTE"
  else
    log "Auto-detected xata remote: $DETECTED_XATA_REMOTE"
  fi

  # Extract repo name from xata remote
  local url
  url=$(git config --get remote."$DETECTED_XATA_REMOTE".url)
  REPO_NAME=$(get_repo_from_url "$url")

  if [ -z "$REPO_NAME" ]; then
    die "Could not extract repository name from remote URL: $url" 4
  fi

  success "Working with repository: $XATA_ORG/$REPO_NAME"
}

# Detect or configure upstream remote
# Requires: UPSTREAM_REMOTE (optional, user-specified), REPO_NAME (must be set)
# Sets: DETECTED_UPSTREAM_REMOTE
detect_upstream_remote() {
  local detected
  detected=$(find_or_verify_remote "$UPSTREAM_ORG" "${UPSTREAM_REMOTE:-}" "upstream" "openebs")

  if [ -n "$detected" ]; then
    # Found a remote - verify it points to the same repo
    local url
    url=$(git config --get remote."$detected".url)
    local remote_repo
    remote_repo=$(get_repo_from_url "$url")

    if [ "$remote_repo" = "$REPO_NAME" ]; then
      DETECTED_UPSTREAM_REMOTE="$detected"

      if [ -n "${UPSTREAM_REMOTE:-}" ]; then
        log "Using specified upstream remote: $DETECTED_UPSTREAM_REMOTE"
      else
        log "Auto-detected upstream remote: $DETECTED_UPSTREAM_REMOTE"
      fi

      local upstream_url
      upstream_url=$(git config --get remote."$DETECTED_UPSTREAM_REMOTE".url)
      success "Upstream remote configured: $DETECTED_UPSTREAM_REMOTE -> $upstream_url"
      return
    else
      warn "Found upstream remote '$detected' points to different repo: $remote_repo (expected: $REPO_NAME)"
      warn "Will add new remote for $UPSTREAM_ORG/$REPO_NAME"
    fi
  fi

  # Not found or points to wrong repo - add it
  add_upstream_remote
}

# Add upstream remote
# Requires: REPO_NAME (must be set)
# Sets: DETECTED_UPSTREAM_REMOTE
add_upstream_remote() {
  local upstream_url="https://github.com/${UPSTREAM_ORG}/${REPO_NAME}.git"
  local remote_name="$DEFAULT_UPSTREAM_REMOTE_NAME"

  # Find an available name if default is taken
  local counter=2
  while git config --get remote."$remote_name".url &>/dev/null; do
    remote_name="${DEFAULT_UPSTREAM_REMOTE_NAME}${counter}"
    ((counter++))
  done

  log "Adding upstream remote '$remote_name': $upstream_url"

  # Always add the remote (even in dry-run) - it's needed for fetching and is harmless
  git remote add "$remote_name" "$upstream_url" || die "Failed to add upstream remote" 5

  # Security: Disable push to upstream to prevent accidental pushes
  log "Disabling push to upstream remote (security measure)"
  git remote set-url --push "$remote_name" no_push || warn "Could not disable push for upstream remote"

  DETECTED_UPSTREAM_REMOTE="$remote_name"
  success "Added upstream remote: $remote_name -> $upstream_url (push disabled)"
}

# Fetch from a remote branch
# Args: remote_name, branch_name
fetch_upstream() {
  local remote="$1"
  local branch="$2"

  log "Fetching tags from $remote..."
  git fetch "$remote" 'refs/tags/*:refs/tags/*' 2>/dev/null || true

  log "Fetching from $remote/$branch..."

  if ! git fetch "$remote" "$branch" 2>&1; then
    die "Failed to fetch from $remote" 5
  fi

  success "Fetched from $remote/$branch"
}

# Check if a remote branch exists
# Args: remote_name, branch_name
check_remote_branch() {
  local remote="$1"
  local branch="$2"

  if ! git rev-parse --verify "$remote/$branch" &>/dev/null; then
    die "Remote branch does not exist: $remote/$branch" 3
  fi
}

# Check if a tag exists
# Args: tag_name
tag_exists() {
  local tag="$1"
  git rev-parse "refs/tags/$tag" &>/dev/null
}
