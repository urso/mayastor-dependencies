#!/usr/bin/env bash

# create-xata-patch.sh - Increment +xata counter for manual patch releases
#
# When we make Xata-specific changes to a release branch, this script increments
# the tag counter (e.g., v2.9.4+xata1 → v2.9.4+xata2).
#
# Exit Codes:
#   0 - Tag created and pushed successfully
#   1 - Error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Script options (must be before sourcing)
DRY_RUN=false
BRANCH=""
COMMIT=""
BASE_VERSION=""
FORCE=false
XATA_REMOTE=""
XATA_ORG_OVERRIDE=""

source "$SCRIPT_DIR/lib/common.sh"

# Display help
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Increment the +xata counter for manual patch releases on release branches.

When Xata-specific changes are made to a release branch, this script finds the
latest +xata tag and creates the next incremented version (e.g., v2.9.4+xata1 → v2.9.4+xata2).

OPTIONS:
  --dry-run                      Preview changes without applying
  --branch <name>                Specify branch to check (default: current branch)
  --commit <SHA>                 Specify commit to tag (must be newer than last tag)
                                 Note: Use with --branch to specify which branch it belongs to,
                                       otherwise uses current branch
  --base <version>               Override base version detection (e.g., v2.9.4)
  --force                        Allow operation on non-release branches, skip commit validation
  --xata-remote <name>           Specify xataio remote name (auto-detected if not provided)
  --org <name>                   Override expected organization (default: xataio, for testing use your fork org)
  -h, --help                     Display this help message

EXIT CODES:
  0 - Tag created and pushed successfully
  1 - Error

NOTE:
  This script will create a new tag even if there are no commits since the last tag.
  This is intentional to keep version numbers aligned across all repositories.

EXAMPLES:
  # Auto-detect from current branch
  $0

  # Preview what tag would be created
  $0 --dry-run

  # Specify a branch without checking it out
  $0 --branch release/2.10

  # Tag a specific commit (must be newer than last tag)
  $0 --commit abc123def

  # Tag a specific commit on a branch without checking out
  $0 --branch release/2.10 --commit abc123def

  # Test with a non-release branch and personal fork
  $0 --branch my-test-branch --xata-remote origin --org urso --force

  # Override base version
  $0 --base v2.9.4

  # Allow on non-release branch (not recommended)
  $0 --force

  # Tag older commit, skipping validation (use with caution)
  $0 --commit abc123def --force

TAG FORMAT:
  Pattern: v<semver>+xata<N> where N is a number
  Examples:
    v2.9.4+xata1 → v2.9.4+xata2
    v2.10.0-rc.1+xata3 → v2.10.0-rc.1+xata4

