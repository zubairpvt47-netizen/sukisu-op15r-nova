#!/usr/bin/env bash
# Write config/required.txt into gki_defconfig, wire the build for out-of-tree-signed vendor modules,
# and pin the kernel release string to the phone's.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/pins.env"
source "$HERE/scripts/lib.sh"
: "${KROOT:?}"
K="$KROOT/common"
cd "$K"
DEFCONFIG=arch/arm64/configs/gki_defconfig
[ -f "$DEFCONFIG" ] || die "$DEFCONFIG missing"

say "defconfig: apply config/required.txt"
grep -rhoE '^(menu)?config [A-Za-z0-9_]+' --include='Kconfig*' . | awk '{print $2}' | sort -u > /tmp/kconfig-symbols.txt
echo "$(wc -l < /tmp/kconfig-symbols.txt) Kconfig symbols in the patched tree"

# BBRv3 as its own algorithm exists only when the BBRv3 patch was applied; BBR itself is the in-tree one
if grep -q '^TCP_CONG_BBR3$' /tmp/kconfig-symbols.txt; then
  echo "TCP_CONG_BBR3 present -> enabling"
  echo 'CONFIG_TCP_CONG_BBR3=y' >> "$WORK/extra-config.txt"
fi

apply_cfg() {  # apply_cfg KEY VALUE
  local key="$1" val="$2" sym="${1#CONFIG_}"
  grep -qx "$sym" /tmp/kconfig-symbols.txt || die "$key: no such Kconfig symbol in this tree (typo, or the patch that defines it did not apply)"
  case "$val" in
    y) bash scripts/config --file "$DEFCONFIG" --enable "$key" ;;
    n) bash scripts/config --file "$DEFCONFIG" --disable "$key" ;;
    *) bash scripts/config --file "$DEFCONFIG" --set-val "$key" "${val//\"/}" ;;
  esac
}
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"
  [ -z "$line" ] && continue
  apply_cfg "${line%%=*}" "${line#*=}"
done < <(cat "$HERE/config/required.txt" "${WORK:+$WORK/extra-config.txt}" 2>/dev/null)
# string values: scripts/config --set-val does not quote strings
sed -i 's|^CONFIG_DEFAULT_TCP_CONG=bbr$|CONFIG_DEFAULT_TCP_CONG="bbr"|' "$DEFCONFIG"
grep -E '^CONFIG_(KSU|ZEROMOUNT|NOMOUNT|BBG|NTSYNC)=' "$DEFCONFIG"

say "build wiring (Kleaf)"
# our extra options are not in Google's ABI-checked defconfig
sed -i 's/check_defconfig//' build.config.gki 2>/dev/null || true
if ! grep -q 'check_defconfig = "disabled"' BUILD.bazel; then
  sed -i '/name = "kernel_aarch64",/a\    check_defconfig = "disabled",' BUILD.bazel
fi
grep -q 'check_defconfig = "disabled"' BUILD.bazel || die "could not disable check_defconfig in BUILD.bazel"

# Stock vendor modules are built against Google's ABI and are not signed with a key of ours. Google's
# "protected exports" list refuses unsigned modules the symbols on it (-EPERM at insmod: no Wi-Fi, no modem),
# so drop the list and the protected-module list.
rm -rf android/abi_gki_protected_exports_*
perl -0pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*\n//m' BUILD.bazel
perl -pi -e 's/^\s*protected_module_names_list\s*=\s*":[A-Za-z0-9_]*_protected_module_names",\s*\n//' BUILD.bazel
sed -i 's/^protected_modules = \[.*\]/protected_modules = []/' modules.bzl
grep -q 'protected_exports_list' BUILD.bazel && die "protected_exports_list still referenced"
grep -q 'protected_module_names_list' BUILD.bazel && die "protected_module_names_list still referenced"
grep -q '^protected_modules = \[\]' modules.bzl || die "protected_modules not emptied"

# Rebuilt exports can carry different symbol CRCs than the stock kernel's (new headers change the DWARF-derived
# CRCs of unrelated symbols even when layouts are identical). Let modules with a CRC mismatch load, as a
# version-skew-tolerant kernel does. verify.sh reports how many CRCs actually differ.
VERSION_C=kernel/module/version.c
grep -q 'bad_version:' "$VERSION_C" || die "$VERSION_C has no bad_version label"
sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$VERSION_C"
grep -A6 'bad_version:' "$VERSION_C" | grep -q 'return 1;' || die "module CRC bypass was not applied"

say "kernel release string -> $STOCK_RELEASE"
# Vendor modules carry vermagic '$STOCK_RELEASE SMP preempt mod_unload modversions aarch64'. Pin the SCM part of
# the release to the phone's value and drop the '-dirty' marker the patched tree would add.
SUFFIX="-${STOCK_RELEASE#*-android16-6-}"; SUFFIX="${SUFFIX%-4k}"          # -g242e1a07f878-ab15865446
cat > scripts/setlocalversion <<EOF
#!/bin/sh
# pinned by sukisu-op15r-nova: keep the vermagic of the stock vendor modules
printf '%s' "$SUFFIX"
EOF
chmod +x scripts/setlocalversion
[ -f ../build/kernel/kleaf/impl/stamp.bzl ] && sed -i '/stable_scmversion_cmd/s/-maybe-dirty//g' ../build/kernel/kleaf/impl/stamp.bzl || true
echo "setlocalversion now prints: $("$PWD/scripts/setlocalversion")"

# Kleaf refuses a dirty tree for stamped builds; commit what we changed (NoMount is a nested clone: keep it out)
echo '/NoMount/' >> "$(git rev-parse --git-dir)/info/exclude"
git add -A . >/dev/null 2>&1 || true
git -c user.name=ci -c user.email=ci@localhost commit -qm "sukisu-op15r-nova: integrated tree" || true
