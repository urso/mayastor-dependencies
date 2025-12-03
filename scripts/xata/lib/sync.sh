#!/usr/bin/env bash

# sync.sh - Shared upstream sync operations for xataio forks
#
# This file is meant to be sourced, not executed directly.
# Usage: source "$SCRIPT_DIR/lib/sync.sh"

# Guard against double-sourcing
if [ -n "${_XATA_SYNC_SOURCED:-}" ]; then
  return 0
fi
_XATA_SYNC_SOURCED=1

# Ensure common.sh is sourced (we depend on it)
SYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${_XATA_COMMON_SOURCED:-}" ]; then
  source "$SYNC_LIB_DIR/common.sh"
fi

# Map local branch to upstream branch
# This encodes xataio's branch naming conventions:
#   develop-* -> develop
#   release/X.Y-* -> release/X.Y
# Args: local_branch_name, optional_override
# Returns: upstream branch name via stdout
map_branch() {
  local local_branch="$1"
  local override="${2:-}"

  # If explicitly provided, use that
  if [ -n "$override" ]; then
    echo "$override"
    return
  fi

  # develop variants -> develop
  if [[ "$local_branch" =~ ^develop(-.*)?$ ]]; then
    echo "develop"
    return
  fi

  # release/X.Y-suffix -> release/X.Y
  if [[ "$local_branch" =~ ^release/([0-9]+\.[0-9]+)(-.+)?$ ]]; then
    echo "release/${BASH_REMATCH[1]}"
    return
  fi

  # Default: use as-is
  echo "$local_branch"
}

# Determine the merge target based on branch type and available tags
# This encodes xataio's merge strategy:
#   - Release branches: sync to latest stable release tag, or latest pre-release tag
#   - Other branches: sync to HEAD
# Args: upstream_remote, upstream_branch
# Returns: merge target (tag or branch ref) via stdout
determine_merge_target() {
  local upstream_remote="$1"
  local upstream_branch="$2"

  if [[ "$upstream_branch" =~ ^release/([0-9]+\.[0-9]+) ]]; then
    local version="${BASH_REMATCH[1]}"

    # Find latest stable tag (no alpha/rc/beta suffix)
    local latest_stable=$(git tag -l --merged "$upstream_remote/$upstream_branch" \
      --sort=-version:refname "v${version}.*" | grep -v -E -- '-(alpha|rc|beta)' | head -1)

    if [ -n "$latest_stable" ]; then
      # Stable release exists - use it (ignore any newer RC/alpha tags)
      log "Release branch detected - syncing to latest stable release: $latest_stable" >&2
      echo "$latest_stable"
      return
    fi

    # No stable release - find latest tag including RC/alpha
    local latest_tag=$(git tag -l --merged "$upstream_remote/$upstream_branch" \
      --sort=-version:refname "v${version}.*" | head -1)

    if [ -n "$latest_tag" ]; then
      log "No stable release found - syncing to latest pre-release tag: $latest_tag" >&2
      echo "$latest_tag"
      return
    fi

    # No tags at all - sync to HEAD (new release in development)
    log "No tags found on $upstream_branch - syncing to HEAD (new release)" >&2
  fi

  # develop or other branches - sync to HEAD
  echo "$upstream_remote/$upstream_branch"
}

# Check for divergence between current branch and merge target
# Args: merge_target
# Returns: 0 if diverged (new commits to pull), 2 if up-to-date
check_divergence() {
  local merge_target="$1"

  local ahead behind
  ahead=$(git rev-list --count HEAD.."$merge_target" 2>/dev/null || echo "0")
  behind=$(git rev-list --count "$merge_target"..HEAD 2>/dev/null || echo "0")

  # If no new commits from upstream, we're up-to-date
  if [ "$ahead" -eq 0 ]; then
    log "Already up-to-date with upstream (no new commits to pull)"
    if [ "$behind" -gt 0 ]; then
      log "Note: You have $behind local commit(s) that are not in upstream"
    fi
    return 2  # Special code: up-to-date
  fi

  # Report divergence status
  if [ "$behind" -gt 0 ]; then
    warn "Local branch has $behind commit(s) not in upstream (diverged)"
  fi

  log "Upstream has $ahead new commit(s) to sync"
  return 0
}

# Check if a path is a submodule
# Args: path
# Returns: 0 if submodule, 1 if not
is_submodule() {
  local path="$1"

  # Check if directory with .git inside
  if [ -d "$path" ] && { [ -f "$path/.git" ] || [ -d "$path/.git" ]; }; then
    return 0
  fi

  # Check .gitmodules in case submodule dir doesn't exist yet
  if [ -f ".gitmodules" ] && git config --file .gitmodules --get "submodule.$path.path" &>/dev/null; then
    return 0
  fi

  return 1
}

