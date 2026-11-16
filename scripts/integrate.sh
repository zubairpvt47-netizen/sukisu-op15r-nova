#!/usr/bin/env bash
# Apply every source-level change to $KROOT/common. Strict: no fuzz, any reject or missing anchor is fatal.
#
#   KROOT  workspace holding the repo-synced kernel tree ($KROOT/common is kernel/common)
#   WORK   scratch directory for the pinned upstream clones
#
# Order matters: SUSFS first (it rewrites fs/ files the later patches anchor on), then NoMount / Baseband Guard / NTSync / tuning.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/pins.env"
source "$HERE/scripts/lib.sh"
: "${KROOT:?}" "${WORK:?}"
K="$KROOT/common"
[ -d "$K/fs" ] || die "no kernel tree at $K"
mkdir -p "$WORK"
cd "$K"

# --------------------------------------------------------------------------------------------------------
say "1/10 fetch pinned upstreams"
clone_at "$NOVA_REPO"          "$KROOT/KernelSU"        "$NOVA_PIN" full
clone_at "$SUSFS_REPO"         "$WORK/susfs4ksu"        "$SUSFS_PIN"
clone_at "$WILD_PATCHES_REPO"  "$WORK/wild-patches"     "$WILD_PATCHES_PIN"
clone_at "$WILD_GKI_REPO"      "$WORK/wild-gki"         "$WILD_GKI_PIN"
WILD_SCRIPTS="$WORK/wild-gki/.github/scripts"
WP="$WORK/wild-patches/common"

# --------------------------------------------------------------------------------------------------------
say "2/10 SukiSU Nova (builtin-new) as drivers/kernelsu"
NOVA="$KROOT/KernelSU"
[ -d "$NOVA/kernel" ] || die "Nova checkout has no kernel/ directory"
# Nova derives KSU_VERSION from the commit count of upstream 'main' (it asks the GitHub API, then falls back to
# git). The Kleaf sandbox has no network and no stable git context, so compute the identical number here and
# write it into the Makefile: the manager checks the kernel's version number.
count=$(git -C "$NOVA" rev-list --count origin/main)
KSU_VER=$((30000 + count - 4001))
short=$(git -C "$NOVA" rev-parse --short=8 HEAD)
echo "Nova version: $KSU_VER (origin/main has $count commits), commit $short"
python3 - "$NOVA/kernel/Makefile" "$KSU_VER" "v3.0.0-$short@builtin-new" <<'PY'
import re, sys
p, ver, full = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
s, n1 = re.subn(r'^KSU_VERSION\s*:=.*$', f'KSU_VERSION := {ver}', s, count=1, flags=re.M)
s, n2 = re.subn(r'^KSU_VERSION_FULL\s*:=.*$', f'KSU_VERSION_FULL := {full}', s, count=1, flags=re.M)
# ksu.o is built with -g0, which the Android kABI tooling (gendwarfksyms) refuses for an object that exports symbols
s, n3 = re.subn(r'^(CFLAGS_ksu\.o \+= )-g0 ', r'\1', s, count=1, flags=re.M)
if (n1, n2, n3) != (1, 1, 1):
    sys.exit(f"Nova Makefile anchors moved: version={n1} full={n2} g0={n3}")
open(p, "w", encoding="utf-8").write(s)
PY
grep -E '^KSU_PACKAGE_NAME|^KSU_EXPECTED_(SIZE|HASH)' "$NOVA/kernel/Makefile"
# Nova only: upstream is_manager_apk() also trusts 4 more signing keys (dummy.keystore = a public debug key anyone
# can sign with, an older SukiSU key, KOWX712, midori01). Keep only the Makefile's EXPECTED_SIZE/EXPECTED_HASH (Nova).
python3 - "$NOVA/kernel/manager/apk_sign.c" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
m = re.search(r'bool is_manager_apk\(char \*path\)\n\{\n(.*?)\n\}\n', s, flags=re.S)
if not m or 'EXPECTED_SIZE, EXPECTED_HASH' not in m.group(1):
    sys.exit("apk_sign.c: is_manager_apk() anchor moved")
