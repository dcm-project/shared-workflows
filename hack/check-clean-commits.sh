#!/usr/bin/env bash
#
# check-clean-commits.sh - Validates PR commits have clean history
#
# This script checks all commits in a PR branch for patterns that indicate
# the history hasn't been cleaned up before merge. It's designed to run in CI
# and fail if any "dirty" commits are found.
#
# Usage:
#   ./hack/check-clean-commits.sh [base_ref]
#
# Arguments:
#   base_ref  - The base branch to compare against (default: origin/main)
#
# Environment variables:
#   GITHUB_BASE_REF - If set (in GitHub Actions), used as base_ref
#
# Exit codes:
#   0 - All commits are clean
#   1 - Dirty commits found or error

set -euo pipefail

# Colors for output (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Determine base ref
BASE_REF="${1:-${GITHUB_BASE_REF:-origin/main}}"

# Ensure we have the base ref
if ! git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
    # Try fetching if it looks like a remote ref
    if [[ "${BASE_REF}" == origin/* ]]; then
        git fetch origin "${BASE_REF#origin/}" --depth=1 2>/dev/null || true
    fi
fi

# Get list of commits in this branch not in base
COMMITS=$(git log --format='%H' "${BASE_REF}..HEAD" 2>/dev/null || true)

if [[ -z "${COMMITS}" ]]; then
    echo -e "${GREEN}No commits to check (branch is up to date with ${BASE_REF})${NC}"
    exit 0
fi

COMMIT_COUNT=$(echo "${COMMITS}" | wc -l | tr -d ' ')
echo "Checking ${COMMIT_COUNT} commit(s) against ${BASE_REF}..."
echo ""

ERRORS=()
PREV_MSG=""

check_pattern() {
    local sha="$1"
    local msg="$2"
    local pattern="$3"
    local description="$4"
    
    if echo "${msg}" | grep -qiE "${pattern}"; then
        ERRORS+=("${sha:0:7}: ${description}")
        ERRORS+=("         Message: ${msg}")
        return 1
    fi
    return 0
}

for SHA in ${COMMITS}; do
    # Get commit message (first line only for most checks)
    MSG=$(git log -1 --format='%s' "${SHA}")
    FULL_MSG=$(git log -1 --format='%B' "${SHA}")
    
    # Check for merge commits
    PARENT_COUNT=$(git rev-list --count --parents -n 1 "${SHA}" | awk '{print NF-1}')
    if [[ "${PARENT_COUNT}" -gt 1 ]]; then
        ERRORS+=("${SHA:0:7}: Merge commit detected")
        ERRORS+=("         Message: ${MSG}")
    fi
    
    # 1. Autosquash markers: fixup!, squash!, amend!
    check_pattern "${SHA}" "${MSG}" '^(fixup|squash|amend)!' \
        "Autosquash marker (fixup!/squash!/amend!) - needs rebasing"
    
    # 2. WIP markers
    check_pattern "${SHA}" "${MSG}" '^wip[: ]|^wip$' \
        "WIP marker - work in progress commit"
    
    # 3. Temporary commits: tmp, test, debug (as standalone or prefix)
    check_pattern "${SHA}" "${MSG}" '^(tmp|test|debug)[: ]|^(tmp|test|debug)$' \
        "Temporary commit marker (tmp/test/debug)"
    
    # 4. Generic review-response messages
    check_pattern "${SHA}" "${MSG}" \
        '^(fix|address|apply|per|incorporate|as requested|requested).*(review|comment|feedback|suggestion|nit)s?[[:space:]]*$|^(typo|nit|nits)$|^fix typo$|^small fix$|^quick fix$' \
        "Generic review-response message - should be squashed"
    
    # 5. Single vague words
    check_pattern "${SHA}" "${MSG}" \
        '^(fix|fixes|fixed|update|updates|updated|change|changes|changed|refactor|cleanup|clean)$' \
        "Single vague word - not descriptive enough"
    
    # 6. Empty or whitespace-only messages
    if [[ -z "${MSG}" || "${MSG}" =~ ^[[:space:]]*$ ]]; then
        ERRORS+=("${SHA:0:7}: Empty or whitespace-only commit message")
    fi
    
    # 7. Duplicate consecutive messages
    if [[ "${MSG}" == "${PREV_MSG}" && -n "${MSG}" ]]; then
        ERRORS+=("${SHA:0:7}: Duplicate consecutive commit message")
        ERRORS+=("         Message: ${MSG}")
    fi
    PREV_MSG="${MSG}"
    
    # 8. TODO/FIXME/XXX/HACK in message
    check_pattern "${SHA}" "${MSG}" \
        '\b(TODO|FIXME|XXX|HACK)\b' \
        "Contains TODO/FIXME/XXX/HACK marker - incomplete work"
    
    # 9. Checkpoint/save commits
    check_pattern "${SHA}" "${MSG}" \
        '^(save|saving|checkpoint|backup)([: ]|$)|save work|saving work' \
        "Checkpoint/save commit - should be squashed"
    
    # 10. Uncertainty markers
    check_pattern "${SHA}" "${MSG}" \
        '\?|^maybe|^might|^try |^trying' \
        "Uncertainty marker (?, maybe, might, try) - incomplete work"
    
    # 11. Oops/whoops
    check_pattern "${SHA}" "${MSG}" \
        '\b(oops|whoops|argh|damn)\b' \
        "Mistake indicator (oops/whoops) - should be squashed"
    
    # 12. Ellipsis at end
    check_pattern "${SHA}" "${MSG}" \
        '\.\.\.[[:space:]]*$' \
        "Ends with ellipsis - suggests incomplete work"
    
    # 13. Just issue/PR number without description
    check_pattern "${SHA}" "${MSG}" \
        '^#[0-9]+$|^(closes?|fixes?|resolves?)[[:space:]]+#[0-9]+$' \
        "Only issue/PR reference - needs descriptive message"
done

echo ""

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}  DIRTY COMMITS DETECTED - CLEANUP REQUIRED${NC}"
    echo -e "${RED}========================================${NC}"
    echo ""
    echo "The following commits need to be cleaned up before merge:"
    echo ""
    for error in "${ERRORS[@]}"; do
        echo -e "${YELLOW}  ${error}${NC}"
    done
    echo ""
    echo "To fix: rebase and squash/reword these commits before merge."
    echo "Example: git rebase -i ${BASE_REF}"
    echo ""
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  All ${COMMIT_COUNT} commit(s) are clean!${NC}"
echo -e "${GREEN}========================================${NC}"
exit 0
