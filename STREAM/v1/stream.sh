#!/bin/sh
# Standalone RTSP -> single-client HTTP MPEG-TS service for Selenga.
# No recorder, cron, archive or disk writes; runtime state lives in /tmp.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
export PATH
SELF=$(readlink -f "$0" 2>/dev/null) || SELF=$0
CONF=${STREAM_CONFIG:-/opt/etc/keenetic-stream.conf}
STATE=${STREAM_STATE_DIR:-/tmp/keenetic-stream}
fail() { printf 'STREAM: %s\n' "$*" >&2; exit 1; }
number() { case "$1" in ''|*[!0-9]*) return 1;; esac; }
state_dir() {
    case "$STATE" in /tmp/*) ;; *) fail 'State must be under /tmp (RAM)' ;; esac
    [ ! -L "$STATE" ] || fail 'Refusing symlinked state directory'
    mkdir -p "$STATE" || fail 'Cannot create state directory'
    actual=$(readlink -f "$STATE" 2>/dev/null) || fail 'Cannot resolve state'
    case "$actual" in /tmp/*) ;; *) fail 'State escapes /tmp' ;; esac
    chmod 700 "$STATE"
}
load_config() {
    [ -r "$CONF" ] || fail "Config not found: $CONF"
    # Config is a trusted, mode 600 root shell file (never commit secrets).
    . "$CONF"
    STREAM_RTSP_HOST=${STREAM_RTSP_HOST:-}
    STREAM_RTSP_PORT=${STREAM_RTSP_PORT:-554}
    STREAM_RTSP_USER=${STREAM_RTSP_USER:-}
    STREAM_RTSP_PASSWORD=${STREAM_RTSP_PASSWORD:-}
    STREAM_BIND=${STREAM_BIND:-}
    STREAM_PLAYLIST_HOST=${STREAM_PLAYLIST_HOST:-}
    STREAM_CHANNELS=${STREAM_CHANNELS:-}
    FFMPEG=${STREAM_FFMPEG_BIN:-/opt/bin/ffmpeg}
    RESTART_DELAY=${STREAM_RESTART_DELAY:-2}
    number "$STREAM_RTSP_PORT" && [ "$STREAM_RTSP_PORT" -gt 0 ] &&
        [ "$STREAM_RTSP_PORT" -le 65535 ] || fail 'Bad RTSP port'
    number "$RESTART_DELAY" && [ "$RESTART_DELAY" -ge 1 ] &&
        [ "$RESTART_DELAY" -le 60 ] || fail 'Bad restart delay'
    case "$STREAM_RTSP_HOST" in ''|*[!a-zA-Z0-9._-]*) fail 'Bad RTSP host' ;; esac
    case "$STREAM_BIND" in ''|*[!0-9.]*) fail 'STREAM_BIND must be a LAN IPv4 address' ;; esac
    case "$STREAM_PLAYLIST_HOST" in ''|*[!0-9.]*) fail 'STREAM_PLAYLIST_HOST must be a LAN IPv4 address' ;; esac
    for credential in "$STREAM_RTSP_USER" "$STREAM_RTSP_PASSWORD"; do
        case "$credential" in ''|YOUR_RTSP_PASSWORD|*[!a-zA-Z0-9._~%-]*)
            fail 'Missing credentials or unescaped RTSP userinfo characters' ;;
        esac
    done
    [ -n "$STREAM_CHANNELS" ] || fail 'No channels'
    seen_ids=' '; seen_ports=' '
    for mapping in $STREAM_CHANNELS; do
        case "$mapping" in *:*) ;; *) fail 'Expected CHANNEL:PORT list' ;; esac
        id=${mapping%%:*}; port=${mapping#*:}
        number "$id" && number "$port" && [ "$id" -gt 0 ] &&
            [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] ||
            fail 'Invalid CHANNEL:PORT'
        case "$seen_ids" in *" $id "*) fail 'Duplicate channel' ;; esac
        case "$seen_ports" in *" $port "*) fail 'Duplicate HTTP port' ;; esac
        seen_ids="$seen_ids$id "; seen_ports="$seen_ports$port "
    done
}
worker_file() { printf '%s/cam%s.worker.pid\n' "$STATE" "$1"; }
ffmpeg_file() { printf '%s/cam%s.ffmpeg.pid\n' "$STATE" "$1"; }
pid_from() {
    value=$(cat "$1" 2>/dev/null || :)
    number "$value" && [ "$value" -gt 1 ] || return 1
    printf '%s\n' "$value"
}
proc_cmd() {
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$1/cmdline"
}
worker_owned() {
    p=$1; id=$2; port=$3
    kill -0 "$p" 2>/dev/null || return 1
    cmd=$(proc_cmd "$p" 2>/dev/null) || return 1
    case "$cmd" in *"$SELF __worker $id $port"*) return 0 ;; *) return 1 ;; esac
}
ffmpeg_owned() {
    p=$1; id=$2; port=$3
    kill -0 "$p" 2>/dev/null || return 1
    cmd=$(proc_cmd "$p" 2>/dev/null) || return 1
    case "$cmd" in *"$FFMPEG"*"-listen 1 http://$STREAM_BIND:$port"*) return 0 ;; *) return 1 ;; esac
}
stop_orphan() {
    id=$1; port=$2
    pf=$(ffmpeg_file "$id")
    p=$(pid_from "$pf" 2>/dev/null || :)
    if [ -n "$p" ] && ffmpeg_owned "$p" "$id" "$port"; then
        kill -TERM "$p" 2>/dev/null || :
        sleep 1
        if ffmpeg_owned "$p" "$id" "$port"; then kill -KILL "$p" 2>/dev/null || :; fi
    fi
    rm -f "$pf"
}
worker() {
    id=$1; port=$2
    state_dir
    child=''
    shutdown_worker() {
        trap - TERM INT HUP
        if [ -n "$child" ]; then
            kill -TERM "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        fi
        pf=$(worker_file "$id")
        old=$(pid_from "$pf" 2>/dev/null || :)
        [ "$old" != "$$" ] || rm -f "$pf"
        rm -f "$(ffmpeg_file "$id")"
        exit 0
    }
    trap shutdown_worker TERM INT HUP
    while :; do
        # A disconnect stops single-client ffmpeg; the worker re-opens HTTP.
        "$FFMPEG" -hide_banner -nostdin -loglevel error \
            -fflags +genpts -rtsp_transport tcp \
            -i "rtsp://$STREAM_RTSP_USER:$STREAM_RTSP_PASSWORD@$STREAM_RTSP_HOST:$STREAM_RTSP_PORT/Streaming/Channels/$id" \
            -map 0:v:0 -map '0:a:0?' -c:v copy \
            -c:a aac -b:a 64k -ar 44100 \
            -mpegts_flags +resend_headers -f mpegts \
            -listen 1 "http://$STREAM_BIND:$port" </dev/null >/dev/null 2>&1 &
        child=$!
        printf '%s\n' "$child" > "$(ffmpeg_file "$id")"
        wait "$child" || :
        child=''
        rm -f "$(ffmpeg_file "$id")"
        sleep "$RESTART_DELAY" &
        wait "$!" || :
    done
}
start() {
    [ -x "$FFMPEG" ] || fail "FFmpeg missing: $FFMPEG"
    state_dir
    lock="$STATE/.start.lock"
    mkdir "$lock" 2>/dev/null || fail 'Another start is in progress'
    trap 'rmdir "$lock" 2>/dev/null || :' EXIT
    for mapping in $STREAM_CHANNELS; do
        id=${mapping%%:*}; port=${mapping#*:}
        pf=$(worker_file "$id")
        p=$(pid_from "$pf" 2>/dev/null || :)
        if [ -n "$p" ] && worker_owned "$p" "$id" "$port"; then
            printf 'Camera %s: already running (%s)\n' "$id" "$port"
            continue
        fi
        stop_orphan "$id" "$port"
        /bin/sh "$SELF" __worker "$id" "$port" </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$pf"
        printf 'Camera %s: started HTTP port %s\n' "$id" "$port"
    done
    rmdir "$lock" || :
    trap - EXIT
}
stop() {
    state_dir
    for mapping in $STREAM_CHANNELS; do
        id=${mapping%%:*}; port=${mapping#*:}
        pf=$(worker_file "$id")
        p=$(pid_from "$pf" 2>/dev/null || :)
        if [ -n "$p" ] && worker_owned "$p" "$id" "$port"; then
            kill -TERM "$p" 2>/dev/null || :
            n=0
            while worker_owned "$p" "$id" "$port" && [ "$n" -lt 5 ]; do
                sleep 1; n=$((n+1))
            done
            if worker_owned "$p" "$id" "$port"; then kill -KILL "$p" 2>/dev/null || :; fi
        fi
        stop_orphan "$id" "$port"
        rm -f "$pf"
        printf 'Camera %s: stopped\n' "$id"
    done
}
status() {
    state_dir
    for mapping in $STREAM_CHANNELS; do
        id=${mapping%%:*}; port=${mapping#*:}
        p=$(pid_from "$(worker_file "$id")" 2>/dev/null || :)
        if [ -n "$p" ] && worker_owned "$p" "$id" "$port"; then
            printf 'Camera %s: WORKER UP, http://%s:%s\n' "$id" "$STREAM_PLAYLIST_HOST" "$port"
        else
            printf 'Camera %s: DOWN, http://%s:%s\n' "$id" "$STREAM_PLAYLIST_HOST" "$port"
        fi
    done
}
playlist() {
    printf '#EXTM3U\n'
    for mapping in $STREAM_CHANNELS; do
        id=${mapping%%:*}; port=${mapping#*:}
        printf '#EXTINF:-1,Camera %s\nhttp://%s:%s\n' "$id" "$STREAM_PLAYLIST_HOST" "$port"
    done
}
case ${1:-} in
    start|stop|restart|status|playlist|check|__worker)
        action=$1; shift
        load_config
        case "$action" in
            start) start ;;
            stop) stop ;;
            restart) stop; start ;;
            status) status ;;
            playlist) playlist ;;
            check)
                [ -x "$FFMPEG" ] || fail "FFmpeg missing: $FFMPEG"
                state_dir
                printf 'STREAM v1 preflight PASS (%s)\n' "$STREAM_CHANNELS" ;;
            __worker)
                [ "$#" -eq 2 ] || fail 'Invalid worker arguments'
                case " $STREAM_CHANNELS " in *" $1:$2 "*) ;; *) fail 'Unknown worker' ;; esac
                worker "$1" "$2" ;;
        esac ;;
    *) printf 'Usage: %s {check|start|stop|restart|status|playlist}\n' "$0" >&2; exit 2 ;;
esac
