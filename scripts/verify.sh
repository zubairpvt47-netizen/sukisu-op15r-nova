#!/usr/bin/env bash
# Post-build gate. Fails (non-zero) if the finished kernel is not what config/required.txt promises.
# A compiled Image is not proof of anything: Kconfig drops options whose dependencies are unmet.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/pins.env"
source "$HERE/scripts/lib.sh"
: "${KROOT:?}" "${OUT:?OUT = directory to copy reports into}" "${LTO:=full}"
cd "$KROOT"
mkdir -p "$OUT"
fail=0
bad() { echo "FAIL: $*"; fail=1; }

CFG=$(find bazel-bin/common -name .config -path '*kernel_aarch64*' 2>/dev/null | head -1)
IMG=bazel-bin/common/kernel_aarch64/Image
SYMVERS=$(find bazel-bin/common -name Module.symvers 2>/dev/null | head -1)
[ -f "$CFG" ] || { echo "FAIL: final .config not found"; exit 1; }
[ -f "$IMG" ] || [ "${CONFIG_ONLY:-0}" = 1 ] || { echo "FAIL: Image not found"; exit 1; }
cp "$CFG" "$OUT/final.config"
[ -n "$SYMVERS" ] && cp "$SYMVERS" "$OUT/Module.symvers"
echo "final config: $CFG"

say "1. every option in config/required.txt"
n=0
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"; [ -z "$line" ] && continue
  key="${line%%=*}"; val="${line#*=}"; n=$((n + 1))
  case "$val" in
    y) grep -qx "${key}=y" "$CFG" || bad "$key=y not in final config ($(grep -E "^(# )?${key}[= ]" "$CFG" || echo absent))" ;;
    n) grep -qE "^(# ${key} is not set|${key}=n)$" "$CFG" || ! grep -q "^${key}=" "$CFG" || bad "$key should be off but is $(grep "^${key}=" "$CFG")" ;;
    *) grep -qx "${key}=${val}" "$CFG" || bad "$key=$val not in final config ($(grep -E "^${key}=" "$CFG" || echo absent))" ;;
  esac
done < "$HERE/config/required.txt"
echo "$n options checked"

say "2. LTO"
want="CONFIG_LTO_CLANG_$(echo "$LTO" | tr a-z A-Z)=y"
[ "$LTO" = none ] && want="CONFIG_LTO_NONE=y"
grep -qx "$want" "$CFG" && echo "ok: $want" || bad "$want not in final config ($(grep -E '^CONFIG_LTO' "$CFG" | tr '\n' ' '))"

say "3. LSM order and slots"
lsm=$(sed -n 's/^CONFIG_LSM="\(.*\)"/\1/p' "$CFG")
echo "CONFIG_LSM=$lsm"
case ",$lsm," in *,baseband_guard,*) ;; *) bad "baseband_guard missing from CONFIG_LSM" ;; esac
case ",$lsm," in *,bpf,*) ;; *) bad "bpf missing from CONFIG_LSM" ;; esac
slots=0
for s in CONFIG_SECURITY CONFIG_SECURITY_SELINUX CONFIG_SECURITY_SAFESETID CONFIG_BPF_LSM CONFIG_SECURITY_LANDLOCK CONFIG_BBG \
         CONFIG_SECURITY_SMACK CONFIG_SECURITY_APPARMOR CONFIG_SECURITY_TOMOYO CONFIG_SECURITY_YAMA CONFIG_SECURITY_LOADPIN \
         CONFIG_SECURITY_LOCKDOWN_LSM CONFIG_IMA CONFIG_EVM CONFIG_SECURITY_IPE; do
  grep -qE "^${s}=[ym]$" "$CFG" && slots=$((slots + 1))
done
echo "LSMs enabled in config: $slots"
grep -q 'BBG_ENABLED' include/linux/lsm_count.h 2>/dev/null || grep -q 'BBG_ENABLED' common/include/linux/lsm_count.h || bad "BBG not counted in MAX_LSM_COUNT"

if [ "${CONFIG_ONLY:-0}" = 1 ]; then
  [ "$fail" = 0 ] && echo "CONFIG CHECKS PASSED" || { echo "CONFIG CHECKS FAILED"; exit 1; }
  exit 0
fi

say "4. Image contents"
python3 -I - "$IMG" "$STOCK_RELEASE" <<'PY' || fail=1
import re, sys
img = open(sys.argv[1], "rb").read()
stock = sys.argv[2]
ok = True
m = re.search(rb"Linux version (6\.\S+)", img)
rel = m.group(1).decode() if m else None
print("built release :", rel)
print("stock release :", stock)
if not (rel or "").startswith("6.12.69-android16-6"):
    print("FAIL: release string does not start with 6.12.69-android16-6"); ok = False
