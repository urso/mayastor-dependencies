#!/usr/bin/env bash

# create-release-branch.sh - Create release branches in fork when upstream creates releases
#
# When upstream creates a release branch (e.g., release/2.10), create the
# corresponding branch in our fork with all our features included.
#
# Exit Codes:
#   0 - Release branch created successfully
#   1 - Error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Script options (must be before sourcing)
DRY_RUN=false
FORCE=false
RELEASE_BRANCH=""
BASE_BRANCH=""
UPSTREAM_BRANCH=""
TARGET_BRANCH=""
XATA_REMOTE=""
UPSTREAM_REMOTE=""
XATA_ORG_OVERRIDE=""

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/sync.sh"

# Display help
show_help() {
  cat <<EOF
Usage: $0 <upstream-release-branch> [OPTIONS]

Create release branches in fork when upstream creates new releases.

When upstream creates a release branch (e.g., release/2.10), this script:
  1. Finds the merge-base between upstream release and upstream develop
  2. Locates the merge commit in our base branch that contains that base
  3. Creates the target branch from that merge commit
  4. Syncs with upstream release branch (brings in release-specific changes)
  5. Leaves the branch locally for review before pushing

ARGUMENTS:
  <upstream-release-branch>      Upstream release branch name (e.g., release/2.10)

OPTIONS:
  --dry-run                      Preview changes without applying
  --force                        Skip safety checks (clean working directory, branch exists)
  --base-branch <name>           Base branch to search for merges (default: current branch)
  --upstream-branch <name>       Upstream branch for merge-base (default: develop)
  --target-branch <name>         Local branch name to create (default: same as upstream-release-branch)
  --xata-remote <name>           Specify xataio remote name (auto-detected if not provided)
  --upstream-remote <name>       Specify upstream remote name (auto-detected/added if not provided)
  --org <name>                   Override expected organization (default: xataio, for testing use your fork org)
  -h, --help                     Display this help message

EXIT CODES:
  0 - Release branch created successfully
  1 - Error

EXAMPLES:
  # Create release/2.10 branch from current branch
  $0 release/2.10

  # Use specific base branch
  $0 release/2.10 --base-branch develop

  # Create with different local name
  $0 release/2.10 --target-branch test/release-2.10

  # Use different upstream develop branch
  $0 release/2.10 --upstream-branch main

  # Preview what would be created
  $0 release/2.10 --dry-run --force

  # All options
  $0 release/2.10 --base-branch test-automation --target-branch my-release \
     --upstream-branch develop --force

PREREQUISITES:
  - Release base must exist in your base branch (sync with upstream first if needed)
  - Working directory must be clean (no uncommitted changes, or use --force)

NOTE:
  This script does NOT push the branch automatically. Review the branch first,
  then push manually or via a GitHub workflow.

EOF
}

# Parse command-line arguments
parse_args() {
  # Check for help first
  for arg in "$@"; do
    if [ "$arg" = "-h" ] || [ "$arg" = "--help" ]; then
      show_help
      exit 0
    fi
  done

  # First positional argument is release branch
  if [ "$#" -eq 0 ] || [[ "$1" == -* ]]; then
    die "Missing required argument: <release-branch> (use --help for usage)"
  fi

  RELEASE_BRANCH="$1"
  shift

  # Parse options
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --base-branch)
        test $# -lt 2 && die "Missing value for: $1"
        BASE_BRANCH="$2"
        shift 2
        ;;
      --upstream-branch)
        test $# -lt 2 && die "Missing value for: $1"
        UPSTREAM_BRANCH="$2"
        shift 2
        ;;
      --target-branch)
        test $# -lt 2 && die "Missing value for: $1"
        TARGET_BRANCH="$2"
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
      *)
        die "Unknown option: $1 (use --help for usage)"
        ;;
    esac
  done
}

# Validate release branch format (release/X.Y)
parse_release_branch() {
  local branch="$1"

  if ! echo "$branch" | grep -qE '^release/[0-9]+\.[0-9]+$'; then
    die "Invalid release branch format: $branch (expected: release/X.Y, e.g., release/2.10)" 1
  fi

  log "Validated release branch format: $branch"
}

# Detect current branch or use specified base branch
detect_base_branch() {
  if [ -n "$BASE_BRANCH" ]; then
    log "Using specified base branch: $BASE_BRANCH"
    echo "$BASE_BRANCH"
    return 0
  fi

  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

  if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
    die "Not on a named branch (detached HEAD). Please checkout a branch or use --base-branch" 1
  fi

  log "Using current branch as base: $current_branch"
  echo "$current_branch"
}

# Get upstream develop branch (default: develop)
get_upstream_develop_branch() {
  if [ -n "$UPSTREAM_BRANCH" ]; then
    log "Using specified upstream branch: $UPSTREAM_BRANCH"
    echo "$UPSTREAM_BRANCH"
  else
    log "Using default upstream branch: develop"
    echo "develop"
  fi
}