body = "\t// sukisu-op15r-nova: SukiSU Nova's own signing key only\n\treturn check_v2_signature(path, EXPECTED_SIZE, EXPECTED_HASH);"
s = s[:m.start(1)] + body + s[m.end(1):]
open(p, "w", encoding="utf-8").write(s)
print("is_manager_apk: Nova key only")
PY
for h in 4359c171f325 56695cfa454a 484fcba6e6c4 b9ee6759de47; do
  ! grep -rq "$h" "$NOVA/kernel" || die "foreign manager signature $h still in the Nova source"
done
[ -e drivers/kernelsu ] && die "drivers/kernelsu already exists"
ln -s "$(realpath --relative-to=drivers "$NOVA/kernel")" drivers/kernelsu
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
[ "$(grep -c '^endmenu' drivers/Kconfig)" = 1 ] || die "drivers/Kconfig does not have exactly one endmenu"
sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || die "Kconfig hook not inserted"

# --------------------------------------------------------------------------------------------------------
say "3/10 SUSFS kernel patch (v2.4.0 line, gki-android16-6.12)"
PATCH=50_add_susfs_in_gki-android16-6.12.patch
cp "$WORK/susfs4ksu/kernel_patches/fs/"*             fs/
cp "$WORK/susfs4ksu/kernel_patches/include/linux/"*  include/linux/
cp "$WORK/susfs4ksu/kernel_patches/$PATCH" .
# Nova already carries the KernelSU-side SUSFS glue: kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch must NOT be applied.
# susfs4ksu bug: with CONFIG_KSU_SUSFS_ENABLE_LOG=n only SUSFS_LOGI/LOGE are stubbed, but the selinux-hide code also
# calls SUSFS_LOGI_RL/LOGE_RL -> implicit declaration at compile time. Add no-op stubs.
python3 - fs/susfs.c <<'PYEOF'
import sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
if 'SUSFS_LOGI_RL' in s and '#ifndef SUSFS_LOGI_RL' not in s:
    stub = """#ifndef SUSFS_LOGI_RL
#define SUSFS_LOGI_RL(fmt, ...)
#endif
#ifndef SUSFS_LOGE_RL
#define SUSFS_LOGE_RL(fmt, ...)
#endif

"""
    i = s.find('/* selinux hide */')
    if i < 0: i = s.find('static DEFINE_MUTEX(')
    if i < 0: sys.exit('fs/susfs.c: no anchor for the SUSFS_LOG*_RL stubs')
    open(p, 'w', encoding='utf-8').write(s[:i] + stub + s[i:]); print('added SUSFS_LOGI_RL/LOGE_RL stubs')
PYEOF
python3 "$WILD_SCRIPTS/susfs_guard_priority_helpers.py" fs/susfs.c
python3 "$WILD_SCRIPTS/susfs_restore_context.py" "$PATCH" "$PWD"
# adapts the patch to this sublevel's exec.c / task_mmu.c shape, then applies it with patch(1)
python3 "$WILD_SCRIPTS/apply_susfs_compat.py" "$PWD" "$PATCH"
python3 "$WILD_SCRIPTS/susfs_fdinfo_fanotify_arity.py" "$PWD"
# patch(1) leaves *.orig backups for hunks that applied with an offset: harmless. A *.rej is a failed hunk: fatal.
if find . -name '*.rej' -not -path './.git/*' | grep -q .; then find . -name '*.rej' -not -path './.git/*' -exec cat {} +; die "SUSFS patch left rejects"; fi
find . -name '*.orig' -not -path './.git/*' -delete
# SUS_MAP/OPEN_REDIRECT use VMA_PAD_START() which older trees lack
if grep -q 'VMA_PAD_START(' fs/proc/task_mmu.c && ! grep -qE 'pgsize_migration|define VMA_PAD_START' fs/proc/task_mmu.c; then
  sed -i '1a #ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif' fs/proc/task_mmu.c
  echo "added VMA_PAD_START fallback"
