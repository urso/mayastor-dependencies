#!/usr/bin/env bash

# verify-release-branch.sh - Verify release branch is based on correct upstream commit
#
# This script checks if a xataio release branch is correctly based on the
# upstream release branch point, and reports any discrepancies.
#
# Exit Codes:
#   0 - Branch is correctly based
#   1 - Branch has issues (based on wrong commit, contains unwanted changes)
#   2 - Branch doesn't exist or other error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities if available
# Output functions - all to stdout for consistent ordering
log() { echo -e "\033[0;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[0;32m[SUCCESS]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }
die() { error "$1"; exit "${2:-1}"; }

# Script options
RELEASE_BRANCH=""
VERBOSE=false
CHECK_REMOTE=false
XATA_REMOTE=""
UPSTREAM_REMOTE=""

show_help() {
  cat <<EOF
Usage: $0 <release-branch> [OPTIONS]

Verify that a release branch is correctly based on the upstream release branch point.

By default, checks the LOCAL branch. Use --remote to check the remote branch instead.

ARGUMENTS:
  <release-branch>              Release branch name (e.g., release/2.10)

OPTIONS:
  --remote                      Check remote branch instead of local (fetches first)
  --xata-remote <name>          Specify xataio remote name (auto-detected if not provided)
  --upstream-remote <name>      Specify upstream remote name (auto-detected if not provided)
  --verbose                     Show detailed output
  -h, --help                    Display this help message

CHECKS PERFORMED:
  1. Verifies branch exists (local or remote depending on --remote flag)
  2. Finds the merge-base between upstream/release and upstream/develop
  3. Checks if release branch contains commits past the release base
  4. Reports any files that differ unexpectedly between branches

EXIT CODES:
  0 - Branch is correctly based
  1 - Branch has issues
  2 - Branch doesn't exist or other error

EXAMPLES:
  $0 release/2.10                  # Check local branch
  $0 release/2.10 --remote         # Check remote branch
  $0 release/2.10 --verbose

EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        exit 0
        ;;
      --remote)
        CHECK_REMOTE=true
        shift
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
      --verbose)
        VERBOSE=true
        shift
        ;;
      -*)
        die "Unknown option: $1 (use --help for usage)" 2
        ;;
      *)
        # Positional argument
        if [ -z "$RELEASE_BRANCH" ]; then
          RELEASE_BRANCH="$1"
        else
          die "Unexpected argument: $1 (use --help for usage)" 2
        fi
        shift
        ;;
    esac
  done

  if [ -z "$RELEASE_BRANCH" ]; then
    die "Missing required argument: <release-branch> (use --help for usage)" 2
  fi
}

# Auto-detect remote by organization
find_remote_by_org() {
  local target_org="$1"
  local remotes
  remotes=$(git remote -v | grep '(fetch)' | awk '{print $1}')

  for remote in $remotes; do
    local url
    url=$(git config --get remote."$remote".url || true)
    if echo "$url" | grep -q "$target_org"; then
      echo "$remote"
      return 0
    fi
  done
  return 1
}

detect_remotes() {
  if [ -z "$XATA_REMOTE" ]; then
    XATA_REMOTE=$(find_remote_by_org "xataio" || echo "")
    if [ -z "$XATA_REMOTE" ]; then
      die "Could not auto-detect xataio remote. Use --xata-remote" 2
    fi
  fi

  if [ -z "$UPSTREAM_REMOTE" ]; then
    UPSTREAM_REMOTE=$(find_remote_by_org "openebs" || echo "")
    if [ -z "$UPSTREAM_REMOTE" ]; then
      die "Could not auto-detect upstream remote. Use --upstream-remote" 2
    fi
  fi

  log "Using xataio remote: $XATA_REMOTE"
  log "Using upstream remote: $UPSTREAM_REMOTE"
}

