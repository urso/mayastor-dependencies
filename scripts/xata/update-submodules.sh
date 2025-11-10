#!/usr/bin/env bash

# Update xataio submodules to their latest remote versions
#
# This script should be sourced by a wrapper script that calls update_xata_submodules()
#
# Environment Variables:
#   GITMODULES_FILE  - Path to .gitmodules file (default: auto-detect from git root)
#
# Arguments:
#   --gitmodules PATH   - Path to .gitmodules file (overrides env variable)
#   --dry-run           - Show what would be updated without making changes
#
# Example wrapper:
#   SOURCE_REL=$(dirname "$0")/../../utils/dependencies/scripts/xata/update-submodules.sh
#   . "$SOURCE_REL"
#   update_xata_submodules --gitmodules path/to/.gitmodules

set -euo pipefail

# Check if a submodule URL is from xataio (relative paths or explicit xataio URLs)
is_xataio_submodule() {
  local url="$1"
  [[ "$url" =~ ^\.\./ ]] || [[ "$url" =~ ^\./ ]] || [[ "$url" =~ xataio ]]
}

# Main function
update_xata_submodules() {
  local gitmodules_file="${GITMODULES_FILE:-}"
  local dry_run=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --gitmodules) gitmodules_file="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      *) echo "Unknown option: $1"; exit 1 ;;
    esac
  done

  # Auto-detect .gitmodules if not specified
  if [ -z "$gitmodules_file" ]; then
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
      echo "Error: Not in a git repository" >&2
      exit 1
    }
    gitmodules_file="$git_root/.gitmodules"
  fi

  # Validate .gitmodules exists
  if [ ! -f "$gitmodules_file" ]; then
    echo "Error: .gitmodules not found at: $gitmodules_file" >&2
    exit 1
  fi

  # Determine repository root from .gitmodules location
  local repo_dir
  repo_dir=$(dirname "$(realpath "$gitmodules_file")")

  local gitmodules_filename
  gitmodules_filename=$(basename "$gitmodules_file")

  echo "Updating xataio submodules from: $gitmodules_file"
  [ "$dry_run" = true ] && echo "[DRY RUN MODE]"

  local updated=0

  # Change to repository directory for git operations
  cd "$repo_dir"

  # Process each submodule
  for path in $(git config --file "$gitmodules_filename" --get-regexp path | awk '{print $2}'); do
    url=$(git config --file "$gitmodules_filename" submodule."$path".url)

    # Only update xataio submodules
    if is_xataio_submodule "$url"; then
      echo "  → $path ($url)"

      if [ "$dry_run" = false ]; then
        git submodule update --remote "$path"
        git add "$path"
        ((updated++))
      fi
    fi
  done

  if [ "$dry_run" = false ]; then
    echo "✓ Updated $updated xataio submodule(s)"
  fi
}
