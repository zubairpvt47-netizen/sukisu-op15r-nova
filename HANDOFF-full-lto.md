# Handoff: review the full-LTO SukiSU Nova kernel on a booted OnePlus 15R

You are a local Claude Code session with `adb` access to the owner's phone. Your job: **review the running full-LTO kernel,
look for warnings and problems, and give a green flag only if everything is right and nothing harms the device.**
Work read-only. Do not flash, write partitions, change props, install modules or reboot without asking the owner first.

## What is on the phone

- Release: https://github.com/zubairpvt47-netizen/sukisu-op15r-nova/releases/tag/nova-6.12.69-lto-full-20261118-1655
  (AnyKernel3 zip, raw `Image`, `final.config`, `SHA256SUMS.txt`, SukiSU Nova manager APK v3.0.0_35000)
- Source: branch `claude/magical-shannon-17hfjx` of `zubairpvt47-netizen/sukisu-op15r-nova`, CI run 44344840412
- Kernel: Google `android16-6.12-2026-03_r54` (commit `242e1a07f878`, Linux 6.12.69), the tree the stock kernel is built from.
  Stock `uname -r`: `6.12.69-android16-6-g242e1a07f878-ab15865446-4k`. The vendor modules need this exact vermagic.
- Added: SukiSU Nova (builtin, KPM on), SUSFS, NoMount, Baseband Guard (LSM after selinux), NTSync, Unicode bypass fix,
  CIFS, BBR, 18 WildKernels tuning patches.
- Device: OnePlus 15R (CPH2767 / OP612DL1), Snapdragon "canoe", 64-bit only.

## Why this build is different (what to check carefully)

1. **Full LTO.** An earlier full-LTO build (run 44023154385, Image 53.4 MiB) fell to fastboot. The cause was unbounded
   cross-file inlining; this build caps it at link time (`-mllvm -inline-threshold=0 -inlinehint-threshold=0
   -hot-callsite-threshold=0`, only for `CONFIG_LTO_CLANG_FULL`). Image is now 45.69 MiB in memory (thin, which boots: 46.25).
2. **Rust is off** with any LTO (BTF on). So:
   - binder: built-in C driver (`CONFIG_ANDROID_BINDER_IPC=y`), `rust_binder.ko` not built.
   - ashmem: the 2026-03 Rust driver is replaced by Google's C driver from `android16-6.12-2025-12_r63`, plus
     `ashmem_memfd_ioctl` ported from `ashmem.rs`, plus exports `is_ashmem_file`, `ashmem_area_name/size/vmfile` for
     oplus vendor modules. The phone really uses `/dev/ashmem` (`sys.use_memfd=false`).
3. `CONFIG_MODULE_SIG_PROTECT=n` (with it on, Google-signed GKI modules such as rfkill were refused, so no Wi-Fi/BT).
4. Module CRC mismatch is allowed (configure.sh), so a vendor module with a changed struct layout would still load.
   Look for any sign of that (oopses in vendor modules).

CI already passed: config assertions (`config/required.txt`), Image size gate, `verify.sh` (exports, trusted manager
cert only), aarch64-only AnyKernel3 tools. No compiler warnings surfaced in the CI log (only a GitHub Node.js 20 notice).

## Checks (read-only)

```bash
adb shell uname -a
adb shell cat /proc/version
adb shell getprop ro.boot.slot_suffix
adb shell su -c 'zcat /proc/config.gz' > running.config   # compare LTO_CLANG_FULL=y, KSU=y, KPM=y, ASHMEM=y with final.config
```

Kernel log, the most important part:

```bash
adb shell su -c 'dmesg' > dmesg.txt
adb shell su -c 'cat /proc/last_kmsg 2>/dev/null; cat /sys/fs/pstore/* 2>/dev/null' > pstore.txt
```

In `dmesg.txt` search for, and report every hit with context:
`Oops|BUG:|WARNING:|Call trace|panic|Unable to handle|kernel BUG|refcount_t|list_add corruption|CFI failure|kcfi|
disagrees about version|Unknown symbol|module verification failed|exports protected symbol|-EPERM|invalid module format|
ashmem|binder|lsm|baseband|susfs|KernelSU|ksu|kpm|nomount|ntsync|watchdog|rcu.*stall|soft lockup|hung_task|thermal|
avc:.*denied` (SELinux denials: note them, a few are normal on stock too; look for ones caused by root/su).

Modules and drivers:

```bash
adb shell su -c 'lsmod | wc -l; lsmod' > lsmod.txt
adb shell su -c 'cat /proc/modules | grep -v Live'      # anything not Live
adb shell su -c 'ls /dev/ashmem* /dev/binderfs 2>&1; cat /proc/filesystems | grep -E "binder|cifs|f2fs"'
adb shell su -c 'grep -c ashmem /proc/*/maps 2>/dev/null | awk -F: "{s+=\$2} END{print s}"'   # ashmem in use
adb shell su -c 'cat /sys/kernel/security/lsm'          # expect ...selinux,baseband_guard,...
adb shell su -c 'getenforce'                            # must be Enforcing
adb shell su -c 'sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_available_congestion_control'
```

Functions the owner cares about (confirm each works):
- Wi-Fi, Bluetooth, mobile data/calls/SMS (modem), camera, fingerprint, NFC, audio, charging, display refresh rates.
- `adb shell dumpsys wifi | head`, `adb shell dumpsys bluetooth_manager | head`, `adb shell dumpsys telephony.registry | grep -i mServiceState`.
- SukiSU Nova manager: root granted, KPM page loads, SUSFS status shown.
- Suspend/resume: screen off 2+ minutes, wake, check `dmesg` again for new errors; `adb shell su -c 'cat /sys/power/suspend_stats/*'`.
- Stability: `adb shell uptime`; ideally let it run for some hours, then re-check dmesg and `pstore`.

Thermal and battery sanity (no runaway):
```bash
adb shell su -c 'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp)"; done' | sort -k2 -n | tail
adb shell dumpsys battery
```

## Give the verdict

- **Green flag** only if: correct `uname`, LTO_CLANG_FULL in the running config, no Oops/BUG/WARNING/CFI/panic, no module
  load refusals, `/dev/ashmem` present and used, SELinux Enforcing, baseband_guard in the LSM list, and all listed
  functions work, including after a suspend/resume.
- Otherwise: list each problem with the log lines, say how serious it is, and whether to go back to the thin-LTO build.
- Recovery if anything is wrong: flash the stock boot image (`fastboot flash boot stock_boot.img`), or the thin build.
  Ask the owner before doing it.