# Get target branch name (default: same as release branch)
get_target_branch() {
  if [ -n "$TARGET_BRANCH" ]; then
    log "Using specified target branch: $TARGET_BRANCH"
    echo "$TARGET_BRANCH"
  else
    log "Using release branch name as target: $RELEASE_BRANCH"
    echo "$RELEASE_BRANCH"
  fi
}

# Check for uncommitted changes
check_clean_working_directory() {
  if [ "$FORCE" = true ]; then
    warn "Skipping clean working directory check (--force)"
    return 0
  fi

  if [ -n "$(git status --porcelain)" ]; then
    die "Uncommitted changes detected. Please commit or stash your changes first." 1
  fi
  log "Working directory is clean"
}

# Find the merge-base between upstream release and upstream develop
find_release_base() {
  local release_branch="$1"
  local upstream_remote="$2"
  local upstream_develop="$3"

  log "Finding merge-base between $upstream_remote/$release_branch and $upstream_remote/$upstream_develop..."

  local base
  base=$(git merge-base "$upstream_remote/$release_branch" "$upstream_remote/$upstream_develop" 2>/dev/null || true)

  if [ -z "$base" ]; then
    die "Could not find merge-base between $upstream_remote/$release_branch and $upstream_remote/$upstream_develop. Ensure branches exist." 1
  fi

  log "Found release base: $base"
  echo "$base"
}

# Find merge commit in our base branch that contains the release base
# Returns the merge commit SHA, or exits with error if not found
find_merge_with_base() {
  local base_commit="$1"
  local base_branch="$2"

  log "Searching for merge commit in $base_branch that contains base $base_commit..."

  # Get all merge commits in base branch (most recent first)
  # This searches the commit history reachable from base_branch
  local merge_commits
  merge_commits=$(git rev-list --merges "$base_branch" 2>/dev/null || true)

  if [ -z "$merge_commits" ]; then
    die "No merge commits found in $base_branch" 1
  fi

  # Iterate through merge commits
  while IFS= read -r merge; do
    [ -z "$merge" ] && continue

    # Get second parent (upstream side of merge)
    local parent2
    parent2=$(git rev-parse "$merge^2" 2>/dev/null || continue)

    # Check if parent2 contains or equals the base
    if git merge-base --is-ancestor "$base_commit" "$parent2" 2>/dev/null; then
      log "Found merge commit: $merge (upstream parent: $parent2)"
      echo "$merge"
      return 0
    fi
  done <<< "$merge_commits"

  # No merge found containing the base
  die "Release base not found in $base_branch. Please sync $base_branch with upstream first." 1
}

# Check if branch already exists locally or remotely
check_branch_exists() {
  local branch="$1"
  local xata_remote="$2"

  if [ "$FORCE" = true ]; then
    warn "Skipping branch exists check (--force)"

    # Clean up existing local branch if needed
    if git rev-parse --verify "$branch" &>/dev/null; then
      warn "Deleting existing local branch: $branch"
      git branch -D "$branch" 2>/dev/null || true
    fi

    return 0
  fi

  # Check local branch
  if git rev-parse --verify "$branch" &>/dev/null; then
    die "Branch $branch already exists locally. Delete it first if you want to recreate it." 1
  fi

  # Check remote branch
  if git rev-parse --verify "$xata_remote/$branch" &>/dev/null; then
    die "Branch $branch already exists on remote $xata_remote. Delete it first if you want to recreate it." 1
  fi

  log "Confirmed branch $branch does not exist"
}

# Create release branch from merge commit (without checking it out)
create_branch() {
  local branch_name="$1"
  local from_commit="$2"

  log "Creating branch $branch_name from commit $from_commit..."

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would run: git branch $branch_name $from_commit"
  else
    git branch "$branch_name" "$from_commit" || die "Failed to create branch $branch_name" 1
    success "Created branch: $branch_name"
  fi
}

