#!/bin/sh
# Offline tests for standalone STREAM; no router, camera or external network.
set -eu
cd "$(dirname "$0")/.."
for script in STREAM/v1/stream.sh STREAM/v1/install.sh STREAM/v1/bootstrap.sh STREAM/v1/init.d/S99stream; do
    sh -n "$script"
    busybox sh -n "$script"
done
sh STREAM/v1/install.sh --help | grep -q 'preflight'
T=$(mktemp -d /tmp/knvr-stream-test.XXXXXX)
export STREAM_TEST_LOG="$T/args.log"
export STREAM_CONFIG="$T/config"
export STREAM_STATE_DIR="$T/state"
export STREAM_MOUNTS_FILE="$T/mounts"
printf 'tmpfs /tmp tmpfs rw,nosuid,nodev 0 0\n' > "$STREAM_MOUNTS_FILE"
cleanup() {
    /bin/sh STREAM/v1/stream.sh stop >/dev/null 2>&1 || :
    rm -rf "$T"
}
trap cleanup EXIT HUP INT TERM
cat > "$T/fake-ffmpeg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STREAM_TEST_LOG"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod 700 "$T/fake-ffmpeg"
cat > "$T/config" <<EOF
STREAM_RTSP_HOST='192.0.2.135'
STREAM_RTSP_USER='test-user'
STREAM_RTSP_PASSWORD='test-password'
STREAM_RTSP_PORT=554
STREAM_BIND='127.0.0.1'
STREAM_PLAYLIST_HOST='192.0.2.3'
STREAM_CHANNELS='101:8081 202:8082 302:8083'
STREAM_RESTART_DELAY=1
STREAM_FFMPEG_BIN='$T/fake-ffmpeg'
EOF
stream() { busybox sh STREAM/v1/stream.sh "$@"; }
stream check | grep -q 'preflight PASS'
# Existing NAND/bind mount under /tmp must fail closed.
printf '/dev/ubi0_0 /tmp ubifs rw 0 0\n' > "$STREAM_MOUNTS_FILE"
if stream check >/dev/null 2>&1; then
    echo 'FAIL: accepted NAND-backed /tmp' >&2; exit 1
fi
[ ! -d "$T/state" ] || { echo 'FAIL: created state on NAND-backed /tmp' >&2; exit 1; }
printf 'tmpfs /tmp tmpfs rw,nosuid,nodev 0 0\n' > "$STREAM_MOUNTS_FILE"
# Reject state symlinks escaping RAM before writing any process state.
ln -s /etc "$T/unsafe-state"
STREAM_STATE_DIR="$T/unsafe-state" stream check >/dev/null 2>&1 && {
    echo 'FAIL: accepted symlinked STREAM_STATE_DIR' >&2; exit 1
}
playlist=$(stream playlist)
printf '%s\n' "$playlist" | grep -q '#EXTM3U'
printf '%s\n' "$playlist" | grep -q 'http://192.0.2.3:8081'
printf '%s\n' "$playlist" | grep -q 'http://192.0.2.3:8082'
printf '%s\n' "$playlist" | grep -q 'http://192.0.2.3:8083'
[ "$(printf '%s\n' "$playlist" | grep -c '^#EXTINF')" -eq 3 ]
stream status | grep -q 'Camera 101: DOWN'
stream start > "$T/start.log"
sleep 2
stream status | grep -q 'Camera 101: WORKER UP'
stream status | grep -q 'Camera 202: WORKER UP'
stream status | grep -q 'Camera 302: WORKER UP'
for id in 101 202 302; do
    [ "$(cat "$T/state/cam$id.worker.pid")" -gt 1 ]
    [ "$(cat "$T/state/cam$id.ffmpeg.pid")" -gt 1 ]
done
grep -q -- '-rtsp_transport tcp' "$T/args.log"
grep -q -- '-fflags +genpts' "$T/args.log"
grep -q -- '-c:v copy' "$T/args.log"
grep -q -- '-c:a aac -b:a 64k' "$T/args.log"
grep -q -- '-mpegts_flags +resend_headers' "$T/args.log"
grep -q -- '-listen 1 http://127.0.0.1:8081' "$T/args.log"
# Starting again must not duplicate workers.
old=$(cat "$T/state/cam101.worker.pid")
stream start >/dev/null
[ "$(cat "$T/state/cam101.worker.pid")" = "$old" ]

# Client disconnect / FFmpeg death: only the corresponding worker restarts it.
child=$(cat "$T/state/cam101.ffmpeg.pid")
kill -TERM "$child"
n=0
while [ "$n" -lt 8 ]; do
    new=$(cat "$T/state/cam101.ffmpeg.pid" 2>/dev/null || :)
    [ -n "$new" ] && [ "$new" != "$child" ] && break
    sleep 1
    n=$((n+1))
done
[ -n "$new" ] && [ "$new" != "$child" ] ||
    { echo 'FAIL: stream did not recover after client disconnect' >&2; exit 1; }
[ "$(cat "$T/state/cam101.worker.pid")" = "$old" ]
stream stop >/dev/null
stream status | grep -q 'Camera 101: DOWN'

# A foreign process must never be killed from a forged/stale PID file.
sleep 40 &
unrelated=$!
printf '%s\n' "$unrelated" > "$T/state/cam101.worker.pid"
stream stop >/dev/null
kill -0 "$unrelated" 2>/dev/null ||
    { echo 'FAIL: unrelated process was killed' >&2; exit 1; }
kill -TERM "$unrelated" 2>/dev/null || :
wait "$unrelated" 2>/dev/null || :

# Invalid/missing credentials and duplicate HTTP ports must fail closed.
sed -i "s/test-password/YOUR_RTSP_PASSWORD/" "$T/config"
if stream check >/dev/null 2>&1; then
    echo 'FAIL: unconfigured password was accepted' >&2; exit 1
fi
sed -i "s/YOUR_RTSP_PASSWORD/test-password/; s/202:8082/202:8081/" "$T/config"
if stream check >/dev/null 2>&1; then
    echo 'FAIL: duplicate HTTP port accepted' >&2; exit 1
fi

echo 'STREAM service PASS (3 channels, playlist, restart, scoped stop, credentials)'
