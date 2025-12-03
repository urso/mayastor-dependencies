#!/usr/bin/env bash

# common.sh - Shared library for xataio sync scripts
#
# This file is meant to be sourced, not executed directly.
# Usage: source "$SCRIPT_DIR/lib/common.sh"
#
# PUBLIC API (lazy getters):
#   get_xata_org        - Returns the xata organization name
#   get_repo_name       - Returns the repository name (detected from xata remote)
#   get_xata_remote     - Returns the xata remote name (auto-detected or user-specified)
#   get_upstream_remote - Returns the upstream remote name (auto-detected or added)
#
# CONFIGURATION (set these BEFORE calling getters):
#   XATA_ORG_OVERRIDE   - Override xata org (from --org flag)
#   XATA_REMOTE         - User-specified xata remote (from --xata-remote flag)
#   UPSTREAM_REMOTE     - User-specified upstream remote (from --upstream-remote flag)
#
# All getters are lazy: they detect/initialize on first call and cache the result.
# Dependencies between getters resolve automatically.

# Guard against double-sourcing
if [ -n "${_XATA_COMMON_SOURCED:-}" ]; then
  return 0
fi
_XATA_COMMON_SOURCED=1


# =============================================================================
# PRIVATE STATE (do not access directly - use getters)
# =============================================================================

_XATA_ORG=""
_XATA_REMOTE=""
_UPSTREAM_REMOTE=""
_REPO_NAME=""

# Configuration defaults
_DEFAULT_XATA_ORG="xataio"
_DEFAULT_UPSTREAM_ORG="openebs"
_DEFAULT_UPSTREAM_REMOTE_NAME="upstream"

# =============================================================================
# LOGGING UTILITIES
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# =============================================================================
# URL PARSING HELPERS (internal)
# =============================================================================