fi
rm -f "$PATCH"
# every ksu_* symbol the SUSFS hooks call must be defined by Nova
missing=0
for sym in $(grep -rhoE '\bksu_[a-z0-9_]+\(' fs kernel include/linux drivers/input 2>/dev/null | tr -d '(' | sort -u); do
  grep -rqE "\b${sym}\b" "$NOVA/kernel" || { echo "UNRESOLVED: $sym is called by the SUSFS hooks but not defined by Nova"; missing=1; }
done
[ "$missing" = 0 ] || die "Nova does not provide every hook SUSFS calls (see UNRESOLVED above)"

# --------------------------------------------------------------------------------------------------------
say "5/10 NoMount"
[ ! -e fs/nomount ] || die "fs/nomount already exists"
retry git clone -q --no-checkout "$NOMOUNT_REPO" NoMount
git -C NoMount fetch -q --depth=1 origin "$NOMOUNT_PIN"
git -C NoMount checkout -q --detach "$NOMOUNT_PIN"
curl -fsSL --retry 5 --retry-all-errors -o "$WORK/nomount-setup.sh" \
  "https://raw.githubusercontent.com/maxsteeel/nomount/$NOMOUNT_PIN/kernel/setup.sh"
sh "$WORK/nomount-setup.sh" "$NOMOUNT_PIN"
[ -L fs/nomount ] || die "NoMount setup did not create the fs/nomount link"
[ "$(git -C NoMount rev-parse HEAD)" = "$NOMOUNT_PIN" ] || die "NoMount moved off its pin"
grep -q 'nomount' fs/Makefile && grep -q 'nomount' fs/Kconfig || die "NoMount is not wired into fs/Makefile and fs/Kconfig"

# --------------------------------------------------------------------------------------------------------
say "6/10 Baseband Guard"
# setup.sh does `git clone --branch <ref>`, which only accepts branch/tag names, so pre-clone at the exact commit
clone_at "$BBG_REPO" "$KROOT/Baseband-guard" "$BBG_PIN"
( cd "$KROOT"
  curl -fsSL --retry 5 --retry-all-errors -o "$WORK/bbg-setup.sh" \
    "https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/$BBG_PIN/setup.sh"
  sh "$WORK/bbg-setup.sh" "$BBG_PIN" )
[ "$(git -C "$KROOT/Baseband-guard" rev-parse HEAD)" = "$BBG_PIN" ] || die "Baseband Guard moved off its pin"
# put it in the default LSM order
# same position as Baseband Guard's own setup and the sukisu-op15r build that boots on the phone: right after lockdown
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/lockdown/lockdown,baseband_guard/ } }' security/Kconfig
grep -q 'baseband_guard' security/Kconfig || die "baseband_guard missing from the LSM order"
# It is a static LSM, so it needs a slot: with only 5 slots (capability, selinux, safesetid, bpf, landlock) the
# kernel would drop the last ordered LSM ("bpf") at boot with a warning. Count it in MAX_LSM_COUNT.
python3 - include/linux/lsm_count.h <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
if "BBG_ENABLED" in s:
    sys.exit(0)
block = ("#if IS_ENABLED(CONFIG_BBG)\n#define BBG_ENABLED 1,\n#else\n#define BBG_ENABLED\n#endif\n\n")
anchor = "/*\n *  There is a trailing comma"
if s.count(anchor) != 1 or s.count("\t\tCAPABILITIES_ENABLED\t\\\n") != 1:
    sys.exit("lsm_count.h anchors moved")
s = s.replace(anchor, block + anchor, 1)
s = s.replace("\t\tCAPABILITIES_ENABLED\t\\\n", "\t\tCAPABILITIES_ENABLED\t\\\n\t\tBBG_ENABLED\t\t\\\n", 1)
open(p, "w").write(s)
PY
grep -q 'BBG_ENABLED		\\' include/linux/lsm_count.h || die "lsm_count.h not patched"