elif rel != stock:
    print("NOTE: release differs from stock (modules with CRCs ignore the version token in vermagic)")
for needle, why in [(b"susfs", "SUSFS"), (b"nomount", "NoMount"), (b"baseband_guard", "Baseband Guard"),
                    (b"ntsync", "NTSync"), (b"com.sukisu.nova", "Nova manager package"),
                    (b"947ae944f3de4ed4c21a7e4f7953ecf351bfa2b36239da37a34111ad29993eef", "Nova manager signature hash")]:
    c = img.count(needle)
    print(f"{why:30s} {'ok' if c else 'MISSING'} ({c} hits)")
    ok &= bool(c)
# no other manager package/signature compiled in
for other in (b"me.weishu.kernelsu", b"com.rifsxd.ksunext", b"com.sukisu.ultra", b"me.bmax.apatch"):
    if other in img:
        print("FAIL: foreign manager package present in the Image:", other.decode()); ok = False
# no other manager signing key (upstream Nova trusts 4 extra keys; integrate.sh removes them)
for other in (b"4359c171f32543394cbc23ef908c4bb94cad7c8087002ba164c8230948c21549",
              b"56695cfa454a72060641830a5c64297aaf3f21f8d55db4a21f83d9ab5be0cd19",
              b"484fcba6e6c43b1fb09700633bf2fb4758f13cb0b2f4457b80d075084b26c588",
              b"b9ee6759de4794f954883458b722b97ae6527cb7709a051db9a2348c0eea1e42"):
    if other in img:
        print("FAIL: foreign manager signature present in the Image:", other[:12].decode()); ok = False
sys.exit(0 if ok else 1)
PY

say "4b. ashmem symbols the OnePlus vendor modules import (real Rust driver, or the LTO stand-ins)"
if [ -n "$SYMVERS" ]; then
  for sym in is_ashmem_file ashmem_area_name ashmem_area_size ashmem_area_vmfile; do
    grep -qE "[[:space:]]${sym}[[:space:]]" "$SYMVERS" && echo "ok: $sym exported" || bad "$sym not exported (oplus vendor modules may need it)"
  done
else
  bad "no Module.symvers to check the ashmem exports against"
fi

say "5. exported symbol CRCs vs the boot-tested build"
# The module loader's CRC check is bypassed (configure.sh). Google's ABI file is no reference: on this tree every one of
# its ~10k CRCs differs for any rebuilt kernel (run 44992377848), so it cannot single anything out. Compare instead with
# the Module.symvers of the full-LTO build that boots on the phone (release nova-6.12.69-lto-full-20261118-1655): any
# changed or vanished export is something the vendor modules were not tested against. Report only; list in
# $OUT/abi-crc-diff.txt
REF="$HERE/reference/booting-lto-full-20261118.Module.symvers"
if [ -n "$SYMVERS" ] && [ -f "$REF" ]; then
  python3 -I - "$REF" "$SYMVERS" "$OUT/abi-crc-diff.txt" <<'PY' || echo "::warning::CRC comparison script failed (non-fatal)"
import sys
def load(p):
    d = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        f = line.split("\t")
        if len(f) >= 2 and f[0].startswith("0x"):
            d[f[1]] = int(f[0], 16)
    return d
ref, new, out = load(sys.argv[1]), load(sys.argv[2]), sys.argv[3]
common = sorted(set(ref) & set(new))
diff = [s for s in common if ref[s] != new[s]]
gone = sorted(set(ref) - set(new)); added = sorted(set(new) - set(ref))
with open(out, "w") as fh:
    fh.write(f"# vs boot-tested build: {len(common)} compared, {len(diff)} CRC changed, {len(gone)} gone, {len(added)} new\n")
    for s in diff: fh.write(f"CRC  {s}\tbooting=0x{ref[s]:08x}\tbuilt=0x{new[s]:08x}\n")
    for s in gone: fh.write(f"GONE {s}\n")
    for s in added: fh.write(f"NEW  {s}\n")
print(f"boot-tested build: {len(ref)} exports, this build: {len(new)}")
print(f"{len(diff)} CRC changed, {len(gone)} gone, {len(added)} new")
for s in diff[:40]: print(f"  CRC  {s}")
for s in gone[:20]: print(f"  GONE {s}")
for s in added[:20]: print(f"  NEW  {s}")
if diff or gone:
    print(f"::warning::{len(diff)} export CRCs changed and {len(gone)} exports vanished compared with the boot-tested build (see abi-crc-diff.txt)")
PY
else
  echo "::warning::Module.symvers or the reference file is missing; CRC comparison skipped"
fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
