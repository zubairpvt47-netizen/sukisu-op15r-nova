#!/usr/bin/env bash
# Shared helpers. Source me; do not execute.

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

retry() {  # retry <cmd...>   5 attempts, growing back-off
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge 5 ] && return 1
    echo "retry $n/5: $*" >&2
    sleep $((n * 6))
  done
}

# clone_at <url> <dir> <full-sha> [full]
# Fetch exactly <sha> into <dir>; abort if what lands is not that sha. "full" keeps the whole history.
clone_at() {
  local url="$1" dir="$2" sha="$3" mode="${4:-shallow}"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "pin for $url is not a full 40-char sha: '$sha'"
  rm -rf "$dir"
  if [ "$mode" = full ]; then
    retry git clone -q "$url" "$dir"
    git -C "$dir" checkout -q --detach "$sha"
  else
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
    if ! retry git -C "$dir" fetch -q --depth=1 origin "$sha"; then
      echo "shallow fetch of $sha refused by $url, falling back to a full clone" >&2
      rm -rf "$dir"
      retry git clone -q "$url" "$dir"
      git -C "$dir" checkout -q --detach "$sha"
    else
      git -C "$dir" checkout -q --detach FETCH_HEAD
    fi
  fi
  [ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || die "$url: checked out $(git -C "$dir" rev-parse HEAD), wanted $sha"
  echo "pinned $(basename "$dir") @ ${sha:0:12} ($(git -C "$dir" log -1 --format=%cs))"
}

# apply_patch <patch-file> [extra patch(1) args]   -- strict: no fuzz unless asked, any reject is fatal
apply_patch() {
  local p="$1"; shift
  [ -f "$p" ] || die "missing patch $p"
  # --batch: never prompt, never assume -R; a hunk that is already applied or does not match is a failure
  if ! patch -p1 --batch --no-backup-if-mismatch "$@" < "$p"; then
    echo "---- rejects for $(basename "$p") ----" >&2
    find . -name '*.rej' -print -exec cat {} \; >&2 || true
    die "patch failed: $(basename "$p")"
  fi
  if find . -name '*.rej' -o -name '*.orig' | grep -q .; then
    find . \( -name '*.rej' -o -name '*.orig' \) -print >&2
    die "patch left rejects/orig files: $(basename "$p")"
  fi
}

# Kconfig symbol must exist somewhere in the tree, otherwise a "CONFIG_X=y" line is silently dropped
need_symbol() {  # need_symbol <SYMBOL-without-CONFIG_> [dir]
  grep -RqsE "^(menu)?config ${1}\$" --include='Kconfig*' "${2:-.}" || die "Kconfig symbol $1 does not exist in this tree"
}
