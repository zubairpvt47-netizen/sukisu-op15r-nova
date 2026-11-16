#!/usr/bin/env bash
# Fetch Google's kernel tree (Kleaf/Bazel layout) with kernel/common pinned to the phone's exact commit.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../pins.env
source "$HERE/pins.env"
# shellcheck source=lib.sh
source "$HERE/scripts/lib.sh"
: "${KROOT:?KROOT must point at the workspace for the kernel tree}"
COMMON_TAG="${COMMON_TAG_OVERRIDE:-$COMMON_TAG}"
COMMIT_PREFIX="${COMMIT_PREFIX_OVERRIDE:-$COMMON_COMMIT_PREFIX}"

say "repo init ($COMMON_MANIFEST_BRANCH), kernel/common pinned to tag $COMMON_TAG"
mkdir -p "$KROOT"
cd "$KROOT"
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=http.lowSpeedLimit GIT_CONFIG_VALUE_0=1024 \
       GIT_CONFIG_KEY_1=http.lowSpeedTime GIT_CONFIG_VALUE_1=60

retry repo init -u https://android.googlesource.com/kernel/manifest -b "$COMMON_MANIFEST_BRANCH" --depth=1 >/dev/null

MANIFEST=.repo/manifests/default.xml
grep -q 'path="common"' "$MANIFEST" || die "manifest has no common project"
# an immutable tag instead of a branch head that Google may move or retire
sed -i "/path=\"common\"/ s|revision=\"[^\"]*\"|revision=\"refs/tags/${COMMON_TAG}\"|" "$MANIFEST"
grep 'path="common"' "$MANIFEST"

say "repo sync"
attempt=1
until timeout 40m repo sync -c --current-branch --no-clone-bundle --jobs-checkout="$(nproc)" -j16 >/dev/null; do
  [ "$attempt" -ge 4 ] && die "repo sync failed after $attempt attempts"
  echo "repo sync attempt $attempt failed, retrying"
  attempt=$((attempt + 1))
  sleep $((attempt * 20))
done

HEAD_SHA=$(git -C common rev-parse HEAD)
echo "kernel/common HEAD = $HEAD_SHA"
[[ "$HEAD_SHA" == "$COMMIT_PREFIX"* ]] || die "kernel/common is $HEAD_SHA, the phone's kernel is g$COMMIT_PREFIX - refusing to build a different tree"
grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL) =' common/Makefile
SUBLEVEL=$(sed -n 's/^SUBLEVEL = //p' common/Makefile)
[ "$SUBLEVEL" = 69 ] || die "expected 6.12.69, Makefile says sublevel $SUBLEVEL"
echo "source verified: Linux 6.12.$SUBLEVEL @ ${HEAD_SHA:0:12}"