REQUIREMENTS:
  - Must be on a release/* branch (or use --force)
  - At least one +xata tag must already exist
  - There must be commits since the last +xata tag
  - The new tag must not already exist
  - If --commit is specified, the commit must be:
    * Reachable from the target branch
    * Newer than (or equal to) the last +xata tag

NOTE:
  If no +xata tag exists yet, first run sync-release-tags.sh to create
  the initial +xata1 tag from an upstream release.

EOF
}

# Parse command-line arguments
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --branch)
        test $# -lt 2 && die "Missing value for: $1"
        BRANCH="$2"
        shift 2
        ;;
      --commit)
        test $# -lt 2 && die "Missing value for: $1"
        COMMIT="$2"
        shift 2
        ;;
      --base)
        test $# -lt 2 && die "Missing value for: $1"
        BASE_VERSION="$2"
        shift 2
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --xata-remote)
        test $# -lt 2 && die "Missing value for: $1"
        XATA_REMOTE="$2"
        shift 2
        ;;
      --org)
        test $# -lt 2 && die "Missing value for: $1"
        XATA_ORG_OVERRIDE="$2"
        shift 2
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown option: $1 (use --help for usage)"
        ;;
    esac
  done
}

# Check if on/using a release branch
check_release_branch() {
  local branch_name="$1"

  if ! echo "$branch_name" | grep -qE '^release/'; then
    if [ "$FORCE" = true ]; then
      warn "Not on a release/* branch (current: $branch_name), proceeding due to --force"
    else
      die "Not on a release/* branch (current: $branch_name). Use --force to override." 1
    fi
  else
    log "Using release branch: $branch_name"
  fi
}

# Find the latest +xata tag on a branch
# Args: branch_name
# Returns: latest +xata tag name on the branch
find_latest_xata_tag() {
  local branch_ref="$1"
  local tags
  # Get all +xata tags reachable from the branch HEAD, sort naturally, take last
  tags=$(git tag --merged "$branch_ref" 2>/dev/null | grep -E '\+xata[0-9]+$' | sort -V || true)

  if [ -z "$tags" ]; then
    return 1
  fi

  echo "$tags" | tail -1
}

# Parse a +xata tag into base version and counter
# Input: v2.9.4+xata1
# Output: base=v2.9.4 counter=1
parse_xata_tag() {
  local tag="$1"

  # Extract base and counter using regex
  # Pattern: v<semver>+xata<N>
  if ! echo "$tag" | grep -qE '\+xata[0-9]+$'; then
    return 1
  fi

  # Split on +xata
  local base
  local counter
  base=$(echo "$tag" | sed -E 's/\+xata[0-9]+$//')
  counter=$(echo "$tag" | sed -E 's/.*\+xata([0-9]+)$/\1/')

  if [ -z "$base" ] || [ -z "$counter" ]; then
    return 1
  fi

  echo "$base $counter"
}

# Validate commit for tagging
# Args: commit_sha, latest_tag_name, target_branch_name
# Validates:
#   1. Commit is reachable from target branch
#   2. Commit comes after (or at) the latest +xata tag in history
validate_commit_for_tag() {
  local commit="$1"
  local last_tag="$2"
  local branch="$3"

  # Resolve last tag to commit SHA
  local last_tag_sha
  last_tag_sha=$(git rev-parse "$last_tag" 2>/dev/null) || die "Failed to resolve tag: $last_tag" 1

  # Check if commit is reachable from branch
  if ! git merge-base --is-ancestor "$commit" "$branch" 2>/dev/null; then
    die "Commit $commit is not reachable from $branch" 1
  fi

  # Check if commit is newer than (or equal to) the last tag
  # This means: last_tag must be an ancestor of commit
  if ! git merge-base --is-ancestor "$last_tag_sha" "$commit" 2>/dev/null; then
    die "Commit $commit is not newer than the last tag $last_tag (tag must be an ancestor of the commit)" 1
  fi

  log "Validated: commit is reachable from $branch and newer than $last_tag"
}

# Main execution
main() {
  parse_args "$@"

  if [ "$DRY_RUN" = true ]; then
    warn "DRY RUN MODE - No changes will be applied"
    echo ""
  fi

  # Verify we're in a git repository
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    die "Not inside a git repository" 1
  fi

  # Apply org override and detect remotes
  apply_org_override
  detect_xata_remote

  echo ""

  # Resolve branch to name and commit
  local resolved target_branch target_commit
  resolved=$(resolve_branch_or_commit "$BRANCH" "$COMMIT")
  read -r target_branch target_commit <<< "$resolved"

  # Check if on/using release branch (unless --force)
  check_release_branch "$target_branch"

  echo ""

  # Find latest +xata tag on the branch
  log "Finding latest +xata tag on $target_branch..."
  local latest_tag
  if ! latest_tag=$(find_latest_xata_tag "$target_branch"); then
    die "No +xata tag found on $target_branch. Run sync-release-tags.sh first to create the initial +xata1 tag." 1
  fi

  log "Found latest +xata tag: $latest_tag"

  # Validate commit if specified (unless --force)
  if [ -n "$COMMIT" ] && [ "$FORCE" = false ]; then
    log "Validating commit $target_commit..."
    validate_commit_for_tag "$target_commit" "$latest_tag" "$target_branch"
  elif [ -n "$COMMIT" ] && [ "$FORCE" = true ]; then
    warn "Skipping commit validation due to --force"
  fi

  # Parse the tag
  local parse_result
  if ! parse_result=$(parse_xata_tag "$latest_tag"); then
    die "Failed to parse tag: $latest_tag (expected format: v<semver>+xata<N>)" 1
  fi

  local base_version counter
  read -r base_version counter <<< "$parse_result"

  log "Parsed tag: base=$base_version, counter=$counter"

  # Override base version if specified
  if [ -n "$BASE_VERSION" ]; then
    warn "Overriding base version: $base_version → $BASE_VERSION"
    base_version="$BASE_VERSION"
  fi

  # Report commits since last tag (informational only)
  local commit_count
  commit_count=$(git rev-list --count "${latest_tag}..${target_commit}" 2>/dev/null || echo "0")
  log "Commits since $latest_tag: $commit_count"

  # Increment counter
  local next_counter=$((counter + 1))
  local new_tag="${base_version}+xata${next_counter}"

  log "Next tag: $new_tag"

  # Check if new tag already exists
  if tag_exists "$new_tag"; then
    die "Tag $new_tag already exists" 1
  fi

  echo ""

  # Resolve target commit SHA
  local target_commit_sha
  target_commit_sha=$(git rev-parse "$target_commit")

  # Create the tag
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would create tag: $new_tag -> $target_commit_sha"
    log "[DRY RUN] Would push tag to $DETECTED_XATA_REMOTE"
  else
    log "Creating tag: $new_tag -> $target_commit_sha"
    git tag "$new_tag" "$target_commit_sha" || die "Failed to create tag $new_tag" 1

    log "Pushing tag to $DETECTED_XATA_REMOTE..."
    git push "$DETECTED_XATA_REMOTE" "refs/tags/$new_tag" --no-follow-tags || die "Failed to push tag $new_tag" 1
  fi

  echo ""
  success "Tag created: $latest_tag → $new_tag"
  log "Changes: $commit_count commit(s) since previous tag"

  exit 0
}

# Run main function
main "$@"
