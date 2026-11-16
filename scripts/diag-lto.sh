#!/usr/bin/env bash
# Read-only diagnostics for LTO builds: why symbols from the KMI list can be missing, and which Kleaf switches exist.
# Prints facts only; never fails the build.
set -uo pipefail
: "${KROOT:?}"
cd "$KROOT"
sec() { printf '\n######## %s\n' "$*"; }

sec "final .config: RUST / BTF / LTO / ashmem / binder"
CFG=$(find bazel-bin/common -name .config -path '*kernel_aarch64*' 2>/dev/null | head -1)
echo "cfg=$CFG"
grep -E '^(# )?CONFIG_(RUST|DEBUG_INFO_BTF|DEBUG_INFO_BTF_MODULES|LTO_[A-Z_]+|CFI_CLANG|MODVERSIONS|GENDWARFKSYMS|ASHMEM|ANDROID_BINDER_IPC[A-Z_]*|ANDROID_BINDERFS|PAHOLE_HAS_LANG_EXCLUDE|PAHOLE_VERSION|HAVE_RUST|RUST_IS_AVAILABLE|TRIM_UNUSED_KSYMS|UNUSED_KSYMS_WHITELIST)[= ]' "$CFG" || true

sec "Kconfig: RUST dependencies"
f=$(grep -rln '^config RUST$' common --include=Kconfig* | head -1); echo "$f"
[ -n "$f" ] && sed -n "/^config RUST\$/,/^config /p" "$f" | head -40

sec "gki_defconfig lines"
grep -nE 'CONFIG_(RUST|DEBUG_INFO_BTF|LTO|CFI|ASHMEM|ANDROID_BINDER|MODVERSIONS|GENDWARFKSYMS)' common/arch/arm64/configs/gki_defconfig || true

sec "where the missing symbols come from (source)"
grep -rnE 'is_ashmem_file|ashmem_area_name|RUST_BINDER_LAYOUT' common --include=*.c --include=*.rs --include=*.h --include=Kconfig* --include=Makefile --include=BUILD.bazel -l 2>/dev/null | head -20
grep -rn 'ashmem' common/drivers/android/Makefile common/drivers/android/Kconfig common/drivers/staging/android/Makefile common/drivers/staging/android/Kconfig 2>/dev/null | head -20

sec "common/BUILD.bazel around kernel_aarch64"
n=$(grep -n 'name = "kernel_aarch64"' common/BUILD.bazel | head -1 | cut -d: -f1); echo "line $n"
sed -n "$((n-10)),$((n+60))p" common/BUILD.bazel 2>/dev/null
grep -nE 'strict_mode|trim_nonlisted|kmi_symbol_list' common/BUILD.bazel | head -20

sec "Kleaf: strict mode / trim / lto switches"
grep -rnE 'strict_mode' build/kernel/kleaf --include=*.bzl --include=BUILD.bazel --include=*.bazelrc --include=bazelrc --include=*.md 2>/dev/null | head -40
echo "--- bazelrc"
grep -nE 'strict|trim|lto|fast' build/kernel/kleaf/bazelrc 2>/dev/null | head -40
echo "--- trim vs lto"
grep -rnE 'trim_nonlisted_kmi' build/kernel/kleaf/impl/*.bzl 2>/dev/null | head -30

sec "KMI symbol lists: ashmem and rust_binder entries"
ls common/android | head -50
grep -nE 'ashmem|rust_binder|RUST_BINDER' common/android/abi_gki_aarch64 2>/dev/null | head -30

sec "in-tree modules list mentioning rust / ashmem"
grep -rnE 'rust_binder|ashmem|rust' common/modules.bzl 2>/dev/null | head -20

sec "pahole / rustc in the Kleaf toolchain"
ls prebuilts 2>/dev/null | head; ls prebuilts/rust 2>/dev/null | head -3; ls prebuilts/kernel-build-tools/linux-x86/bin 2>/dev/null | grep -iE 'pahole' | head
exit 0
