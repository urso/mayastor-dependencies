#!/usr/bin/env bash

# sync-release-tags.sh - Create +xata1 tags for upstream releases after syncing
#
# After a merge to a release branch, this script finds upstream tags on the
# merged commit and creates +xata1 versions pointing to our merge commit.
#
# Exit Codes:
#   0 - Tags created and pushed successfully
#   1 - Error
#   2 - Nothing to do (not a merge, no upstream tags, or all tags already exist)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Script options (must be before sourcing common.sh)
DRY_RUN=false
BRANCH=""
COMMIT=""
XATA_REMOTE=""
UPSTREAM_REMOTE=""
XATA_ORG_OVERRIDE=""

source "$SCRIPT_DIR/lib/common.sh"

# Display help
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Create +xata1 tags for upstream releases after syncing.

After a merge commit that brings in upstream changes, this script finds any
upstream version tags on the merged commit and creates corresponding +xata1
tags pointing to our merge commit.

OPTIONS:
  --dry-run                      Preview changes without applying
  --branch <name>                Specify branch to check (default: current branch)
  --commit <SHA>                 Specify commit to check (overrides --branch)
  --xata-remote <name>           Specify xataio remote name (auto-detected if not provided)
  --upstream-remote <name>       Specify upstream remote name (auto-detected/added if not provided)
  --org <name>                   Override expected organization (default: xataio, for testing use your fork org)
  -h, --help                     Display this help message

EXIT CODES:
  0 - Tags created and pushed successfully
  1 - Error
  2 - Nothing to do (not a merge, no upstream tags, or all tags already exist)

EXAMPLES:
  # Auto-detect from current branch HEAD
  $0

  # Preview what tags would be created
  $0 --dry-run

  # Check a specific branch without checking it out
  $0 --branch release/2.10

  # Check a specific commit
  $0 --commit abc123

  # Test with a local test branch and personal fork
  $0 --branch test-release/2.10 --xata-remote origin --org urso --dry-run

  # Specify upstream remote
  $0 --upstream-remote openebs-upstream

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
      --xata-remote)
        test $# -lt 2 && die "Missing value for: $1"
        XATA_REMOTE="$2"
        shift 2
        ;;
      --upstream-remote)
        test $# -lt 2 && die "Missing value for: $1"
        UPSTREAM_REMOTE="$2"
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

# Check if commit is a merge commit (has 2+ parents)
is_merge_commit() {
  local commit="$1"
  local parent_count
  parent_count=$(git rev-list --parents -n 1 "$commit" | awk '{print NF-1}')
  [ "$parent_count" -ge 2 ]
}

# Get the upstream parent (second parent) of a merge commit
get_upstream_parent() {
  local commit="$1"
  git rev-parse "${commit}^2" 2>/dev/null
}

# Find version tags pointing at a commit
find_version_tags() {
  local commit="$1"
  git tag --points-at "$commit" 2>/dev/null | grep -E '^v[0-9]' || true
}

# Find the upstream commit with tags, handling PR merge nesting
# Returns the commit SHA that has upstream tags, or empty if none found
find_upstream_tagged_commit() {
  local commit="$1"

  # Check if commit is a merge
  if ! is_merge_commit "$commit"; then
    return 1
  fi

  # Get second parent (upstream side of merge)
  local parent2
  parent2=$(get_upstream_parent "$commit") || return 1

  # Check if parent2 has upstream tags
  local tags
  tags=$(find_version_tags "$parent2")
  if [ -n "$tags" ]; then
    echo "$parent2"
    return 0
  fi

  # No tags on parent2 - check if it's also a merge (PR merge case)
  # In this case, the actual upstream commit is at parent2^2
  if is_merge_commit "$parent2"; then
    local grandparent2
    grandparent2=$(get_upstream_parent "$parent2") || return 1

    tags=$(find_version_tags "$grandparent2")
    if [ -n "$tags" ]; then
      echo "$grandparent2"
      return 0
    fi
  fi

  # No upstream tags found
  return 1
}

# Check if a tag exists
tag_exists() {
  local tag="$1"
  git rev-parse "refs/tags/$tag" &>/dev/null
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
  detect_upstream_remote

  echo ""

  # Resolve branch/commit to SHA
  local resolved commit_name commit_sha
  resolved=$(resolve_branch_or_commit "BRANCH" "COMMIT")
  read -r commit_name commit_sha <<< "$resolved"
  log "Resolved to commit: $commit_sha"

  # Check if this is a merge commit
  if ! is_merge_commit "$commit_sha"; then
    log "Commit is not a merge commit (no upstream sync detected)"
    exit 2
  fi

  log "Commit is a merge commit"

  # Fetch upstream tags first (needed for tag detection)
  log "Fetching upstream tags from $DETECTED_UPSTREAM_REMOTE..."
  git fetch "$DETECTED_UPSTREAM_REMOTE" 'refs/tags/*:refs/tags/*' 2>/dev/null || warn "Failed to fetch some tags"

  # Find the upstream commit with tags (handles both direct push and PR merge)
  local upstream_parent
  upstream_parent=$(find_upstream_tagged_commit "$commit_sha")

  if [ -z "$upstream_parent" ]; then
    log "No upstream tags found (checked HEAD^2 and HEAD^2^2)"
    exit 2
  fi

  log "Found upstream commit with tags: $upstream_parent"

  # Find version tags on that commit
  local upstream_tags
  upstream_tags=$(find_version_tags "$upstream_parent")

  log "Found upstream tags: $(echo "$upstream_tags" | tr '\n' ' ')"
  echo ""

  # Track created tags
  local created_tags=()
  local skipped_tags=()

  # Process each upstream tag
  while IFS= read -r upstream_tag; do
    [ -z "$upstream_tag" ] && continue

    local xata_tag="${upstream_tag}+xata1"

    if tag_exists "$xata_tag"; then
      warn "Tag $xata_tag already exists, skipping"
      skipped_tags+=("$xata_tag")
      continue
    fi

    if [ "$DRY_RUN" = true ]; then
      log "[DRY RUN] Would create tag: $xata_tag -> $commit_sha"
    else
      log "Creating tag: $xata_tag -> $commit_sha"
      git tag "$xata_tag" "$commit_sha" || die "Failed to create tag $xata_tag" 1
    fi

    created_tags+=("$xata_tag")
  done <<< "$upstream_tags"

  echo ""

  # Check if we created any tags
  if [ ${#created_tags[@]} -eq 0 ]; then
    log "All tags already exist, nothing to do"
    exit 2
  fi

  # Push created tags
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would push tags to $DETECTED_XATA_REMOTE: ${created_tags[*]}"
  else
    log "Pushing tags to $DETECTED_XATA_REMOTE..."
    for tag in "${created_tags[@]}"; do
      git push "$DETECTED_XATA_REMOTE" "refs/tags/$tag" --no-follow-tags || die "Failed to push tag $tag" 1
      success "Pushed tag: $tag"
    done
  fi

  echo ""
  success "Created ${#created_tags[@]} tag(s): ${created_tags[*]}"
  if [ ${#skipped_tags[@]} -gt 0 ]; then
    log "Skipped ${#skipped_tags[@]} existing tag(s): ${skipped_tags[*]}"
  fi

  exit 0
}

# Run main function
main "$@"
