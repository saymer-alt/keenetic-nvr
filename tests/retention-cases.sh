#!/bin/sh
# Offline retention matrix: exact age boundaries, open segments, broken
# cameras, clock steps, unreadable entries, missing disk, idempotency.
# Run from repository root. Requires busybox, gcc (only for the open-segment
# case) and GNU-compatible touch/date.
set -eu
cd "$(dirname "$0")/.."
busybox sh -n NVR/v2/nvr.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
M="$T/mount"
RET=259200

setup() {
  rm -rf "$M" "$T/state"
  mkdir -p "$M/cctv" "$T/state"
  printf '/dev/mock %s ext4 rw,relatime 0 0\n' "$M" > "$T/mounts"
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
NVR_RETENTION_SECONDS=$RET
NVR_DISK_WARN_PERCENT=75
NVR_DISK_CRIT_PERCENT=90
EOT
}
seg() { # seg <cam> <suffix> <age_seconds> -> sets SEG_PATH
  SEG_PATH="$M/cctv/cam$1/cam$1_$2.mkv"
  mkdir -p "$(dirname "$SEG_PATH")"
  printf 'data-%s\n' "$2" > "$SEG_PATH"
  ts=$(( $(date +%s) - $3 ))
  touch -d "@$ts" "$SEG_PATH"
}
expect_kept() { [ -f "$1" ] || { echo "FAIL must keep: $1" >&2; exit 1; }; }
expect_gone() { [ ! -e "$1" ] || { echo "FAIL must delete: $1" >&2; exit 1; }; }
NVR() { NVR_CONFIG="$T/conf" busybox sh NVR/v2/nvr.sh "$@"; }

# 1) 71h: keep.
setup
seg 101 71h $(( RET - 3600 ))
NVR cleanup
expect_kept "$SEG_PATH"

# 2) Just inside the boundary (retention minus 60s): keep.
setup
seg 101 fresh $(( RET - 60 ))
NVR cleanup
expect_kept "$SEG_PATH"

# 3) Just past the boundary (retention plus 60s): delete.
setup
seg 101 expired $(( RET + 60 ))
NVR cleanup
expect_gone "$SEG_PATH"

# 4) 73h: delete.
setup
seg 101 73h $(( RET + 3600 ))
NVR cleanup
expect_gone "$SEG_PATH"

# 5) Mixed mtimes across cameras: an OPEN but expired segment of a live
# recorder is protected; other cameras' old files still expire.
setup
gcc -Wall -Wextra -O2 -o "$T/ffmpeg" tests/ffmpeg-stub.c
seg 201 other-old $(( RET + 7200 ))
seg 301 gone-old $(( RET + 3600 ))
# Live recorder on cam101 through the stub: cmdline matches the owned() contract.
mkdir -p "$M/cctv/cam101"
"$T/ffmpeg" -rtsp_transport tcp -i 'rtsp://dummy:test-only-secret@192.0.2.1:554/Streaming/Channels/101' \
  -c copy "$M/cctv/cam101/cam101_%Y-%m-%d_%H-%M-%S.mkv" >/dev/null 2>&1 &
stubpid=$!
sleep 1
printf '%s\n' "$stubpid" > "$T/state/cam101.pid"
printf '%s\n' "$(date +%s)" > "$T/state/cam101.started"
open101=$(ls -t "$M/cctv/cam101"/cam101_*.mkv 2>/dev/null | head -n 1 || :)
[ -n "$open101" ] || { echo 'FAIL stub produced no segment' >&2; exit 1; }
# The open file is long expired by mtime; only the process keeps it alive.
ts=$(( $(date +%s) - RET - 3600 ))
touch -d "@$ts" "$open101"
NVR cleanup
expect_kept "$open101"
expect_gone "$M/cctv/cam201/cam201_other-old.mkv"
expect_gone "$M/cctv/cam301/cam301_gone-old.mkv"
kill -TERM "$stubpid" 2>/dev/null || :
wait "$stubpid" 2>/dev/null || :
# With the recorder gone the same segment expires normally.
NVR cleanup
expect_gone "$open101"

