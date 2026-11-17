#!/usr/bin/env bash
# Write config/required.txt into gki_defconfig and wire the build for stock vendor modules.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/pins.env"
source "$HERE/scripts/lib.sh"
: "${KROOT:?}" "${WORK:?}"
K="$KROOT/common"
cd "$K"
DEFCONFIG=arch/arm64/configs/gki_defconfig
[ -f "$DEFCONFIG" ] || die "$DEFCONFIG missing"

say "defconfig: apply config/required.txt"
# -R follows the symlinked drivers (Nova, NoMount, Baseband Guard); symbols can be indented inside choice/if blocks
grep -RhoE '^[[:space:]]*(menu)?config[[:space:]]+[A-Za-z0-9_]+' --include='Kconfig*' . | awk '{print $NF}' | sort -u > "$WORK/kconfig-symbols.txt"
echo "$(wc -l < "$WORK/kconfig-symbols.txt") Kconfig symbols in the patched tree"

# BBRv3 as its own algorithm exists only when the BBRv3 patch was applied; BBR itself is the in-tree one
: > "$WORK/extra-config.txt"
if grep -qx 'TCP_CONG_BBR3' "$WORK/kconfig-symbols.txt"; then
  echo "TCP_CONG_BBR3 present -> enabling"
  echo 'CONFIG_TCP_CONG_BBR3=y' >> "$WORK/extra-config.txt"
fi

# report every unknown symbol at once, then fail once
unknown=()
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; [ -z "$line" ] && continue
  grep -qx "${line%%=*}" <(sed 's/^/CONFIG_/' "$WORK/kconfig-symbols.txt") || unknown+=("${line%%=*}")
done < <(cat "$HERE/config/required.txt" "$WORK/extra-config.txt")
if [ "${#unknown[@]}" -gt 0 ]; then
  printf 'unknown Kconfig symbol: %s\n' "${unknown[@]}" >&2
  die "${#unknown[@]} option(s) in config/required.txt do not exist in this tree"
fi

while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; [ -z "$line" ] && continue
  key="${line%%=*}"; val="${line#*=}"
  case "$val" in
    y) bash scripts/config --file "$DEFCONFIG" --enable "$key" ;;
    n) bash scripts/config --file "$DEFCONFIG" --disable "$key" ;;
    \"*\") bash scripts/config --file "$DEFCONFIG" --set-str "$key" "${val//\"/}" ;;
    *) bash scripts/config --file "$DEFCONFIG" --set-val "$key" "$val" ;;
  esac
done < <(cat "$HERE/config/required.txt" "$WORK/extra-config.txt")
grep -E '^CONFIG_(KSU|NOMOUNT|BBG|NTSYNC|DEFAULT_TCP_CONG)=' "$DEFCONFIG"

say "build wiring (Kleaf)"
# our extra options are not in Google's ABI-checked defconfig: disable check_defconfig on the kernel_aarch64 target only
python3 - BUILD.bazel <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r'common_kernel\(\n    name = "kernel_aarch64",\n', s)
if not m: sys.exit('BUILD.bazel: common_kernel(name = "kernel_aarch64") not found')
end = s.index('\n)\n', m.end())
if 'check_defconfig' in s[m.end():end]:
    print('kernel_aarch64 already sets check_defconfig'); sys.exit(0)
s = s[:m.end()] + '    check_defconfig = "disabled",\n' + s[m.end():]
open(p, 'w').write(s); print('check_defconfig disabled on kernel_aarch64')
PY
sed -i 's/check_defconfig//' build.config.gki 2>/dev/null || true

# Stock vendor modules are not signed with a key of ours. Google's "protected exports" / protected-module lists
# refuse unsigned modules certain symbols (-EPERM at insmod: no Wi-Fi, no modem), so drop them.
rm -rf android/abi_gki_protected_exports_*
perl -0pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*\n//mg' BUILD.bazel
perl -pi -e 's/^\s*protected_module_names_list\s*=\s*":[A-Za-z0-9_]*_protected_module_names",\s*\n//' BUILD.bazel
grep -q 'protected_exports_list' BUILD.bazel && die "protected_exports_list still referenced"
grep -q 'protected_module_names_list' BUILD.bazel && die "protected_module_names_list still referenced"
echo "protected exports/module lists removed"

# Rebuilt exports can carry different symbol CRCs than the stock kernel's (new headers change DWARF-derived CRCs
# even when struct layouts are identical). Let a module with a CRC mismatch load.
VERSION_C=kernel/module/version.c
grep -q 'bad_version:' "$VERSION_C" || die "$VERSION_C has no bad_version label"
sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$VERSION_C"
grep -A6 'bad_version:' "$VERSION_C" | grep -q 'return 1;' || die "module CRC bypass was not applied"
echo "module CRC bypass applied"

say "release string"
# setlocalversion prints the WHOLE release (version + CONFIG_LOCALVERSION + scm part): only strip the dirty marker
sed -i 's/-dirty//' scripts/setlocalversion
[ -f ../build/kernel/kleaf/impl/stamp.bzl ] && sed -i '/stable_scmversion_cmd/s/-maybe-dirty//g' ../build/kernel/kleaf/impl/stamp.bzl || true

# the prebuilt clang sysroot lacks the glibc 2.39 symbols of ubuntu-24.04: link the host tool against the system libc
if [ -f tools/bpf/resolve_btfids/Makefile ]; then
  echo 'override KBUILD_HOSTLDFLAGS += --sysroot=/' >> tools/bpf/resolve_btfids/Makefile
  echo 'override LDFLAGS += --sysroot=/' >> tools/bpf/resolve_btfids/Makefile
fi

# Kleaf wants a clean tree for stamping; commit what we changed (NoMount is a nested clone: keep it out)
EXCL="$(git rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$EXCL")"; echo '/NoMount/' >> "$EXCL"
git add -A . >/dev/null 2>&1 || true
git -c user.name=ci -c user.email=ci@localhost commit -qm "sukisu-op15r-nova: integrated tree" || true
