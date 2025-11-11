#!/usr/bin/env bash

# Update xataio submodules to their latest remote versions
#
# This script should be sourced by a wrapper script that calls update_xata_submodules()
#
# Environment Variables:
#   GITMODULES_FILE  - Path to .gitmodules file (default: auto-detect from git root)
#   DEBUG            - Set to 1 to enable command tracing
#
# Arguments:
#   --gitmodules PATH   - Path to .gitmodules file (overrides env variable)
#   --dry-run           - Show what would be updated without making changes
#
# Example wrapper:
#   SOURCE_REL=$(dirname "$0")/../../utils/dependencies/scripts/xata/update-submodules.sh
#   . "$SOURCE_REL"
#   update_xata_submodules --gitmodules path/to/.gitmodules

set -uo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
  error "$1"
  exit "${2:-1}"
}

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
      *) die "Unknown option: $1" ;;
    esac
  done

  # Auto-detect .gitmodules if not specified
  if [ -z "$gitmodules_file" ]; then
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "Not in a git repository"
    gitmodules_file="$git_root/.gitmodules"
  fi

  # Validate .gitmodules exists
  if [ ! -f "$gitmodules_file" ]; then
    die ".gitmodules not found at: $gitmodules_file"
  fi

  # Determine repository root from .gitmodules location
  local repo_dir
  repo_dir=$(dirname "$(realpath "$gitmodules_file")")

  local gitmodules_filename
  gitmodules_filename=$(basename "$gitmodules_file")

  log "Updating xataio submodules from: $gitmodules_file"
  [ "$dry_run" = true ] && warn "[DRY RUN MODE]"

  # Change to repository directory for git operations
  cd "$repo_dir" || die "Failed to change to repository directory: $repo_dir"

  # Process each submodule
  for path in $(git config --file "$gitmodules_filename" --get-regexp path | awk '{print $2}'); do
    url=$(git config --file "$gitmodules_filename" submodule."$path".url) || die "Failed to get URL for submodule: $path"

    # Only update xataio submodules
    if is_xataio_submodule "$url"; then
      log "Updating submodule: $path ($url)"

      if [ "$dry_run" = false ]; then
        if ! git submodule update --remote "$path"; then
          die "Failed to update submodule: $path"
        fi
        if ! git add "$path"; then
          die "Failed to stage submodule: $path"
        fi
      fi
    fi
  done

  if [ "$dry_run" = false ]; then
    success "Updated xataio submodules"
  fi
}