# --------------------------------------------------------------------------------------------------------
say "7/10 NTSync"
rm -f include/uapi/linux/ntsync.h drivers/misc/ntsync.c      # stale stub in the GKI tree
apply_patch "$WP/ntsync/ntsync_compat_android16-6.12.patch"
apply_patch "$WP/ntsync/ntsync_base.patch"
# stock Kconfig makes NTSYNC depend on BROKEN, which silently drops CONFIG_NTSYNC=y
if grep -qE '^\s*depends on BROKEN' drivers/misc/Kconfig; then
  python3 - drivers/misc/Kconfig <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r'(config NTSYNC\n(?:\t.*\n|\n(?=\t))*)', s)
if not m: sys.exit("config NTSYNC block not found")
blk = m.group(1); new = blk.replace("\tdepends on BROKEN\n", "")
if blk == new: sys.exit("NTSYNC block has no 'depends on BROKEN'")
open(p, "w").write(s.replace(blk, new, 1))
PY
fi
need_symbol NTSYNC

# --------------------------------------------------------------------------------------------------------
say "8/10 Unicode bypass fix (experimental, WildKernels)"
if [ "${WITH_UNICODE:-true}" = true ]; then
  apply_patch "$WP/unicode_bypass_fix_6.1+.patch"
else
  echo "skipped (WITH_UNICODE=false)"
fi

# --------------------------------------------------------------------------------------------------------
say "9/10 networking: CIFS and BBR"
# BBRv1 is the in-tree tcp_bbr. The BBRv3 backport (kernel_patches/common/bbrv3) is NOT applied: WildKernels disables it
# on android16-6.12 too, and it changes kABI-covered structures (tcp_sock, tcp_skb_cb, rate_sample) that the phone's
# prebuilt vendor modules were compiled against; the module CRC bypass would hide a layout mismatch.
# CIFS=y pulls NETFS_SUPPORT=y; Kleaf fails if its GKI module list still names fs/netfs/netfs.ko.
python3 "$WILD_SCRIPTS/cifs_modules_fix.py" "$PWD" fs/netfs/netfs.ko

# --------------------------------------------------------------------------------------------------------
say "10/10 tuning patches (memory, I/O, scheduler, network)"
if [ "${WITH_TUNING:-false}" != true ]; then
  echo "skipped (WITH_TUNING=false)"
else
# Audited one by one (see README). Left out on purpose:
#   optimise_memcmp.patch              uses NEON q-registers inside kernel memcmp without kernel_neon_begin()
#   add_timeout_wakelocks_globally     silently gives every userspace wakelock a 500 ms timeout
for p in optimized_mem_operations file_struct_8bytes_align reduce_cache_pressure mem_opt_prefetch \
         minimise_wakeup_time int_sqrt reduce_gc_thread_sleep_time f2fs_reduce_congestion reduce_freeze_timeout \
         disable_cache_hot_buddy f2fs_enlarge_min_fsync_blocks increase_ext4_default_commit_age \
         increase_sk_mem_packets reduce_pci_pme_wakeups silence_irq_cpu_logspam silence_system_logspam; do
  echo "-- $p"
  apply_patch "$WP/$p.patch" -F3
done

# clear_page: since 5.16 the arm64 symbol is __pi_clear_page
echo "-- clear_page_16bytes_align"
sed 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' "$WP/clear_page_16bytes_align.patch" > "$WORK/clear_page.patch"
grep -q '__pi_clear_page' arch/arm64/lib/clear_page.S || die "arch/arm64/lib/clear_page.S has no __pi_clear_page (patch would not match)"
apply_patch "$WORK/clear_page.patch" -F3

# s2idle: the patch's context expects pm_system_wakeup() without the fs-sync abort that Android added
echo "-- avoid_extra_s2idle_wake_attempts"
if sed -n '/^void pm_system_wakeup(void)/,/^}/p' drivers/base/power/wakeup.c | grep -q 'suspend_abort_fs_sync();'; then
  sed -i '/^void pm_system_wakeup(void)/,/^}/{/suspend_abort_fs_sync();/d}' drivers/base/power/wakeup.c
fi
apply_patch "$WP/avoid_extra_s2idle_wake_attempts.patch" -F3
fi

say "integration finished"
git -C "$K" status --short | head -60 || true
