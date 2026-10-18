#!/bin/sh
# Verify read-only mount classification and detection of NAND-backed RAM paths.
set -eu
cd "$(dirname "$0")/.."
sh -n tools/nand-audit.sh
busybox sh -n tools/nand-audit.sh
T=$(mktemp -d /tmp/knvr-nand-audit.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/internal/opt/var/log" "$T/ram"
export NAND_AUDIT_OPT="$T/internal/opt"
export NAND_AUDIT_TMP="$T/ram"
export NAND_AUDIT_MOUNTS="$T/mounts"
printf '/dev/ubi0_0 %s ubifs rw 0 0\ntmpfs %s tmpfs rw 0 0\n' \
    "$T/internal" "$T/ram" > "$NAND_AUDIT_MOUNTS"
busybox sh tools/nand-audit.sh > "$T/pass.log"
grep -q 'PASS /opt: internal UBIFS' "$T/pass.log"
grep -q 'PASS /tmp: tmpfs' "$T/pass.log"
grep -q 'WARN /opt/var/log: still on UBIFS' "$T/pass.log"
printf '/dev/ubi0_0 %s ubifs rw 0 0\n/dev/ubi0_0 %s ubifs rw 0 0\n' \
    "$T/internal" "$T/ram" > "$NAND_AUDIT_MOUNTS"
if busybox sh tools/nand-audit.sh > "$T/fail.log"; then
    echo 'FAIL: NAND-backed /tmp accepted by auditor' >&2; exit 1
fi
grep -q 'FAIL /tmp: not proven tmpfs' "$T/fail.log"
echo 'Keenetic internal UBIFS audit PASS (read-only, tmpfs failure, directories)'
