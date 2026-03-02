#!/usr/bin/env bash
# Sync with upstream HKUDS/nanobot repo while preserving your customizations.
# Usage: ./scripts/sync-upstream.sh

set -euo pipefail

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"
LOCAL_BRANCH="main"

echo "==> Fetching upstream ($UPSTREAM_REMOTE/$UPSTREAM_BRANCH)..."
git fetch "$UPSTREAM_REMOTE"

BEHIND=$(git rev-list --count HEAD.."$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")
if [ "$BEHIND" -eq 0 ]; then
    echo "==> Already up to date with upstream."
    exit 0
fi

echo "==> $BEHIND new commit(s) from upstream. Merging..."
git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-edit || {
    echo ""
    echo "!!! Merge conflicts detected. Resolve them manually, then:"
    echo "    git add ."
    echo "    git commit"
    echo "    git push origin $LOCAL_BRANCH"
    exit 1
}

echo "==> Merge successful. Pushing to origin..."
git push origin "$LOCAL_BRANCH"

echo "==> Done! Your fork is now up to date with upstream."