# Auto-resolve submodule conflicts by keeping ours
# (.gitattributes merge=ours doesn't work for submodules/gitlinks)
# Returns: 0 if all conflicts resolved, 1 if file conflicts remain
# Outputs remaining file conflicts to stdout (one per line)
resolve_submodule_conflicts() {
  local conflicted_files
  conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

  if [ -z "$conflicted_files" ]; then
    return 0
  fi

  local submodule_count=0
  local file_conflicts=()

  while IFS= read -r file; do
    [ -z "$file" ] && continue

    if is_submodule "$file"; then
      log "  Auto-resolving submodule: $file (keeping ours)"
      git checkout --ours "$file" 2>/dev/null || true
      git add "$file" 2>/dev/null || true
      ((submodule_count++)) || true
    else
      file_conflicts+=("$file")
    fi
  done <<< "$conflicted_files"

  if [ $submodule_count -gt 0 ]; then
    log "Auto-resolved $submodule_count submodule conflict(s)"
  fi

  # Output remaining file conflicts
  for file in "${file_conflicts[@]}"; do
    echo "$file"
  done

  if [ ${#file_conflicts[@]} -gt 0 ]; then
    return 1
  fi
  return 0
}

# Perform merge from upstream with conflict handling
# Args: merge_target, dry_run (true/false), no_verify (true/false), commit_conflicts (true/false)
#   commit_conflicts: if true, commit conflict markers for PR resolution; if false, leave working tree dirty
# Returns: 0 on success, 1 on merge conflicts
merge_upstream() {
  local merge_target="$1"
  local dry_run="${2:-false}"
  local no_verify="${3:-false}"
  local commit_conflicts="${4:-false}"

  log "Attempting to merge $merge_target..."

  if [ "$dry_run" = "true" ]; then
    log "[DRY RUN] Would execute: git merge --no-ff $merge_target"
    log ""
    log "[DRY RUN] Preview of incoming changes from upstream:"
    echo "----------------------------------------"
    log "New commits from upstream:"
    git log --oneline --no-decorate HEAD.."$merge_target" 2>/dev/null || true
    echo ""
    log "Changes from upstream (since divergence):"
    # Use three-dot syntax to show changes on upstream side only
    git diff --stat HEAD..."$merge_target" 2>/dev/null || true
    echo ""
    log "Note: Your local-only files will be preserved during merge"
    echo "----------------------------------------"
    return 0
  fi

  # Check if merge would be non-fast-forward (force-push scenario)
  if ! git merge-base --is-ancestor "$merge_target" HEAD 2>/dev/null; then
    if ! git merge-base --is-ancestor HEAD "$merge_target" 2>/dev/null; then
      # Neither is ancestor of the other - check for common history
      local base
      base=$(git merge-base HEAD "$merge_target" 2>/dev/null || echo "")

      if [ -z "$base" ]; then
        # No common ancestor - likely force push
        die "Upstream appears to have been force-pushed (no common history). Manual intervention required." 6
      fi

      # We have a common ancestor, so this is normal divergence
      log "Branches have diverged, will create merge commit"
    fi
  fi

  # Attempt the merge with conventional commit message
  # Use zdiff3 conflict style to show common ancestor in conflict markers
  local merge_flags=("-c" "merge.conflictStyle=zdiff3" "merge" "--no-ff")
  if [ "$no_verify" = "true" ]; then
    merge_flags+=("--no-verify")
  fi

  if git "${merge_flags[@]}" -m "chore: sync upstream changes" "$merge_target" 2>&1; then
    success "Successfully merged $merge_target"

    # Show summary
    log "Changes summary:"
    git diff --stat HEAD~1 2>/dev/null || true

    return 0
  else
    # Merge failed - check if it's due to conflicts
    if git status | grep -q "Unmerged paths\|Merge conflict"; then
      error "Merge conflicts detected"

      # Show conflicted files
      log "Conflicted files:"
      git diff --name-only --diff-filter=U 2>/dev/null || true

      # Try to auto-resolve submodule conflicts
      local remaining_conflicts
      remaining_conflicts=$(resolve_submodule_conflicts)

      if [ -z "$remaining_conflicts" ]; then
        # All conflicts were submodules - complete the merge
        log "All conflicts were submodule conflicts (auto-resolved)"
        log "Completing merge..."

        local commit_flags=()
        if [ "$no_verify" = "true" ]; then
          commit_flags+=("--no-verify")
        fi

        if git commit "${commit_flags[@]}" -m "chore: sync upstream changes"; then
          success "Successfully merged $merge_target (submodule conflicts auto-resolved)"
          log "Changes summary:"
          git diff --stat HEAD~1 2>/dev/null || true
          return 0
        else
          error "Failed to complete merge after resolving submodule conflicts"
          git merge --abort 2>/dev/null || true
          return 1
        fi
      else
        # File conflicts remain
        warn "Remaining file conflicts require manual resolution:"
        echo "$remaining_conflicts" | while read -r file; do
          [ -n "$file" ] && log "  $file"
        done

        if [ "$commit_conflicts" = "true" ]; then
          # Commit the conflict markers so they can be pushed and resolved in a PR
          log "Committing conflict markers for PR resolution..."
          git add -A
          git commit -m "chore: sync upstream changes (conflicts)

This commit contains unresolved merge conflicts that need manual resolution.
Look for conflict markers (<<<<<<< HEAD, =======, >>>>>>> upstream) in the files listed above."
        fi

        return 1
      fi
    else
      # Some other error
      git merge --abort 2>/dev/null || true
      die "Merge failed with unknown error" 5
    fi
  fi
}
