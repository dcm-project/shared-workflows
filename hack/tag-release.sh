#!/usr/bin/env bash
# Git-tag all DCM service repos from their release branch HEAD.
#
# Resolves the HEAD SHA of the release branch (derived from the tag name) for
# each service repo via GitHub API, creates an annotated git tag at that commit,
# and pushes it. Each tag push triggers CI to build and push the image.
#
# Works for both RC tags (v0.0.1-rc.1) and final releases (v0.0.1).
#
# Prerequisites: gh (authenticated with push access to the service repos)
#
# Usage:
#   ./hack/tag-release.sh v0.0.1-rc.1
#   ./hack/tag-release.sh v0.0.1-rc.2 placement-manager catalog-manager
#   ./hack/tag-release.sh v0.0.1
set -euo pipefail

ORG="dcm-project"
ALL_SERVICES=(
  placement-manager
  service-provider-manager
  catalog-manager
  policy-manager
  kubevirt-service-provider
  k8s-container-service-provider
  acm-cluster-service-provider
)

usage() {
  echo "Usage: $0 <tag> [service ...]"
  echo ""
  echo "  tag      Version tag to create (e.g. v0.0.1-rc.1 or v0.0.1)"
  echo "  service  Optional list of services to tag (default: all)"
  echo ""
  echo "Examples:"
  echo "  $0 v0.0.1-rc.1"
  echo "  $0 v0.0.1-rc.2 placement-manager catalog-manager"
  echo "  $0 v0.0.1"
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

TAG="$1"
shift

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
  echo "Error: tag must match vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N" >&2
  exit 1
fi

# Release branch matches README convention: release/vMAJOR.MINOR.PATCH (strip RC suffix first)
VERSION="${TAG%-rc.*}"
BRANCH="release/${VERSION}"

if ! command -v gh &> /dev/null; then
  echo "Error: gh is required but not found" >&2
  exit 1
fi

SERVICES=("$@")
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=("${ALL_SERVICES[@]}")
fi

echo "Tag:      ${TAG}"
echo "Branch:   ${BRANCH}"
echo "Services: ${SERVICES[*]}"
echo ""

FAILED=0
for svc in "${SERVICES[@]}"; do
  echo "--- ${svc} ---"

  # Fetch full SHA of the branch HEAD; stderr merged so error message lands in $SHA for reporting
  SHA=$(gh api "repos/${ORG}/${svc}/commits/${BRANCH}" --jq '.sha' 2>&1) || {
    echo "  Error: failed to resolve HEAD of branch ${BRANCH} for ${svc}: ${SHA}" >&2
    FAILED=1
    continue
  }
  SHORT_SHA="${SHA:0:7}"
  echo "  Branch ${BRANCH} HEAD: ${SHORT_SHA} (${SHA})"

  # Create an annotated tag object pointing at the resolved commit
  gh api "repos/${ORG}/${svc}/git/tags" \
    -X POST \
    -f tag="${TAG}" \
    -f message="${TAG}" \
    -f object="${SHA}" \
    -f type="commit" \
    --silent || {
    echo "  Error: failed to create tag object ${TAG} for ${svc}" >&2
    FAILED=1
    continue
  }

  # Create the ref (refs/tags/vX.Y.Z) so the tag is visible and triggers CI
  gh api "repos/${ORG}/${svc}/git/refs" \
    -X POST \
    -f ref="refs/tags/${TAG}" \
    -f sha="${SHA}" \
    --silent || {
    echo "  Error: failed to create ref refs/tags/${TAG} for ${svc}" >&2
    FAILED=1
    continue
  }

  echo "  Tagged ${svc}@${SHORT_SHA} -> ${TAG}"
done

echo ""
if [[ "$FAILED" -ne 0 ]]; then
  echo "Warning: one or more services failed to tag" >&2
  exit 1
fi

echo "Done. All services tagged with ${TAG}"
