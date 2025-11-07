#!/usr/bin/env bash

# Create and push multi-platform Docker manifests
# This script creates Docker manifests that combine multiple architecture-specific images
#
# This script should be sourced by a wrapper script that calls create_manifests()
#
# Environment Variables:
#   REGISTRY        - Container registry URL (required)
#   BASE_TAG        - Base tag without architecture suffix (auto-detected from git if not set)
#   ARCHITECTURES   - Space-separated list of architectures (default: "amd64 arm64")
#   IMAGES          - Space-separated list of image names (required)
#
# Example wrapper:
#   SOURCE_REL=$(dirname "$0")/../../utils/dependencies/scripts/xata/create-manifest.sh
#   . "$SOURCE_REL"
#   create_manifests $@

# Determine base tag based on git branch
determine_base_tag() {
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
}

# Validate required environment variables
validate_env() {
  if [ -z "${REGISTRY:-}" ]; then
    echo "Error: REGISTRY environment variable is required"
    echo "Example: REGISTRY=390402546598.dkr.ecr.us-east-1.amazonaws.com $0"
    exit 1
  fi

  if [ -z "${IMAGES:-}" ]; then
    echo "Error: IMAGES environment variable is required"
    echo "Example: IMAGES=\"mayastor-agent-core mayastor-rest\" $0"
    exit 1
  fi
}

# Function to create and push manifest for a single image
create_manifest() {
  local image_name=$1
  local manifest_tag="${REGISTRY}/${image_name}:${BASE_TAG}"

  echo ""
  echo "Creating manifest for ${image_name}:${BASE_TAG}"
  echo "---------------------------------------"

  # Build list of architecture-specific images
  local arch_images=()
  for arch in $ARCHITECTURES; do
    local arch_tag="${REGISTRY}/${image_name}:${BASE_TAG}-${arch}"
    arch_images+=("$arch_tag")
    echo "  - ${arch_tag}"
  done

  # Create the manifest
  echo ""
  echo "Creating manifest: ${manifest_tag}"
  docker manifest create "$manifest_tag" "${arch_images[@]}"

  # Annotate each architecture in the manifest
  for arch in $ARCHITECTURES; do
    local arch_tag="${REGISTRY}/${image_name}:${BASE_TAG}-${arch}"

    # Map common arch names to Docker platform names
    local platform_arch="$arch"
    case "$arch" in
      amd64) platform_arch="amd64" ;;
      arm64) platform_arch="arm64" ;;
      *) platform_arch="$arch" ;;
    esac

    echo "Annotating ${arch_tag} as linux/${platform_arch}"
    docker manifest annotate "$manifest_tag" "$arch_tag" \
      --os linux \
      --arch "$platform_arch"
  done

  # Push the manifest
  echo "Pushing manifest: ${manifest_tag}"
  docker manifest push "$manifest_tag"

  echo "✓ Successfully created and pushed ${manifest_tag}"
}

# Main entry point
create_manifests() {
  set -euo pipefail

  # Determine base tag from environment or git
  determine_base_tag

  # Validate environment
  validate_env

  echo "=========================================="
  echo "Creating Multi-Platform Manifests"
  echo "=========================================="
  echo "Registry:       $REGISTRY"
  echo "Base tag:       $BASE_TAG"
  echo "Architectures:  $ARCHITECTURES"
  echo "Images:         $IMAGES"
  echo "=========================================="

  # Process each image
  for image in $IMAGES; do
    create_manifest "$image"
  done

  echo ""
  echo "=========================================="
  echo "✓ All manifests created successfully"
  echo "=========================================="
}

# Default values
ARCHITECTURES="${ARCHITECTURES:-amd64 arm64}"
