#!/bin/sh
# NAND-safe NVR and STREAM runtime state tests; no access to real routers.
set -eu
cd "$(dirname "$0")/.."
busybox sh -n NVR/v2/nvr.sh
busybox sh -n NVR/v2/telegram-bot.sh
busybox sh -n STREAM/v1/stream.sh
T=$(mktemp -d /tmp/knvr-nand-wear.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/archive/cctv" "$T/ram"
printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$T/archive" > "$T/mounts"
config() {
    cat > "$T/conf" <<EOF
NVR_MOUNT='$T/archive'
NVR_BASE_DIR='$T/archive/cctv'
RTSP_USER='test'
RTSP_PASS='test-password'
RTSP_IP='192.0.2.1'
NVR_MOUNTS_FILE='$T/mounts'
NVR_STATE_DIR='$1'
EOF
}
run_nvr() { NVR_CONFIG="$T/conf" busybox sh NVR/v2/nvr.sh status; }
config "$T/ram"
run_nvr >/dev/null
# No forced override may point NVR's 5-min cron writes into /opt/NAND.
config /opt/knvr-nand-test-do-not-create
if run_nvr >/dev/null 2>&1; then
    echo 'FAIL: NVR accepted /opt runtime state' >&2; exit 1
fi
[ ! -e /opt/knvr-nand-test-do-not-create ] ||
    { echo 'FAIL: NVR wrote to internal /opt' >&2; exit 1; }
# Same for symlinks: /tmp/... pointing outside RAM.
ln -s /etc "$T/symlinked"
config "$T/symlinked"
if run_nvr >/dev/null 2>&1; then
    echo 'FAIL: NVR accepted symlink to /etc' >&2; exit 1
fi
# A custom TMPDIR must never divert recorder temp files to internal flash.
config "$T/ram"
(
    TMPDIR=/opt
    export TMPDIR
    NVR_CONFIG="$T/conf"
    export NVR_CONFIG
    NVR_LIB_ONLY=1
    export NVR_LIB_ONLY
    . NVR/v2/nvr.sh
    [ "$TMPDIR" = /tmp ]
)
echo 'NVR RAM-state wear protection PASS'