main() {
  parse_args "$@"

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    die "Not inside a git repository" 2
  fi

  detect_remotes

  local repo_name
  repo_name=$(basename "$(git rev-parse --show-toplevel)")
  echo ""
  log "Verifying $RELEASE_BRANCH in $repo_name"
  echo ""

  # Determine which branch ref to check (local or remote)
  local check_ref
  if [ "$CHECK_REMOTE" = true ]; then
    check_ref="$XATA_REMOTE/$RELEASE_BRANCH"
    log "Checking REMOTE branch: $check_ref"
    # Fetch latest when checking remote
    log "Fetching latest from remotes..."
    git fetch "$UPSTREAM_REMOTE" --quiet 2>/dev/null || die "Failed to fetch from $UPSTREAM_REMOTE" 2
    git fetch "$XATA_REMOTE" --quiet 2>/dev/null || die "Failed to fetch from $XATA_REMOTE" 2
  else
    check_ref="$RELEASE_BRANCH"
    log "Checking LOCAL branch: $check_ref"
    # Still fetch upstream to compare against
    log "Fetching upstream..."
    git fetch "$UPSTREAM_REMOTE" --quiet 2>/dev/null || die "Failed to fetch from $UPSTREAM_REMOTE" 2
  fi

  # Check branches exist
  if ! git rev-parse --verify "$UPSTREAM_REMOTE/$RELEASE_BRANCH" &>/dev/null; then
    die "Upstream branch $UPSTREAM_REMOTE/$RELEASE_BRANCH does not exist" 2
  fi

  if ! git rev-parse --verify "$check_ref" &>/dev/null; then
    die "Branch $check_ref does not exist" 2
  fi

  # Find merge-base between upstream release and upstream develop
  local release_base
  release_base=$(git merge-base "$UPSTREAM_REMOTE/$RELEASE_BRANCH" "$UPSTREAM_REMOTE/develop" 2>/dev/null || true)

  if [ -z "$release_base" ]; then
    die "Could not find merge-base between $UPSTREAM_REMOTE/$RELEASE_BRANCH and $UPSTREAM_REMOTE/develop" 2
  fi

  local release_base_short="${release_base:0:7}"
  local release_base_desc
  release_base_desc=$(git log --oneline -1 "$release_base")

  log "Upstream release base: $release_base_desc"

  # Get branch HEADs
  local upstream_head check_head
  upstream_head=$(git rev-parse "$UPSTREAM_REMOTE/$RELEASE_BRANCH")
  check_head=$(git rev-parse "$check_ref")

  log "Upstream HEAD: $(git log --oneline -1 "$upstream_head")"
  log "Branch HEAD:   $(git log --oneline -1 "$check_head")"

  echo ""

  # Check what's in our branch but not in upstream
  local ours_only_count
  ours_only_count=$(git rev-list --count "$UPSTREAM_REMOTE/$RELEASE_BRANCH".."$check_ref")

  # Check what's in upstream but not in our branch
  local upstream_only_count
  upstream_only_count=$(git rev-list --count "$check_ref".."$UPSTREAM_REMOTE/$RELEASE_BRANCH")

  log "Commits in branch but not upstream: $ours_only_count"
  log "Commits in upstream but not branch: $upstream_only_count"

  if [ "$VERBOSE" = true ] && [ "$ours_only_count" -gt 0 ]; then
    echo ""
    log "Branch-only commits:"
    git log --oneline "$UPSTREAM_REMOTE/$RELEASE_BRANCH".."$check_ref" | sed 's/^/  /'
  fi

  if [ "$VERBOSE" = true ] && [ "$upstream_only_count" -gt 0 ]; then
    echo ""
    log "Upstream-only commits (missing from branch):"
    git log --oneline "$check_ref".."$UPSTREAM_REMOTE/$RELEASE_BRANCH" | sed 's/^/  /'
  fi

  echo ""

  # Log base commit info for debugging (informational only)
  # The develop-only commits check below is the definitive test for correctness
  local actual_base
  actual_base=$(git merge-base "$check_ref" "$UPSTREAM_REMOTE/$RELEASE_BRANCH" 2>/dev/null || echo "")

  if [ -n "$actual_base" ]; then
    log "Release branch point: $(git log --oneline -1 "$release_base")"
    log "Merge base with upstream: $(git log --oneline -1 "$actual_base")"
  fi

  echo ""

  # Check if branch contains commits from develop that are past the release base
  # These would be commits in upstream/develop that are NOT in upstream/release
  local develop_only_commits
  develop_only_commits=$(git rev-list "$UPSTREAM_REMOTE/$RELEASE_BRANCH".."$UPSTREAM_REMOTE/develop" 2>/dev/null || echo "")

  local has_develop_commits=false
  local develop_commit_list=""
  if [ -n "$develop_only_commits" ]; then
    while IFS= read -r commit; do
      if git merge-base --is-ancestor "$commit" "$check_ref" 2>/dev/null; then
        has_develop_commits=true
        develop_commit_list="${develop_commit_list}  $(git log --oneline -1 "$commit")"$'\n'
      fi
    done <<< "$develop_only_commits"
  fi

  if [ "$has_develop_commits" = true ]; then
    warn "Release branch contains commits from develop that are NOT in upstream release:"
    printf "%s" "$develop_commit_list"
    echo ""
  fi

  # Check file differences
  local diff_files
  diff_files=$(git diff --name-only "$UPSTREAM_REMOTE/$RELEASE_BRANCH" "$check_ref" 2>/dev/null || echo "")

  if [ -n "$diff_files" ]; then
    local diff_count
    diff_count=$(echo "$diff_files" | wc -l | tr -d ' ')
    log "Files differing between upstream and xataio: $diff_count"

    if [ "$VERBOSE" = true ]; then
      echo "$diff_files" | sed 's/^/  /'
    fi
  else
    log "Files differing between upstream and xataio: 0"
  fi

  echo ""

  # Summary
  echo "=== SUMMARY ==="
  local issues=0

  if [ "$has_develop_commits" = true ]; then
    error "✗ Branch contains develop-only commits that shouldn't be in release"
    ((issues++)) || true
  else
    success "✓ No unexpected develop-only commits"
  fi

  if [ "$upstream_only_count" -gt 0 ]; then
    warn "⚠ Missing $upstream_only_count commits from upstream (may need sync)"
  else
    success "✓ No missing upstream commits"
  fi

  echo ""

  if [ "$issues" -eq 0 ]; then
    success "Release branch $RELEASE_BRANCH is correctly based"
    exit 0
  else
    error "Release branch $RELEASE_BRANCH has $issues critical issue(s) - needs to be recreated"
    exit 1
  fi
}

main "$@"