# Extract org name from git URL
_parse_org_from_url() {
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
_parse_repo_from_url() {
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

# =============================================================================
# REMOTE DETECTION HELPERS (internal)
# =============================================================================

# Find remote by organization
# Args: org_name, preferred_names...
# Returns: remote name via stdout (empty if not found)
_find_remote_by_org() {
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
      org=$(_parse_org_from_url "$url")
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
_find_or_verify_remote() {
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
    remote_org=$(_parse_org_from_url "$url")
    if [ "$remote_org" != "$org" ]; then
      die "Specified remote '$user_specified' does not point to $org (found: $remote_org). Use --org $remote_org to override." 4
    fi

    echo "$user_specified"
    return 0
  else
    # Auto-detect with preferred names
    local detected
    detected=$(_find_remote_by_org "$org" "${preferred_names[@]}" || true)
    echo "$detected"
    return 0
  fi
}

# =============================================================================
# ADD UPSTREAM REMOTE (internal)
# =============================================================================

# Add upstream remote
# Args: repo_name
# Returns: remote name via stdout
_add_upstream_remote() {
  local repo_name="$1"
  local upstream_url="https://github.com/${_DEFAULT_UPSTREAM_ORG}/${repo_name}.git"
  local remote_name="$_DEFAULT_UPSTREAM_REMOTE_NAME"

  # Find an available name if default is taken
  local counter=2
  while git config --get remote."$remote_name".url &>/dev/null; do
    remote_name="${_DEFAULT_UPSTREAM_REMOTE_NAME}${counter}"
    ((counter++))
  done

  log "Adding upstream remote '$remote_name': $upstream_url"
  git remote add "$remote_name" "$upstream_url" || die "Failed to add upstream remote" 5

  # Security: Disable push to upstream
  log "Disabling push to upstream remote (security measure)"
  git remote set-url --push "$remote_name" no_push || warn "Could not disable push for upstream remote"

  success "Added upstream remote: $remote_name -> $upstream_url (push disabled)"
  echo "$remote_name"
}

# =============================================================================
# PUBLIC API - LAZY GETTERS (using namerefs)
# =============================================================================
#
# Usage: Pass the variable name (without $) to receive the result.
#   get_xata_remote my_var
#   echo "$my_var"
#
# The getters are lazy: detection happens once, results are cached.

# Get the xata organization name
# Uses XATA_ORG_OVERRIDE if set, otherwise defaults to "xataio"
get_xata_org() {
  local -n _result="$1"

  if [ -z "$_XATA_ORG" ]; then
    if [ -n "${XATA_ORG_OVERRIDE:-}" ]; then
      _XATA_ORG="$XATA_ORG_OVERRIDE"
      log "Using custom organization: $_XATA_ORG"
    else
      _XATA_ORG="$_DEFAULT_XATA_ORG"
    fi
  fi

  _result="$_XATA_ORG"
}

# Get the xata remote name
# Auto-detects or uses XATA_REMOTE if specified
# Also populates _REPO_NAME as a side effect
get_xata_remote() {
  local -n _result="$1"

  if [ -z "$_XATA_REMOTE" ]; then
    local org
    get_xata_org org

    _XATA_REMOTE=$(_find_or_verify_remote "$org" "${XATA_REMOTE:-}" "origin" "xata" "xataio")

    if [ -z "$_XATA_REMOTE" ]; then
      die "No remote found pointing to github.com/$org/. Please specify with --xata-remote" 4
    fi

    if [ -n "${XATA_REMOTE:-}" ]; then
      log "Using specified xata remote: $_XATA_REMOTE"
    else
      log "Auto-detected xata remote: $_XATA_REMOTE"
    fi

    # Extract repo name from xata remote
    local url
    url=$(git config --get remote."$_XATA_REMOTE".url)
    _REPO_NAME=$(_parse_repo_from_url "$url")

    if [ -z "$_REPO_NAME" ]; then
      die "Could not extract repository name from remote URL: $url" 4
    fi

    success "Working with repository: $org/$_REPO_NAME"
  fi

  _result="$_XATA_REMOTE"
}

# Get the repository name
# Triggers xata remote detection if not already done
get_repo_name() {
  local -n _result="$1"

  if [ -z "$_REPO_NAME" ]; then
    local _unused
    get_xata_remote _unused  # Triggers detection, sets _REPO_NAME
  fi

  _result="$_REPO_NAME"
}

# Get the upstream remote name
# Auto-detects, verifies, or creates the upstream remote
get_upstream_remote() {
  local -n _result="$1"

  if [ -z "$_UPSTREAM_REMOTE" ]; then
    local repo_name
    get_repo_name repo_name  # Ensures xata remote is detected first

    local detected
    detected=$(_find_or_verify_remote "$_DEFAULT_UPSTREAM_ORG" "${UPSTREAM_REMOTE:-}" "upstream" "openebs")

    if [ -n "$detected" ]; then
      # Found a remote - verify it points to the same repo
      local url
      url=$(git config --get remote."$detected".url)
      local remote_repo
      remote_repo=$(_parse_repo_from_url "$url")

      if [ "$remote_repo" = "$repo_name" ]; then
        _UPSTREAM_REMOTE="$detected"

        if [ -n "${UPSTREAM_REMOTE:-}" ]; then
          log "Using specified upstream remote: $_UPSTREAM_REMOTE"
        else
          log "Auto-detected upstream remote: $_UPSTREAM_REMOTE"
        fi

        local upstream_url
        upstream_url=$(git config --get remote."$_UPSTREAM_REMOTE".url)
        success "Upstream remote configured: $_UPSTREAM_REMOTE -> $upstream_url"
      else
        warn "Found upstream remote '$detected' points to different repo: $remote_repo (expected: $repo_name)"
        warn "Will add new remote for $_DEFAULT_UPSTREAM_ORG/$repo_name"
        _UPSTREAM_REMOTE=$(_add_upstream_remote "$repo_name")
      fi
    else
      # Not found - add it
      _UPSTREAM_REMOTE=$(_add_upstream_remote "$repo_name")
    fi
  fi

  _result="$_UPSTREAM_REMOTE"
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

# =============================================================================
# UTILITY FUNCTIONS (public)
# =============================================================================

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
