#!/bin/sh
# Isolate status file validation; process ownership is the only mocked boundary.
set -u
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d /tmp/knvr-empty-status.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/mount/cctv/cam101" "$T/state"
printf '/dev/test %s ext4 rw 0 0\n' "$T/mount" > "$T/mounts"
cat > "$T/config" <<CONF
NVR_MOUNT='$T/mount'
NVR_BASE_DIR='$T/mount/cctv'
NVR_CAMERAS='101'
NVR_STATE_DIR='$T/state'
NVR_MOUNTS_FILE='$T/mounts'
RTSP_USER='dummy'
RTSP_PASS='fixture-only'
RTSP_IP='192.0.2.1'
CONF
export NVR_CONFIG="$T/config" NVR_LIB_ONLY=1
. ./NVR/v2/nvr.sh
owned() { return 0; }
printf '%s\n' "$$" > "$STATE/cam101.pid"
printf 'CHECK_LAST_EPOCH=%s\n' "$(date +%s)" > "$STATE/check.state"
file="$NVR_BASE_DIR/cam101/cam101_current.mkv"
: > "$file"
output=$(status)
printf '%s\n' "$output" | grep -q '^CAM 101: STARTING,' || {
    echo 'FAIL: a zero-byte segment was reported as healthy' >&2; exit 1;
}
printf 'some frame bytes\n' > "$file"
output=$(status)
printf '%s\n' "$output" | grep -q '^CAM 101: HEALTHY,' || {
    echo 'FAIL: nonempty recent segment not healthy' >&2; exit 1;
}
echo 'Empty segment status guard PASS'
