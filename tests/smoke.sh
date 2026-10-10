#!/bin/sh
# Offline BusyBox ash integration smoke. Run from repository root.
set -eu
cd "$(dirname "$0")/.."
for f in NVR/v2/nvr.sh NVR/v2/install-router.sh NVR/v2/fresh-install.sh NVR/v2/bootstrap.sh; do
  sh -n "$f"
  busybox sh -n "$f"
done
T=$(mktemp -d)
cleanup() {
  NVR_CONFIG="$T/conf" sh NVR/v2/nvr.sh stop >/dev/null 2>&1 || :
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/mount/cctv" "$T/state"
M="$T/mount"
printf '/dev/mock %s ext4 rw,relatime 0 0\n' "$M" > "$T/mounts"
gcc -Wall -Wextra -O2 -o "$T/ffmpeg" tests/ffmpeg-stub.c
cat > "$T/conf" <<EOT
NVR_MOUNT='$M'
NVR_BASE_DIR='$M/cctv'
RTSP_USER='dummy'
RTSP_PASS='test-only-secret'
RTSP_IP='192.0.2.1'
NVR_STATE_DIR='$T/state'
NVR_MOUNTS_FILE='$T/mounts'
NVR_FFMPEG='$T/ffmpeg'
NVR_CAMERAS='101 201 301'
NVR_STALE_SECONDS=120
NVR_GRACE_SECONDS=0
NVR_RETENTION_SECONDS=259200
NVR_DISK_WARN_PERCENT=75
NVR_DISK_CRIT_PERCENT=90
EOT
NVR() { NVR_CONFIG="$T/conf" busybox sh NVR/v2/nvr.sh "$@"; }

# Status basics: v2.4 report format, standalone (no notification transports).
NVR status | grep -q 'NVR v2.4 - '
NVR status | grep -q 'DISK: RW,'
NVR status | grep -q 'RETENTION: 72 hours'
NVR status | grep -q 'SEGMENT: 900 seconds'
NVR status | grep -q 'LAST CLEANUP: never'
NVR status | grep -q 'ALERTS: disabled'
if NVR notify test; then
  echo 'ERROR notify test must fail without configured transports' >&2; exit 1
fi

NVR start
sleep 2
for id in 101 201 301; do
  [ "$(cat "$T/state/cam$id.pid")" -gt 1 ]
  [ -n "$(find "$M/cctv/cam$id" -name '*.mkv' -type f -size +0c -print -quit)" ]
done
p0=$(cat "$T/state/cam101.pid")
p201=$(cat "$T/state/cam201.pid")
p301=$(cat "$T/state/cam301.pid")
# A healthy check must not restart anything and must record check state.
NVR check
[ "$(cat "$T/state/cam101.pid")" = "$p0" ]
[ -f "$T/state/check.state" ]
NVR status | grep -q 'LAST CHECK: '
# One stalled camera must be restarted, others left untouched.
kill -STOP "$p0"
f=$(find "$M/cctv/cam101" -name '*.mkv' | head -n 1)
touch -d '1 hour ago' "$f"
for suffix in started last_try failures; do printf '0\n' > "$T/state/cam101.$suffix"; done
NVR check
[ "$(cat "$T/state/cam101.pid")" != "$p0" ]
[ "$(cat "$T/state/cam201.pid")" = "$p201" ]
[ "$(cat "$T/state/cam301.pid")" = "$p301" ]

# Expire only old (>72h) segments in each camera folder.
printf 'old\n' > "$M/cctv/cam101/cam101_old.mkv"
touch -d '73 hours ago' "$M/cctv/cam101/cam101_old.mkv"
printf 'keep\n' > "$M/cctv/cam201/cam201_keep.mkv"
touch -d '71 hours ago' "$M/cctv/cam201/cam201_keep.mkv"
NVR cleanup
[ ! -f "$M/cctv/cam101/cam101_old.mkv" ]
[ -f "$M/cctv/cam201/cam201_keep.mkv" ]
grep -q '^CLEANUP_RESULT=OK$' "$T/state/cleanup.state"
NVR status | grep -q 'LAST CLEANUP: .* OK'
NVR status | grep -q 'REMOVED FILES: 1'

# Durable stop: cron check must not resurrect paused cameras.
NVR stop
[ -f "$T/state/paused" ]
NVR status | grep -q 'NVR v2.4 - PAUSED'
p_after_stop=$(cat "$T/state/cam101.pid" 2>/dev/null || :)
[ -z "$p_after_stop" ]
NVR check
[ -z "$(cat "$T/state/cam101.pid" 2>/dev/null || :)" ]
# Retention keeps working while paused.
printf 'old while paused\n' > "$M/cctv/cam201/cam201_paused_old.mkv"
touch -d '80 hours ago' "$M/cctv/cam201/cam201_paused_old.mkv"
NVR cleanup
[ ! -f "$M/cctv/cam201/cam201_paused_old.mkv" ]
NVR resume
sleep 2
[ "$(cat "$T/state/cam101.pid" 2>/dev/null || :)" -gt 1 ] 2>/dev/null || {
  echo 'ERROR resume did not restart cameras' >&2; exit 1
}

# If a camera is stopped, its completed last old file still expires by age.
NVR stop
printf 'old final\n' > "$M/cctv/cam301/cam301_final.mkv"
touch -d '5 days ago' "$M/cctv/cam301/cam301_final.mkv"
NVR cleanup
[ ! -f "$M/cctv/cam301/cam301_final.mkv" ]

# Leave paused state before the fail-closed tests: a paused check is a
# deliberate no-op and would mask the read-only refusal below.
NVR resume || :

# Mount read-only: fail closed, never delete.
printf '/dev/mock %s ext4 ro,relatime 0 0\n' "$M" > "$T/mounts"
if NVR cleanup; then
  echo 'ERROR cleanup succeeded with read-only mount' >&2; exit 1
fi
grep -q '^CLEANUP_RESULT=FAILED$' "$T/state/cleanup.state"
if NVR check; then
  echo 'ERROR health check succeeded with read-only mount' >&2; exit 1
fi

# Event log redaction: planted rtsp credentials must never surface via logs.
printf '/dev/mock %s ext4 rw,relatime 0 0\n' "$M" > "$T/mounts"
printf 'manual line rtsp://operator:leaked-pass@10.0.0.9:554/Streaming/Channels/101\n' >> "$T/state/events.log"
if NVR logs 10 | grep -q 'leaked-pass'; then
  echo 'ERROR logs exposed rtsp credential' >&2; exit 1
fi
NVR logs 10 | grep -q '\[REDACTED\]'

# No credentials anywhere in the persisted event log.
if grep -q 'test-only-secret' "$M/cctv/.nvr-v2/events.log" 2>/dev/null; then
  echo 'ERROR leaked credential in events.log' >&2; exit 1
fi

echo 'BusyBox ash NVR v2.4 smoke PASS'