# Sync with upstream release branch
# This brings in release-specific changes and updates .gitmodules
# Uses lib/sync.sh functions directly to avoid bootstrap issues
sync_with_upstream() {
  local target_branch="$1"
  local upstream_branch="$2"

  log "Syncing $target_branch with upstream/$upstream_branch..."

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would sync $target_branch with upstream/$upstream_branch"
    return 0
  fi

  # Save current branch so we can return to it
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  # Checkout target branch if different from current
  if [ "$target_branch" != "$current_branch" ]; then
    log "Checking out $target_branch for sync..."
    git checkout "$target_branch" || die "Failed to checkout $target_branch" 1
  fi

  # Use sync library functions directly (already loaded from correct branch)
  fetch_upstream "$DETECTED_UPSTREAM_REMOTE" "$upstream_branch"
  check_remote_branch "$DETECTED_UPSTREAM_REMOTE" "$upstream_branch"

  local merge_target
  merge_target=$(determine_merge_target "$DETECTED_UPSTREAM_REMOTE" "$upstream_branch")
  log "Merge target: $merge_target"

  echo ""

  # Check for divergence (returns 2 if up-to-date)
  check_divergence "$merge_target" || {
    local exit_code=$?
    if [ $exit_code -eq 2 ]; then
      log "Already up-to-date with upstream (no changes to sync)"
      # Checkout back to original branch
      if [ "$target_branch" != "$current_branch" ]; then
        log "Returning to $current_branch..."
        git checkout "$current_branch" || warn "Failed to checkout back to $current_branch"
      fi
      return 0
    fi
    # Checkout back even on error
    if [ "$target_branch" != "$current_branch" ]; then
      git checkout "$current_branch" 2>/dev/null || true
    fi
    die "Failed to check divergence" 1
  }

  echo ""

  # Perform merge (using FORCE for no_verify)
  if ! merge_upstream "$merge_target" "$DRY_RUN" "$FORCE"; then
    error "Merge conflicts detected during sync"
    # Checkout back to original branch even on failure
    if [ "$target_branch" != "$current_branch" ]; then
      log "Returning to $current_branch..."
      git checkout "$current_branch" 2>/dev/null || warn "Failed to checkout back to $current_branch"
    fi
    die "Merge conflicts detected. Please resolve manually." 1
  fi

  success "Successfully synced with upstream/$upstream_branch"

  # Checkout back to original branch
  if [ "$target_branch" != "$current_branch" ]; then
    log "Returning to $current_branch..."
    git checkout "$current_branch" || warn "Failed to checkout back to $current_branch"
  fi
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

  # Validate release branch format
  parse_release_branch "$RELEASE_BRANCH"

  # Detect branch configuration
  local base_branch upstream_develop target_branch
  base_branch=$(detect_base_branch)
  upstream_develop=$(get_upstream_develop_branch)
  target_branch=$(get_target_branch)

  # Check for clean working directory
  check_clean_working_directory

  # Apply org override and detect remotes
  apply_org_override
  detect_xata_remote

  # Detect or configure upstream remote
  detect_upstream_remote

  echo ""

  log "Configuration:"
  log "  Base branch: $base_branch (will search commit history for merges)"
  log "  Upstream develop: $DETECTED_UPSTREAM_REMOTE/$upstream_develop"
  log "  Upstream release: $DETECTED_UPSTREAM_REMOTE/$RELEASE_BRANCH"
  log "  Target branch: $target_branch"
  echo ""

  # Check if branch already exists
  check_branch_exists "$target_branch" "$DETECTED_XATA_REMOTE"

  # Fetch upstream to ensure we have latest branches
  log "Fetching from $DETECTED_UPSTREAM_REMOTE..."
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would run: git fetch $DETECTED_UPSTREAM_REMOTE"
  else
    git fetch "$DETECTED_UPSTREAM_REMOTE" || die "Failed to fetch from $DETECTED_UPSTREAM_REMOTE" 1
  fi

  # Fetch from our remote to ensure we have latest base branch
  log "Fetching from $DETECTED_XATA_REMOTE..."
  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would run: git fetch $DETECTED_XATA_REMOTE"
  else
    git fetch "$DETECTED_XATA_REMOTE" || die "Failed to fetch from $DETECTED_XATA_REMOTE" 1
  fi

  echo ""

  # Find the release base
  local release_base
  release_base=$(find_release_base "$RELEASE_BRANCH" "$DETECTED_UPSTREAM_REMOTE" "$upstream_develop")

  # Find the merge commit in our base branch that contains the release base
  local merge_commit
  merge_commit=$(find_merge_with_base "$release_base" "$base_branch")

  echo ""
  log "Creating target branch $target_branch from merge commit $merge_commit"
  echo ""

  # Create the branch
  create_branch "$target_branch" "$merge_commit"

  # Sync with upstream release branch (brings in release-specific changes and updates .gitmodules)
  echo ""
  sync_with_upstream "$target_branch" "$RELEASE_BRANCH"

  echo ""
  success "Release branch $target_branch created successfully!"
  log "Branch is based on merge commit: $merge_commit"
  log "This commit contains upstream release base: $release_base"
  echo ""
  log "Next steps:"
  log "  1. Switch to branch: git checkout $target_branch"
  log "  2. Review the branch: git log --oneline --graph -20"
  log "  3. Verify changes: git diff $DETECTED_UPSTREAM_REMOTE/$RELEASE_BRANCH..$target_branch"
  log "  4. Push when ready: git push $DETECTED_XATA_REMOTE $target_branch --no-follow-tags"
  echo ""
  warn "IMPORTANT: Always use --no-follow-tags when pushing release branches!"
  warn "This prevents accidentally pushing upstream tags to your fork."
  warn "Upstream tags should only exist as +xata1 versions created by sync-release-tags.sh"

  exit 0
}

# Run main function
main "$@"
