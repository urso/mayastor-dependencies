#!/usr/bin/env bash

# sync-upstream.sh - Automated upstream sync script for xataio forks
#
# This script syncs changes from upstream OpenEBS repositories into xataio forks.
# It automatically detects remotes, maps branches, and handles merge operations.
#
# Exit Codes:
#   0 - Clean merge, changes applied successfully
#   1 - Merge conflicts detected
#   2 - No changes to merge (already up-to-date)
#   3 - Upstream branch doesn't exist
#   4 - Not in a git repo / xataio remote not found
#   5 - Upstream remote configuration failed
#   6 - Non-fast-forward (upstream force-pushed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Script options (must be before sourcing)
DRY_RUN=false
NO_VERIFY=false
COMMIT_CONFLICTS=false
UPSTREAM_BRANCH=""
TARGET_BRANCH=""
VERBOSE=false
XATA_REMOTE=""
UPSTREAM_REMOTE=""
XATA_ORG_OVERRIDE=""

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/sync.sh"

# Display help
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Sync changes from upstream OpenEBS repository into xataio fork.

This script automatically detects your git remotes and syncs changes from the
upstream OpenEBS repository. It handles multiple remote configurations and can
be used in environments where developers have custom remote names.

OPTIONS:
  --dry-run                      Preview changes without applying
  --no-verify                    Skip git hooks during merge (useful outside nix shell)
  --commit-conflicts             Commit conflict markers instead of leaving working tree dirty
                                 (useful for CI to create PRs with conflicts for manual resolution)
  --upstream-branch <branch>     Override auto-detected upstream branch
  --target-branch <branch>       Branch name to use for mapping (default: current branch)
                                 Note: Merge always happens into current branch
  --xata-remote <name>           Specify xataio remote name (auto-detected if not provided)
  --upstream-remote <name>       Specify upstream remote name (auto-detected/added if not provided)
  --org <name>                   Override expected organization (default: xataio, for testing use your fork org)
  --verbose                      Show detailed output
  -h, --help                     Display this help message

EXIT CODES:
  0 - Clean merge, changes applied successfully
  1 - Merge conflicts detected
  2 - No changes to merge (already up-to-date)
  3 - Upstream branch doesn't exist
  4 - Not in a git repo / xataio remote not found
  5 - Upstream remote configuration failed
  6 - Non-fast-forward (upstream force-pushed)

REMOTE DETECTION:
  The script searches all git remotes to find:
  - Xataio remote: Any remote pointing to github.com/xataio/<repo>
    Priority: origin > xata > xataio > first found
  - Upstream remote: Any remote pointing to github.com/openebs/<repo>
    Priority: upstream > openebs > first found

  If upstream remote is not found, it will be added automatically.

BRANCH MAPPING:
  Local Branch        → Upstream Branch
  develop             → upstream/develop
  develop-*           → upstream/develop
  release/2.9         → upstream/release/2.9
  release/2.9-*       → upstream/release/2.9

EXAMPLES:
  # Sync current branch with auto-detected upstream branch
  git checkout develop-prepare
  $0

  # Preview sync without applying changes
  $0 --dry-run

  # Sync from workflow (merge into current branch, use develop-prepare for mapping)
  git checkout -b sync-upstream/develop-prepare-123456
  $0 --target-branch develop-prepare

  # Override upstream branch mapping
  git checkout develop-fix
  $0 --upstream-branch develop

  # Specify custom remote names
  $0 --xata-remote origin --upstream-remote openebs-upstream

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
      --no-verify)
        NO_VERIFY=true
        shift
        ;;
      --commit-conflicts)
        COMMIT_CONFLICTS=true
        shift
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
      --verbose)
        VERBOSE=true
        set -x
        shift
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

# Main execution
main() {
  parse_args "$@"

  if [ "$DRY_RUN" = true ]; then
    warn "DRY RUN MODE - No changes will be applied"
    echo ""
  fi

  # Verify we're in a git repository
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    die "Not inside a git repository" 4
  fi

  # Get remotes (lazy initialization)
  local xata_remote upstream_remote
  get_xata_remote xata_remote
  get_upstream_remote upstream_remote

  echo ""

  # Determine target branch (for mapping only - never checkout)
  if [ -z "$TARGET_BRANCH" ]; then
    TARGET_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    log "Syncing current branch: $TARGET_BRANCH"
  else
    log "Using branch name for mapping: $TARGET_BRANCH"
    log "Merging into current branch: $(git rev-parse --abbrev-ref HEAD)"
  fi

  # Map to upstream branch
  local upstream_branch
  upstream_branch=$(map_branch "$TARGET_BRANCH" "$UPSTREAM_BRANCH")
  log "Branch mapping: $TARGET_BRANCH → $upstream_remote/$upstream_branch"

  echo ""

  # Fetch from upstream
  fetch_upstream "$upstream_remote" "$upstream_branch"

  # Check if upstream branch exists
  check_remote_branch "$upstream_remote" "$upstream_branch"

  # Determine merge target (tag or branch HEAD)
  local merge_target
  merge_target=$(determine_merge_target "$upstream_remote" "$upstream_branch")
  log "Merge target: $merge_target"

  echo ""

  # Check for divergence
  check_divergence "$merge_target" || {
    local exit_code=$?
    if [ $exit_code -eq 2 ]; then
      # Already up-to-date
      exit 2
    fi
    exit 1
  }

  echo ""

  # Attempt merge
  if merge_upstream "$merge_target" "$DRY_RUN" "$NO_VERIFY" "$COMMIT_CONFLICTS"; then
    echo ""
    success "Sync completed successfully!"
    exit 0
  else
    echo ""
    error "Sync failed due to merge conflicts"
    exit 1
  fi
}

# Run main function
main "$@"