# 6) Broken camera does not block other cameras' cleanup.
setup
seg 101 downcam-old $(( RET + 3600 ))
# no cam101 process at all; cam201 healthy-ish files still expire by age
seg 201 done $(( RET + 10 ))
NVR cleanup
expect_gone "$M/cctv/cam101/cam101_downcam-old.mkv"
expect_gone "$M/cctv/cam201/cam201_done.mkv"

# 7) Future mtime (clock stepped back) is never deleted.
setup
seg 101 future 0
ts=$(( $(date +%s) + 3600 ))
touch -d "@$ts" "$SEG_PATH"
NVR cleanup
expect_kept "$SEG_PATH"

# 8) Dangling symlink and foreign directory entries are skipped, cleanup OK.
setup
seg 101 real $(( RET - 100 ))
ln -sf /nonexistent/target "$M/cctv/cam101/cam101_broken.mkv"
mkdir -p "$M/cctv/cam101/cam101_dir.mkv"
NVR cleanup
expect_kept "$M/cctv/cam101/cam101_real.mkv"
grep -q '^CLEANUP_RESULT=OK$' "$T/state/cleanup.state"

# 9) Disk missing: fail closed, nothing deleted, result FAILED.
setup
seg 101 keepme $(( RET + 7200 ))
printf '/dev/mock /nowhere ext4 rw 0 0\n' > "$T/mounts"
if NVR cleanup; then
  echo 'ERROR cleanup succeeded without mounted disk' >&2; exit 1
fi
expect_kept "$M/cctv/cam101/cam101_keepme.mkv"
grep -q '^CLEANUP_RESULT=FAILED$' "$T/state/cleanup.state"
NVR status | grep -q 'DISK: NOT MOUNTED/READ-ONLY'
NVR status | grep -q 'LAST CLEANUP: .* FAILED'

# 10) Repeated cleanup is idempotent: second run removes nothing, result OK.
setup
seg 101 once $(( RET + 30 ))
NVR cleanup
expect_gone "$M/cctv/cam101/cam101_once.mkv"
NVR cleanup
grep -q '^CLEANUP_REMOVED=0$' "$T/state/cleanup.state"
grep -q '^CLEANUP_RESULT=OK$' "$T/state/cleanup.state"

# 11) Aggressive disk thresholds never evict fresh recordings: deletion stays
# purely age-based (75%/90% are alerts, not eviction triggers).
setup
seg 101 precious $(( RET - 7200 ))
seg 301 junk $(( RET + 3600 ))
sed -i 's/^NVR_DISK_WARN_PERCENT=.*/NVR_DISK_WARN_PERCENT=1/; s/^NVR_DISK_CRIT_PERCENT=.*/NVR_DISK_CRIT_PERCENT=2/' "$T/conf"
NVR cleanup
expect_kept "$M/cctv/cam101/cam101_precious.mkv"
expect_gone "$M/cctv/cam301/cam301_junk.mkv"

# 12) Cleanup state survives a simulated reboot: volatile copy gone, USB copy read.
setup
seg 101 old $(( RET + 60 ))
NVR cleanup
rm -rf "$T/state"
mkdir -p "$T/state"
NVR status | grep -q 'LAST CLEANUP: .* OK'
NVR status | grep -q 'LAST SUCCESSFUL CLEANUP: '

# 13) A partial pass does not replace the last fully successful cleanup.
setup
seg 101 successful $(( RET + 3600 ))
NVR cleanup
sed -i 's/^CLEANUP_OK_EPOCH=.*/CLEANUP_OK_EPOCH=1000000000/; s/^CLEANUP_OK_HUMAN=.*/CLEANUP_OK_HUMAN=2001-09-09 01:46:40/' "$T/state/cleanup.state"
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 busybox sh -c '. NVR/v2/nvr.sh; save_cleanup_state PARTIAL 0 1'
grep -q 'CLEANUP_RESULT=PARTIAL' "$T/state/cleanup.state"
grep -q 'CLEANUP_OK_EPOCH=1000000000' "$T/state/cleanup.state"
NVR status | grep -q 'LAST SUCCESSFUL CLEANUP: 2001-09-09 01:46:40'
echo 'Retention matrix PASS (13 cases)'
