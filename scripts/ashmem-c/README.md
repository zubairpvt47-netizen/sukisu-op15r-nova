# C ashmem for LTO builds

With any LTO mode Kconfig turns Rust off (RUST depends on !DEBUG_INFO_BTF || (PAHOLE_HAS_LANG_EXCLUDE && !LTO)),
and android16-6.12-2026-03 only has the **Rust** ashmem driver. The phone uses /dev/ashmem heavily (Android keeps
`sys.use_memfd false`), so an LTO kernel needs a real ashmem driver. Google's own tree had the C driver until
android16-6.12-2025-12; `integrate.sh` swaps it in only when `LTO != none`.

- `ashmem.c`, `ashmem.h`: unmodified, from kernel/common tag `android16-6.12-2025-12_r63`
  (drivers/staging/android/). Hashes are checked by integrate.sh.
- `ashmem_exports.inc`: appended to ashmem.c; implements/exports is_ashmem_file, ashmem_area_name/size/vmfile.
- `uapi/ashmem.h` is byte-identical between the two Google trees, so the tree's own copy is used.
- Not provided (Rust driver only): the misc devices ashmem_unpinning_enable / ashmem_ignore_unset_prot_read /
  ashmem_ignore_unset_prot_exec. Their defaults equal the C driver's behaviour and AOSP init.rc does not write them.

    63bd518d3e739ae6a190b4fc8ebf9359c8745d5e579c6cdf562a8c8776f56089  scripts/ashmem-c/ashmem.c
    94fef78c005a36c16a298a293b28f2a999cce016ce8399818f60b9ed9ea3a4f1  scripts/ashmem-c/ashmem.h
