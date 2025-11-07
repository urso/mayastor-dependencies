#!/usr/bin/env bash

# Build and push mayastor docker images to AWS ECR.
# This script provides ECR-specific configuration for the standard release.sh script.
#
# This script should be sourced by a wrapper script that calls build_and_push_ecr()
#
# Environment Variables:
#   ARCH            - Architecture to build for (auto-detected if not set: amd64 or arm64)
#   AWS_REGION      - AWS region for ECR (default: us-east-1)
#   AWS_ACCOUNT_ID  - AWS account ID for ECR registry (required)
#
# Example wrapper:
#   SOURCE_REL=$(dirname "$0")/../../utils/dependencies/scripts/xata/build-and-push-ecr.sh
#   . "$SOURCE_REL"
#   build_and_push_ecr $@

# Detect or validate architecture
detect_arch() {
  if [ -z "${ARCH:-}" ]; then
    # Try to auto-detect architecture
    MACHINE_ARCH=$(uname -m)
    case "$MACHINE_ARCH" in
      x86_64)
        ARCH="amd64"
        echo "Auto-detected architecture: $ARCH (from $MACHINE_ARCH)"
        ;;
      aarch64|arm64)
        ARCH="arm64"
        echo "Auto-detected architecture: $ARCH (from $MACHINE_ARCH)"
        ;;
      *)
        echo "Error: Unable to detect architecture. Machine reports: $MACHINE_ARCH"
        echo "Please set ARCH environment variable explicitly (amd64 or arm64)"
        echo "Example: ARCH=amd64 $0"
        exit 1
        ;;
    esac
  fi
}

# Validate required environment variables
validate_env() {
  if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    echo "Error: AWS_ACCOUNT_ID environment variable is required"
    echo "Example: AWS_ACCOUNT_ID=390402546598 $0"
    exit 1
  fi
}

# Parse arguments
parse_args() {
  RELEASE_ARGS=()
  while [ "$#" -gt 0 ]; do
    case $1 in
      --tag)
        # Allow overriding the tag
        shift
        VERSION_TAG=$1
        shift
        ;;
      *)
        # Pass through other arguments to release.sh
        RELEASE_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# Determine version tag based on git branch
determine_version_tag() {
  # Check if BASE_TAG is already set in environment
  if [ -z "${BASE_TAG:-}" ]; then
    # On develop branch: use "develop"
    # Otherwise: use git describe output
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$GIT_BRANCH" =~ ^develop ]]; then
      BASE_TAG="develop"
    else
      # Check if we're on a tag
      BASE_TAG=$(git describe --exact-match 2>/dev/null || git describe --tags --always)
    fi
  fi

  # Add architecture suffix to tag (unless already overridden by --tag)
  if [ -z "${VERSION_TAG:-}" ]; then
    VERSION_TAG="${BASE_TAG}-${ARCH}"
  fi
}

# Output GitHub Actions outputs
output_github_actions() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "registry=$ECR_REGISTRY" >> "$GITHUB_OUTPUT"
    echo "tag=$VERSION_TAG" >> "$GITHUB_OUTPUT"
    echo "base_tag=$BASE_TAG" >> "$GITHUB_OUTPUT"
    echo "arch=$ARCH" >> "$GITHUB_OUTPUT"
    echo ""
    echo "GitHub Actions outputs:"
    echo "  registry=$ECR_REGISTRY"
    echo "  tag=$VERSION_TAG"
    echo "  base_tag=$BASE_TAG"
    echo "  arch=$ARCH"
  fi
}

# Main entry point
build_and_push_ecr() {
  set -euo pipefail

  # Get the repository root using git (same pattern as release.sh)
  if ! command -v git &>/dev/null; then
    echo "Error: git is required but not found"
    exit 1
  fi
  REPO_ROOT=$(git rev-parse --show-toplevel)

  # Detect architecture
  detect_arch

  # Validate environment
  validate_env

  # Construct ECR registry URL
  ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  echo "=========================================="
  echo "Building for ECR"
  echo "=========================================="
  echo "Registry:     $ECR_REGISTRY"
  echo "Architecture: $ARCH"
  echo "Region:       $AWS_REGION"
  echo "=========================================="

  # Parse arguments
  parse_args "$@"

  # Determine version tag
  determine_version_tag

  echo "Git branch:   $GIT_BRANCH"
  echo "Base tag:     $BASE_TAG"
  echo "Version tag:  $VERSION_TAG"
  echo "=========================================="

  # Output for GitHub Actions
  output_github_actions

  # Build and push images using the standard release script
  echo "Running: ./scripts/release.sh --registry $ECR_REGISTRY --tag $VERSION_TAG ${RELEASE_ARGS[*]}"
  cd "$REPO_ROOT"
  ./scripts/release.sh --registry "$ECR_REGISTRY" --tag "$VERSION_TAG" "${RELEASE_ARGS[@]}"
}

# Default values
AWS_REGION="${AWS_REGION:-us-east-1}"
