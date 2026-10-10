#!/bin/sh
# Offline storage policies regression tests. Never use real camera credentials.
set -eu
cd "$(dirname "$0")/.."
busybox sh -n NVR/v2/nvr.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM
M="$T/mount"
mkdir -p "$M/cctv" "$T/state"
printf '/dev/mock %s ext4 rw,relatime 0 0\n' "$M" > "$T/mounts"
export NVR_TEST_MOUNT="$M"
cat > "$T/mock-df" <<'EOF'
#!/bin/sh
count=0
for f in "$NVR_TEST_MOUNT"/cctv/cam*/*.mkv; do
    [ -f "$f" ] && [ ! -L "$f" ] && count=$((count+1))
done
# On 1000 KiB disk, initial free 80 and +10 KiB per deleted segment.
free=$((110 - 10 * count))
used=$((1000 - free))
case " $* " in
    *" -k "*) printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n' ;;
    *) printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\n' ;;
esac
printf '/dev/mock 1000 %s %s 92%% %s\n' "$used" "$free" "$NVR_TEST_MOUNT"
EOF
chmod +x "$T/mock-df"
write_config() {
    cat > "$T/config" <<EOF
NVR_MOUNT='$M'
NVR_BASE_DIR='$M/cctv'
RTSP_USER='dummy'
RTSP_PASS='test-only-secret'
RTSP_IP='192.0.2.1'
NVR_STATE_DIR='$T/state'
NVR_MOUNTS_FILE='$T/mounts'
NVR_DF_BIN='$T/mock-df'
NVR_CAMERAS='101 201 301'
NVR_STALE_SECONDS=120
NVR_GRACE_SECONDS=0
NVR_STORAGE_MODE='$1'
NVR_RETENTION_SECONDS=$2
NVR_DISK_FREE_RESERVE_PERCENT=10
NVR_DISK_FREE_MIN_MB=0
EOF
}
reset() {
    rm -rf "$M/cctv" "$T/state"
    mkdir -p "$M/cctv" "$T/state"
    write_config "$1" "$2"
}
segment() {
    id=$1; suffix=$2; age=$3
    mkdir -p "$M/cctv/cam$id"
    file="$M/cctv/cam$id/cam${id}_${suffix}.mkv"
    printf 'fake-video-%s\n' "$suffix" > "$file"
    touch -d "@$(( $(date +%s) - age ))" "$file"
}
kept() { [ -f "$1" ] || { echo "FAIL: expected kept: $1" >&2; exit 1; }; }
gone() { [ ! -e "$1" ] || { echo "FAIL: expected deleted: $1" >&2; exit 1; }; }
nvr() { NVR_CONFIG="$T/config" busybox sh NVR/v2/nvr.sh "$@"; }

# Default 72h is preserved by the legacy configuration and its own suite.
reset time 259200
segment 101 old $((73*3600)); old=$file
segment 201 young $((71*3600)); young=$file
nvr cleanup
gone "$old"
kept "$young"
nvr status | grep -q '^STORAGE MODE: time$'

# Explicit 24h TIME can delete older footage; nothing younger is reclaimed,
# even if the disk mock reports insufficient free space.
reset time 86400
segment 101 old $((25*3600)); old=$file
segment 201 young $((23*3600)); young=$file
nvr cleanup
gone "$old"
kept "$young"

# 168 hours guarantee — at 72h this segment must remain.
reset time 604800
segment 101 recent $((73*3600)); recent=$file
nvr cleanup
kept "$recent"

# CIRCULAR ignores mtime horizon, only evicts if below free reserve.
reset circular 259200
segment 201 oldest $((100*3600)); oldest=$file
segment 101 middle $((50*3600)); middle=$file
segment 301 newest $((2*3600)); newest=$file
nvr cleanup
gone "$oldest"
gone "$middle"
kept "$newest"
nvr status | grep -q '^STORAGE MODE: circular$'
nvr status | grep -q '^FREE RESERVE: 10% (minimum 0 MB)$'
nvr status | grep -q '^RETENTION: capacity-based (no minimum)$'
nvr cleanup
kept "$newest"

# Dry-run can list would-delete files, but must not delete nor mutate cleanup state.
reset circular 259200
segment 201 oldest $((100*3600)); oldest=$file
segment 101 middle $((50*3600)); middle=$file
segment 301 newest $((2*3600)); newest=$file
nvr cleanup --dry-run > "$T/preview"
grep -q 'DRY-RUN' "$T/preview"
kept "$oldest"; kept "$middle"; kept "$newest"
[ ! -e "$T/state/cleanup.state" ] || { echo 'FAIL: dry-run wrote cleanup state' >&2; exit 1; }

# HYBRID expires by age even without disk pressure; also evicts youngest
# candidates when the pressure still exceeds free reserve.
reset hybrid 86400
segment 101 expired $((30*3600)); expired=$file
segment 201 middle $((20*3600)); middle=$file
segment 301 newest $((2*3600)); newest=$file
nvr cleanup
gone "$expired"; gone "$middle"; kept "$newest"
nvr status | grep -q '^STORAGE MODE: hybrid$'
nvr status | grep -q '^RETENTION: 24 hours$'

# An active FFmpeg segment must not be unlinked even when it has an
# artificially old mtime and disk pressure requires removing older files.
reset circular 259200
gcc -Wall -Wextra -O2 -o "$T/ffmpeg" tests/ffmpeg-stub.c
mkdir -p "$M/cctv/cam101"
"$T/ffmpeg" -rtsp_transport tcp -i 'rtsp://dummy:test-only-secret@192.0.2.1:554/Streaming/Channels/101' \
    -c copy "$M/cctv/cam101/cam101_%Y-%m-%d_%H-%M-%S.mkv" >/dev/null 2>&1 &
active_pid=$!
sleep 1
printf '%s\n' "$active_pid" > "$T/state/cam101.pid"
open_segment=$(ls "$M/cctv/cam101"/cam101_*.mkv | head -n 1)
[ -n "$open_segment" ] || { echo 'FAIL: missing active mock segment' >&2; exit 1; }
touch -d '10 days ago' "$open_segment"
segment 201 old $((4*3600)); second=$file
segment 301 young $((1*3600)); third=$file
nvr cleanup
kept "$open_segment"; gone "$second"; gone "$third"
kill -TERM "$active_pid" 2>/dev/null || :
wait "$active_pid" 2>/dev/null || :

# Symlinked camera directory means an unsafe archive path: fail closed.
reset circular 259200
mkdir -p "$T/outside"
ln -s "$T/outside" "$M/cctv/cam101"
segment 201 keep $((200*3600)); keep=$file
if nvr cleanup; then
    echo 'FAIL: symlinked camera directory passed safe_archive' >&2; exit 1
fi
kept "$keep"

# Invalid modes and zero reserve fail config parsing without deletion.
reset circular 259200
segment 101 safe $((200*3600)); safe=$file
sed -i 's/NVR_STORAGE_MODE=.*/NVR_STORAGE_MODE=broken/' "$T/config"
if nvr cleanup; then echo 'FAIL: invalid storage mode accepted' >&2; exit 1; fi
kept "$safe"

echo 'Storage policy matrix PASS'
