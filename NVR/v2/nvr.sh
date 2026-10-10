#!/bin/sh
# Keenetic/Entware NVR v2.4 — supervised ffmpeg stream-copy recorder.
# Each cron tick is independent; no persistent shell watchdog.
# Retention contract: every finished segment is kept at least NVR_RETENTION_SECONDS
# (default 259200 = 72 h) measured by file mtime. Fullness NEVER shortens it.
set -u
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin

CONFIG=${NVR_CONFIG:-/opt/etc/nvr-v2.conf}
[ -r "$CONFIG" ] || { echo "NVR: missing config: $CONFIG" >&2; exit 2; }
. "$CONFIG"
: "${NVR_MOUNT:?}" "${NVR_BASE_DIR:?}" "${RTSP_USER:?}" "${RTSP_PASS:?}" "${RTSP_IP:?}"
STATE=${NVR_STATE_DIR:-/tmp/nvr-v2}
PDATA="$NVR_BASE_DIR/.nvr-v2"
FFMPEG=${NVR_FFMPEG:-/opt/bin/ffmpeg}
CAMERAS=${NVR_CAMERAS:-'101 201 301'}
STALE=${NVR_STALE_SECONDS:-720}
GRACE=${NVR_GRACE_SECONDS:-600}
RETENTION=${NVR_RETENTION_SECONDS:-259200}
DISK_WARN=${NVR_DISK_WARN_PERCENT:-75}
DISK_CRIT=${NVR_DISK_CRIT_PERCENT:-90}
SEGMENT=900
CLEANUP_STALE=${NVR_CLEANUP_STALE_SECONDS:-7200}
# Notification transports (all optional; without them NVR runs fully standalone).
TG_TOKEN=${NVR_NOTIFY_TELEGRAM_TOKEN:-}
TG_CHAT=${NVR_NOTIFY_TELEGRAM_CHAT:-}
WEBHOOK=${NVR_NOTIFY_WEBHOOK_URL:-}
NOTIFY_REPEAT=${NVR_NOTIFY_REPEAT_SECONDS:-21600}
NOTIFY_TIMEOUT=${NVR_NOTIFY_TIMEOUT:-10}
# 0 keeps byte-parity with v2.3 (raw userinfo); 1 percent-encodes URL-unsafe
# characters of RTSP_USER/RTSP_PASS (installer verifies live which variant works).
RTSP_ENCODE=${NVR_RTSP_ENCODE:-0}
# curl override is a test seam; on the router it must stay the real curl so the
# notification token never appears in /proc cmdline.
CURLBIN=${NVR_CURL:-curl}
NOW=$(date +%s)

isnum() { case ${1:-} in ''|*[!0-9]*) return 1;; esac; return 0; }
numfile() { v=$(cat "$1" 2>/dev/null) || v=0; isnum "$v" || v=0; printf '%s\n' "$v"; }
# Reject dangerous free-form camera identifiers or nonsensical settings.
for id in $CAMERAS; do
    isnum "$id" || { echo 'NVR: numeric camera IDs required' >&2; exit 2; }
done
for v in "$STALE" "$GRACE" "$RETENTION" "$DISK_WARN" "$DISK_CRIT" \
         "$CLEANUP_STALE" "$NOTIFY_REPEAT" "$NOTIFY_TIMEOUT" "$RTSP_ENCODE"; do
    isnum "$v" || { echo 'NVR: invalid numeric configuration' >&2; exit 2; }
done
[ "$STALE" -ge 120 ] && [ "$RETENTION" -ge 259200 ] && \
[ "$DISK_WARN" -ge 1 ] && [ "$DISK_WARN" -le 100 ] && \
[ "$DISK_CRIT" -ge "$DISK_WARN" ] && [ "$DISK_CRIT" -le 100 ] && \
[ "$RTSP_ENCODE" -le 1 ] && [ "$NOTIFY_TIMEOUT" -ge 1 ] && \
[ "$NOTIFY_REPEAT" -ge 60 ] && [ "$CLEANUP_STALE" -ge 3600 ] || exit 2
if [ -n "$TG_CHAT" ]; then
    case $TG_CHAT in
        [0-9]*|-?[0-9]*|@*) : ;;
        *) echo 'NVR: invalid NVR_NOTIFY_TELEGRAM_CHAT' >&2; exit 2;;
    esac
fi
case $WEBHOOK in ''|http://*|https://*) : ;; *) echo 'NVR: NVR_NOTIFY_WEBHOOK_URL must be http(s)' >&2; exit 2;; esac

mounted_rw() {
    awk -v d="$NVR_MOUNT" '$2==d && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' "${NVR_MOUNTS_FILE:-/proc/mounts}"
}
disk_ok() {
    if ! mounted_rw || [ ! -d "$NVR_BASE_DIR" ]; then
        log 'ERROR volume missing, unmounted or read-only; no writes/deletions'
        notify_event CRITICAL volume 'archive volume missing, unmounted or read-only'
        return 1
    fi
    notify_event RECOVERY volume 'archive volume back online, writes confirmed'
    return 0
}
log() {
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$line" >> "$STATE/events.log"
    # Persist event history across reboots, only when actual USB volume is mounted.
    if mounted_rw && [ -d "$NVR_BASE_DIR" ]; then
        mkdir -p "$PDATA" 2>/dev/null || return 0
        printf '%s\n' "$line" >> "$PDATA/events.log"
    fi
}
usage_pct() {
    u=$(df -P "$NVR_MOUNT" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
    isnum "$u" || return 1
    printf '%s\n' "$u"
}
free_kb() {
    u=$(df -P -k "$NVR_MOUNT" 2>/dev/null | awk 'NR==2 {print $4}')
    isnum "$u" || return 1
    printf '%s\n' "$u"
}
# Strip rtsp://user:pass@ credentials from a stream. The replacement is emitted
# into `out` and never rescanned, so this cannot loop.
redact() {
    awk '{
        out = ""
        while (match($0, /rtsp:\/\/[^ @]*@/)) {
            out = out substr($0, 1, RSTART - 1) "rtsp://[REDACTED]@"
            $0 = substr($0, RSTART + RLENGTH)
        }
        print out $0
    }'
}
# Verify both ffmpeg executable identity and which RTSP channel it owns.
# The channel match is end-anchored so 101 never matches a 1011 URL.
owned() {
    id=$1; p=$2
    isnum "$p" && [ "$p" -gt 1 ] && [ -r "/proc/$p/cmdline" ] || return 1
    bin=$(readlink "/proc/$p/exe" 2>/dev/null) || return 1
    case "$bin" in */ffmpeg|*/ffmpeg\ \(deleted\)) ;; *) return 1;; esac
    tr '\000' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -Eq "/Streaming/Channels/$id\$"
}
# A stray v1/v2 process must not be duplicated accidentally.
find_camera_pid() {
    id=$1
    for p in $(pidof ffmpeg 2>/dev/null); do
        if owned "$id" "$p"; then printf '%s\n' "$p"; fi
    done
}
newest() { ls -t "$NVR_BASE_DIR/cam$1"/cam"$1"_*.mkv 2>/dev/null | head -n 1; }
# A file whose mtime lies slightly in the future (clock stepped back) is still
# fresh evidence of writing; only a genuinely frozen stream ages past STALE.
healthy_file() {
    f=$(newest "$1")
    [ -f "$f" ] || return 1
    mt=$(stat -c %Y "$f" 2>/dev/null) || return 1
    sz=$(stat -c %s "$f" 2>/dev/null) || return 1
    isnum "$mt" && isnum "$sz" && [ "$sz" -gt 0 ] || return 1
    age=$(( $(date +%s) - mt ))
    [ "$age" -le "$STALE" ] && [ "$age" -ge -"$STALE" ]
}
file_age() {
    f=$(newest "$1")
    if [ -f "$f" ]; then
        mt=$(stat -c %Y "$f" 2>/dev/null) || { echo unknown; return; }
        if isnum "$mt" && [ "$mt" -gt 0 ]; then
            echo $(( $(date +%s) - mt ))
        else
            echo unknown
        fi
    else
        echo none
    fi
}
# Keep log files bounded; carried-over tail is redacted from rtsp credentials.
rotate_log() {
    f=$1
    [ -f "$f" ] || return 0
    sz=$(stat -c %s "$f" 2>/dev/null) || return 0
    isnum "$sz" || return 0
    if [ "$sz" -gt 524288 ]; then
        tail -c 262144 "$f" | redact > "$f.tmp" && cat "$f.tmp" > "$f"
        rm -f "$f.tmp"
    fi
}
# Small bounded exponential backoff on broken cameras.
allow_retry() {
    id=$1
    last=$(numfile "$STATE/cam$id.last_try")
    failures=$(numfile "$STATE/cam$id.failures")
    if [ "$last" -gt 0 ] && [ $((NOW-last)) -ge 3600 ]; then failures=0; fi
    case $failures in 0) delay=0;; 1) delay=300;; 2) delay=600;; 3) delay=1200;; *) delay=1800;; esac
    [ $((NOW-last)) -ge "$delay" ] || return 1
    printf '%s\n' "$NOW" > "$STATE/cam$id.last_try"
    printf '%s\n' $((failures+1)) > "$STATE/cam$id.failures"
}
# Percent-encode for RTSP userinfo: keep RFC-unreserved bytes plus sub-delims.
# `%` stays literal because cameras compare the typed password and ffmpeg does
# not decode userinfo (a literal % must survive as typed).
url_user_enc() {
    TEXT="$1" awk 'BEGIN {
        s = ENVIRON["TEXT"]; out = ""
        chars = ""
        for (i = 1; i <= 255; i++) chars = chars sprintf("%c", i)
        for (j = 1; j <= length(s); j++) {
            c = substr(s, j, 1)
            if (c ~ /[A-Za-z0-9._%~!$&()*+,;=-]/) { out = out c; continue }
            d = index(chars, c)
            out = out sprintf("%%%02X", d)
        }
        print out
    }'
}
# Strict form-encoding (application/x-www-form-urlencoded) for HTTP payloads.
form_enc() {
    TEXT="$1" awk 'BEGIN {
        s = ENVIRON["TEXT"]; out = ""
        chars = ""
        for (i = 1; i <= 255; i++) chars = chars sprintf("%c", i)
        for (j = 1; j <= length(s); j++) {
            c = substr(s, j, 1)
            if (c ~ /[A-Za-z0-9._~-]/) { out = out c; continue }
            d = index(chars, c)
            out = out sprintf("%%%02X", d)
        }
        print out
    }'
}
# Incident deduplication state. One line per key: "<key> <open|closed> <epoch>".
# Written to volatile and persistent locations; reads prefer volatile (newest),
# fall back to the USB copy after a reboot.
notify_state_read() {
    if [ -r "$STATE/notify.state" ]; then cat "$STATE/notify.state" 2>/dev/null
    elif [ -r "$PDATA/notify.state" ]; then cat "$PDATA/notify.state" 2>/dev/null
    fi
}
incident_get() {
    I_OPEN=''; I_LAST=0
    line=$(notify_state_read | awk -v k="$1" '$1==k {print $2" "$3; exit}')
    I_OPEN=${line%% *}
    I_LAST=${line#* }
    isnum "$I_LAST" || I_LAST=0
    [ "$I_OPEN" = open ] || [ "$I_OPEN" = closed ] || I_OPEN=''
}
incident_put() {
    tmp=$(notify_state_read | awk -v k="$1" -v f="$2" -v e="$3" '
        BEGIN { found = 0 }
        { if ($1 == k) { if (!found) { print k, f, e; found = 1 } } else print }
        END { if (!found) print k, f, e }')
    printf '%s\n' "$tmp" | write_atomic "$STATE/notify.state" || return 0
    if mounted_rw && [ -d "$NVR_BASE_DIR" ]; then
        mkdir -p "$PDATA" 2>/dev/null && printf '%s\n' "$tmp" | write_atomic "$PDATA/notify.state"
    fi
}
# Atomic same-directory replace; ext4 rename is the commit point.
write_atomic() {
    f=$1; t="$1.tmp.$$"
    cat > "$t" 2>/dev/null || { rm -f "$t"; return 1; }
    mv -f "$t" "$f" 2>/dev/null || { rm -f "$t"; return 1; }
}
# Send to every configured transport. Tokens/URLs travel to curl via stdin
# config (-K -) and are never placed in argv, logs or error output.
send_notify() {
    lvl=$1; key=$2; msg=$3
    TG_CODE=''; WH_CODE=''
    text="NVR $lvl [$key] $msg"
    ok=0
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        payload="chat_id=$TG_CHAT&text=$(form_enc "$text")"
        TG_CODE=$(printf 'silent\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' \
            "$TG_TOKEN" "$payload" \
            | "$CURLBIN" -K - -s -o /dev/null -w '%{http_code}' --max-time "$NOTIFY_TIMEOUT" 2>/dev/null)
        case $TG_CODE in 2*) ok=1; log "INFO notify telegram level=$lvl key=$key delivered";;
                          *) log "WARN notify telegram level=$lvl key=$key failed status=${TG_CODE:-error}";; esac
    fi
    if [ -n "$WEBHOOK" ]; then
        safe_msg=$(printf '%s' "$msg" | tr -d '"\\')
        safe_lvl=$(printf '%s' "$lvl" | tr -d '"\\')
        safe_key=$(printf '%s' "$key" | tr -d '"\\')
        WH_CODE=$(printf 'silent\nurl = "%s"\nheader = "Content-Type: application/json"\ndata = "{\\"level\\":\\"%s\\",\\"key\\":\\"%s\\",\\"text\\":\\"%s\\"}"\n' \
            "$WEBHOOK" "$safe_lvl" "$safe_key" "$safe_msg" \
            | "$CURLBIN" -K - -s -o /dev/null -w '%{http_code}' --max-time "$NOTIFY_TIMEOUT" 2>/dev/null)
        case $WH_CODE in 2*) ok=1; log "INFO notify webhook level=$lvl key=$key delivered";;
                          *) log "WARN notify webhook level=$lvl key=$key failed status=${WH_CODE:-error}";; esac
    fi
    [ "$ok" -eq 1 ] || return 1
}
# Record an incident transition. RECOVERY is only sent for a previously OPEN
# incident, so a notification failure upstream cannot fabricate recovery news.
# force=1 bypasses the repeat interval (escalations).
notify_event() {
    lvl=$1; key=$2; msg=$3; force=${4:-0}
    [ -n "$TG_TOKEN" ] || [ -n "$WEBHOOK" ] || return 0
    incident_get "$key"
    if [ "$lvl" = RECOVERY ]; then
        [ "$I_OPEN" = open ] || return 0
        if send_notify "$lvl" "$key" "$msg"; then
            incident_put "$key" closed "$NOW"
        else
            # Keep the incident open; retry after the repeat interval.
            incident_put "$key" open "$NOW"
        fi
        return 0
    fi
    if [ "$I_OPEN" = open ] && [ "$force" != 1 ]; then
        [ $((NOW - I_LAST)) -ge "$NOTIFY_REPEAT" ] || return 0
    fi
    if send_notify "$lvl" "$key" "$msg"; then
        incident_put "$key" open "$NOW"
    else
        # Record the attempt so a dead uplink is retried, not hammered.
        incident_put "$key" open "$NOW"
    fi
}
start_cam() {
    id=$1
    mkdir -p "$NVR_BASE_DIR/cam$id" "$PDATA" || return 1
    fl="$PDATA/ffmpeg-cam$id.log"
    rotate_log "$fl"
    if [ "$RTSP_ENCODE" = 1 ]; then
        user=$(url_user_enc "$RTSP_USER"); pass=$(url_user_enc "$RTSP_PASS")
    else
        user=$RTSP_USER; pass=$RTSP_PASS
    fi
    url="rtsp://$user:$pass@$RTSP_IP:554/Streaming/Channels/$id"
    "$FFMPEG" -hide_banner -nostdin -loglevel error \
        -timeout 15000000 -rtsp_transport tcp -i "$url" \
        -c copy -f segment -segment_time "$SEGMENT" -strftime 1 -reset_timestamps 1 \
        "$NVR_BASE_DIR/cam$id/cam${id}_%Y-%m-%d_%H-%M-%S.mkv" \
        </dev/null >> "$fl" 2>&1 &
    p=$!
    printf '%s\n' "$p" > "$STATE/cam$id.pid"
    printf '%s\n' "$NOW" > "$STATE/cam$id.started"
    log "INFO camera=$id launch pid=$p"
}
stop_cam() {
    id=$1
    p=$(numfile "$STATE/cam$id.pid")
    if owned "$id" "$p"; then
        kill -TERM "$p" 2>/dev/null || :
        n=0
        while owned "$id" "$p" && [ "$n" -lt 10 ]; do sleep 1; n=$((n+1)); done
        if owned "$id" "$p"; then
            log "WARN camera=$id SIGTERM timeout; SIGKILL pid=$p"
            kill -KILL "$p" 2>/dev/null || :
            sleep 1
        fi
    fi
    if owned "$id" "$p"; then
        log "ERROR camera=$id process will not terminate; refusing duplicate"
        return 1
    fi
    rm -f "$STATE/cam$id.pid" "$STATE/cam$id.started"
}
# Two recorders on one channel are forbidden. A duplicate is ours only when it
# writes into this installation's camera directory; foreign processes are only
# reported.
dedup_camera() {
    id=$1
    extra=''
    for p in $(find_camera_pid "$id"); do
        tracked=$(numfile "$STATE/cam$id.pid")
        [ "$p" = "$tracked" ] && continue
        if tr '\000' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -Fq "$NVR_BASE_DIR/cam$id/"; then
            extra="$extra $p"
        fi
    done
    [ -z "$extra" ] && return 0
    for p in $extra; do
        log "WARN camera=$id duplicate recorder pid=$p detected; terminating duplicate"
        kill -TERM "$p" 2>/dev/null || :
    done
    sleep 2
    for p in $extra; do
        if owned "$id" "$p"; then
            kill -KILL "$p" 2>/dev/null || :
            log "ERROR camera=$id duplicate pid=$p required SIGKILL"
        fi
    done
}
# Serializes cron checks, cleanups, starts and stops.
lock() {
    L="$STATE/.lock"
    if mkdir "$L" 2>/dev/null; then
        printf '%s\n' "$$" > "$L/pid"
        trap 'rm -f "$L/pid"; rmdir "$L" 2>/dev/null || :' EXIT
        trap 'exit 130' INT
        trap 'exit 143' HUP TERM
        return 0
    fi
    lp=$(numfile "$L/pid")
    # Never remove a lock belonging to a live PID. Stale lock reclamation only.
    if [ "$lp" -gt 1 ] && kill -0 "$lp" 2>/dev/null; then return 1; fi
    age=$(stat -c %Y "$L" 2>/dev/null) || return 1
    [ $((NOW-age)) -gt 90 ] || return 1
    rm -f "$L/pid"
    rmdir "$L" 2>/dev/null || return 1
    mkdir "$L" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$L/pid"
    trap 'rm -f "$L/pid"; rmdir "$L" 2>/dev/null || :' EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
}
is_paused() { [ -e "$PDATA/paused" ] || [ -e "$STATE/paused" ]; }
ensure_no_legacy() {
    if [ -e /tmp/cctv_is_running ]; then
        log 'ERROR legacy marker detected; v2 check refused'
        return 1
    fi
}
save_check_state() {
    first=${CHECK_FIRST_EPOCH:-0}
    isnum "$first" && [ "$first" -gt 0 ] || first=$NOW
    hu=$(date '+%Y-%m-%d %H:%M:%S')
    content="CHECK_FIRST_EPOCH=$first
CHECK_LAST_EPOCH=$NOW
CHECK_LAST_HUMAN=$hu"
    printf '%s\n' "$content" | write_atomic "$STATE/check.state"
    if mounted_rw && [ -d "$NVR_BASE_DIR" ]; then
        mkdir -p "$PDATA" 2>/dev/null && printf '%s\n' "$content" | write_atomic "$PDATA/check.state"
    fi
}
# State files live on the archive USB and must never be executed. Parse them
# with a strict per-key whitelist instead of sourcing: anything that is not a
# known key with a known value shape is ignored.
read_kv() {
    f=''
    if [ -r "$STATE/$1" ]; then f="$STATE/$1"; elif [ -r "$PDATA/$1" ]; then f="$PDATA/$1"; fi
    [ -n "$f" ] || return 0
    while IFS= read -r kvline || [ -n "$kvline" ]; do
        key=${kvline%%=*}
        [ "$key" != "$kvline" ] || continue
        val=${kvline#*=}
        case $key in
            CHECK_FIRST_EPOCH|CHECK_LAST_EPOCH|CLEANUP_LAST_EPOCH|CLEANUP_OK_EPOCH|CLEANUP_REMOVED|CLEANUP_SKIPPED)
                case $val in ''|*[!0-9]*) continue;; esac ;;
            CLEANUP_RESULT)
                case $val in OK|PARTIAL|FAILED|NEVER) ;; *) continue;; esac ;;
            CHECK_LAST_HUMAN|CLEANUP_LAST_HUMAN|CLEANUP_OK_HUMAN)
                # Timestamps are stored unquoted; only digits, space, ':', '-' pass.
                case $val in ''|*[!0-9:\ -]*) continue;; esac ;;
            *) continue;;
        esac
        eval "$key=\"\$val\""
    done < "$f"
    return 0
}
save_cleanup_state() {
    result=$1; removed=$2; skipped=$3
    read_kv cleanup.state
    ok_epoch=${CLEANUP_OK_EPOCH:-0}; ok_human=${CLEANUP_OK_HUMAN:-never}
    isnum "$ok_epoch" || ok_epoch=0
    now=$(date +%s); hu=$(date '+%Y-%m-%d %H:%M:%S')
    case $result in
        OK|PARTIAL) ok_epoch=$now; ok_human=$hu;;
    esac
    content="CLEANUP_LAST_EPOCH=$now
CLEANUP_LAST_HUMAN=$hu
CLEANUP_RESULT=$result
CLEANUP_REMOVED=$removed
CLEANUP_SKIPPED=$skipped
CLEANUP_OK_EPOCH=$ok_epoch
CLEANUP_OK_HUMAN=$ok_human"
    printf '%s\n' "$content" | write_atomic "$STATE/cleanup.state"
    if mounted_rw && [ -d "$NVR_BASE_DIR" ]; then
        mkdir -p "$PDATA" 2>/dev/null && printf '%s\n' "$content" | write_atomic "$PDATA/cleanup.state"
    fi
}
disk_health() {
    pct=$(usage_pct) || return 0
    if [ "$pct" -ge "$DISK_CRIT" ]; then
        notify_event CRITICAL disk-crit "disk usage ${pct}% (critical threshold ${DISK_CRIT}%)"
        notify_event RECOVERY disk-warn "disk usage back below warning threshold"
    elif [ "$pct" -ge "$DISK_WARN" ]; then
        notify_event WARN disk-warn "disk usage ${pct}% (warning threshold ${DISK_WARN}%)"
        notify_event RECOVERY disk-crit "disk usage back below critical threshold"
    else
        notify_event RECOVERY disk-warn "disk usage back below warning threshold"
        notify_event RECOVERY disk-crit "disk usage back below critical threshold"
    fi
}
# Hourly projection: bytes recorded in the last hour extrapolated to the
# retention horizon. Only real recording files are counted; without them the
# estimate is skipped instead of guessed.
forecast_space() {
    total=0
    for id in $CAMERAS; do
        for f in "$NVR_BASE_DIR/cam$id"/cam"$id"_*.mkv; do
            [ -f "$f" ] || continue
            mt=$(stat -c %Y "$f" 2>/dev/null) || continue
            isnum "$mt" || continue
            age=$((NOW - mt))
            [ "$age" -ge 0 ] && [ "$age" -le 3600 ] || continue
            sz=$(stat -c %s "$f" 2>/dev/null) || continue
            isnum "$sz" || continue
            total=$((total + sz))
        done
    done
    [ "$total" -gt 0 ] || return 0
    need_kb=$(( total / 1024 * RETENTION / 3600 + 1 ))
    free=$(free_kb) || return 0
    if [ "$free" -lt "$need_kb" ]; then
        notify_event WARN space72 "free ${free} KB is below projected ${need_kb} KB for ${RETENTION}h retention at current bitrate"
    else
        notify_event RECOVERY space72 "free space covers the projected ${RETENTION}h retention again"
    fi
}
cleanup_stale_check() {
    read_kv cleanup.state
    base=${CLEANUP_LAST_EPOCH:-0}
    isnum "$base" || base=0
    if [ "$base" -eq 0 ]; then
        read_kv check.state
        base=${CHECK_FIRST_EPOCH:-0}
        isnum "$base" || base=0
    fi
    [ "$base" -gt 0 ] || return 0
    if [ $((NOW - base)) -gt "$CLEANUP_STALE" ]; then
        notify_event WARN cleanup-stale "no cleanup for $(( (NOW - base) / 60 )) minutes (limit ${CLEANUP_STALE}s)"
    else
        notify_event RECOVERY cleanup-stale "hourly cleanup is running again"
    fi
}
check() {
    disk_ok || return 1
    disk_health
    ensure_no_legacy || return 1
    read_kv check.state
    save_check_state
    rotate_log "$STATE/events.log"
    if mounted_rw && [ -d "$NVR_BASE_DIR" ]; then rotate_log "$PDATA/events.log"; fi
    cleanup_stale_check
    for id in $CAMERAS; do
        pid=$(numfile "$STATE/cam$id.pid")
        if ! owned "$id" "$pid"; then
            other=$(find_camera_pid "$id") || other=''
            if [ -n "$other" ]; then
                log "WARN camera=$id untracked ffmpeg pid=$other; adopting process"
                printf '%s\n' "$other" > "$STATE/cam$id.pid"
                printf '%s\n' "$NOW" > "$STATE/cam$id.started"
                dedup_camera "$id"
                continue
            fi
            notify_event ERROR "cam$id" "camera $id is not recording: ffmpeg process missing"
            if allow_retry "$id"; then
                log "WARN camera=$id ffmpeg missing; start attempt"
                start_cam "$id"
                if [ "$(numfile "$STATE/cam$id.failures")" -eq 3 ]; then
                    notify_event ERROR "cam$id" "watchdog could not recover camera $id after repeated attempts" 1
                fi
            fi
        elif healthy_file "$id"; then
            printf '0\n' > "$STATE/cam$id.failures"
            notify_event RECOVERY "cam$id" "camera $id writes again, freshness confirmed"
        else
            started=$(numfile "$STATE/cam$id.started")
            if [ "$started" -gt 0 ] && [ $((NOW-started)) -lt "$GRACE" ]; then continue; fi
            notify_event ERROR "cam$id" "camera $id is not recording: stream stalled, no fresh data"
            if allow_retry "$id"; then
                log "WARN camera=$id stream stale; restarting camera only"
                if stop_cam "$id"; then
                    start_cam "$id"
                    if [ "$(numfile "$STATE/cam$id.failures")" -eq 3 ]; then
                        notify_event ERROR "cam$id" "watchdog could not recover camera $id after repeated attempts" 1
                    fi
                fi
            fi
        fi
    done
}
status() {
    read_kv check.state
    read_kv cleanup.state
    last_check_age='unknown'
    if isnum "${CHECK_LAST_EPOCH:-}" && [ "${CHECK_LAST_EPOCH:-0}" -gt 0 ]; then
        last_check_age=$(( NOW - CHECK_LAST_EPOCH ))
    fi
    if is_paused; then overall=PAUSED
    elif ! mounted_rw || [ ! -d "$NVR_BASE_DIR" ]; then overall='NO-DISK'
    else overall=HEALTHY
    fi
    echo "NVR v2.4 - $overall"
    if mounted_rw; then
        u=$(usage_pct) || u=unknown
        free=$(free_kb) || free=unknown
        if [ "$free" != unknown ]; then
            free_gb=$(awk -v k="$free" 'BEGIN { printf "%.1f", k / 1048576 }')
        else free_gb=unknown; fi
        echo "DISK: RW, ${u}% used, ${free_gb} GB free"
    else
        echo 'DISK: NOT MOUNTED/READ-ONLY'
    fi
    echo "RETENTION: $(( RETENTION / 3600 )) hours"
    echo "SEGMENT: $SEGMENT seconds"
    case $last_check_age in
        unknown) echo "LAST CHECK: ${CHECK_LAST_HUMAN:-never}";;
        *) echo "LAST CHECK: ${CHECK_LAST_HUMAN:-never} (${last_check_age}s ago)";;
    esac
    echo "LAST CLEANUP: ${CLEANUP_LAST_HUMAN:-never} ${CLEANUP_RESULT:-NEVER}"
    echo "LAST SUCCESSFUL CLEANUP: ${CLEANUP_OK_HUMAN:-never}"
    echo "REMOVED FILES: ${CLEANUP_REMOVED:-0} (skipped ${CLEANUP_SKIPPED:-0})"
    for id in $CAMERAS; do
        pid=$(numfile "$STATE/cam$id.pid")
        age=$(file_age "$id")
        if ! mounted_rw || [ ! -d "$NVR_BASE_DIR" ]; then
            state=UNKNOWN
        elif owned "$id" "$pid"; then
            case $age in
                none) state=STARTING;;
                unknown) state=UNKNOWN;;
                *[!0-9-]*) state=UNKNOWN;;
                -*) state=HEALTHY;;   # future mtime within tolerance: clock stepped back
                *) if [ "$age" -le "$STALE" ]; then state=HEALTHY
                   else state=STALE; fi;;
            esac
        else
            case $age in
                none|unknown) state=DOWN;;
                *) if isnum "$age" && [ "$age" -le "$STALE" ]; then
                       state=STOPPED   # recent footage, process gone (paused/just stopped)
                   else state=DOWN; fi;;
            esac
        fi
        if is_paused; then [ "$state" = DOWN ] && state=STOPPED; fi
        case $age in
            none) disp='no file yet';;
            unknown) disp=unknown;;
            *) disp="${age}s ago";;
        esac
        echo "CAM $id: $state, last write $disp"
    done
    if [ -n "$TG_TOKEN" ] || [ -n "$WEBHOOK" ]; then
        echo 'ALERTS: enabled'
    else
        echo 'ALERTS: disabled'
    fi
}
logs_cmd() {
    arg=${1:-50}
    if printf '%s' "$arg" | grep -Eq '^cam[0-9]+$'; then
        cid=${arg#cam}
        fl="$PDATA/ffmpeg-cam$cid.log"
        if [ -r "$fl" ]; then
            tail -n 50 "$fl" | redact
        else
            echo "no ffmpeg log for camera $cid"
        fi
        return 0
    fi
    isnum "$arg" || { echo 'Usage: nvr.sh logs [lines|cam<ID>]' >&2; return 2; }
    ev=''
    [ -r "$STATE/events.log" ] && ev="$STATE/events.log"
    [ -z "$ev" ] && [ -r "$PDATA/events.log" ] && ev="$PDATA/events.log"
    if [ -n "$ev" ]; then
        tail -n "$arg" "$ev" | redact
    else
        echo 'no events log yet'
    fi
}
notify_test() {
    if [ -z "$TG_TOKEN" ] && [ -z "$WEBHOOK" ]; then
        echo 'Notifications are not configured.'
        echo 'Add NVR_NOTIFY_TELEGRAM_TOKEN / NVR_NOTIFY_TELEGRAM_CHAT and/or'
        echo 'NVR_NOTIFY_WEBHOOK_URL to /opt/etc/nvr-v2.conf (mode 600), then re-run this test.'
        return 2
    fi
    msg='test notification from NVR v2.4'
    if send_notify TEST notify-test "$msg"; then
        echo "Test notification delivered. telegram=${TG_CODE:-skipped} webhook=${WH_CODE:-skipped}"
        return 0
    fi
    echo "Test notification FAILED. telegram=${TG_CODE:-skipped} webhook=${WH_CODE:-skipped}"
    return 1
}
do_stop() {
    for id in $CAMERAS; do stop_cam "$id" || :; done
    # Durable stop: explicit operator intent must survive cron ticks and reboots.
    printf 'paused\n' | write_atomic "$STATE/paused"
    if mounted_rw && [ -d "$NVR_BASE_DIR" ]; then
        mkdir -p "$PDATA" 2>/dev/null && printf 'paused\n' | write_atomic "$PDATA/paused"
    fi
    # Operator-initiated stop resolves open camera incidents without recovery noise.
    for id in $CAMERAS; do incident_put "cam$id" closed 0; done
    log 'INFO paused by operator (durable stop; cron will not restart until start/resume)'
}
do_start() {
    rm -f "$STATE/paused" "$PDATA/paused" 2>/dev/null || :
    # An explicit resume overrides per-camera retry backoff: the operator asked
    # for a fresh start now, not for the old schedule.
    for id in $CAMERAS; do
        rm -f "$STATE/cam$id.last_try" "$STATE/cam$id.failures"
    done
    log 'INFO started/resumed by operator'
    check
}
cleanup() {
    disk_ok || { save_cleanup_state FAILED 0 0; return 1; }
    disk_health
    # Strict retention policy: a per-camera, rolling 72-hour *time* horizon.
    # Fullness must NEVER shorten it; do not remove unexpired footage.
    # mtime marks the last bytes actually written, not the filename start time.
    # Cleanup runs hourly, so expiration may occur up to an hour later.
    cutoff=$((NOW-RETENTION))
    removed=0; failed=0; skipped=0
    for id in $CAMERAS; do
        # Don't unlink a segment potentially still held open by an FFmpeg process.
        pid=$(numfile "$STATE/cam$id.pid")
        open_file=''
        if owned "$id" "$pid"; then
            open_file=$(newest "$id")
        else
            # Also protect against an untracked but active recorder process.
            other=$(find_camera_pid "$id") || other=''
            [ -z "$other" ] || open_file=$(newest "$id")
        fi
        for f in "$NVR_BASE_DIR/cam$id"/cam"$id"_*.mkv; do
            [ -f "$f" ] || continue
            [ "$f" = "$open_file" ] && continue
            mt=$(stat -c %Y "$f" 2>/dev/null) || { skipped=$((skipped+1)); continue; }
            isnum "$mt" || { skipped=$((skipped+1)); continue; }
            if [ "$mt" -lt "$cutoff" ]; then
                if rm -f -- "$f" 2>/dev/null && [ ! -e "$f" ]; then
                    removed=$((removed+1))
                else
                    failed=$((failed+1))
                fi
            fi
        done
    done
    if [ "$failed" -gt 0 ]; then result=FAILED
    elif [ "$skipped" -gt 0 ]; then result=PARTIAL
    else result=OK
    fi
    save_cleanup_state "$result" "$removed" "$skipped"
    if [ "$removed" -gt 0 ] || [ "$result" != OK ]; then
        log "INFO retention cleanup removed=$removed skipped=$skipped failed=$failed result=$result"
    fi
    # Disk alerts only; NEVER evict video because of free-space pressure.
    forecast_space
}

mkdir -p "$STATE" || exit 2
# NVR_LIB_ONLY=1 loads functions for offline tests without executing anything.
if [ "${NVR_LIB_ONLY:-0}" != 1 ]; then
case ${1:-status} in
  status) status ;;
  check) lock || exit 0; is_paused && exit 0; check ;;
  start|resume) lock || { echo 'NVR: controller busy' >&2; exit 1; }; do_start ;;
  stop|pause) lock || { echo 'NVR: controller busy' >&2; exit 1; }; do_stop ;;
  cleanup) lock || exit 0; cleanup ;;
  logs) shift; logs_cmd "${1:-50}" ;;
  notify)
      [ "${2:-}" = test ] || { echo 'Usage: nvr.sh notify test' >&2; exit 2; }
      notify_test ;;
  *) echo 'Usage: nvr.sh {start|resume|check|status|stop|pause|cleanup|logs [lines|cam<ID>]|notify test}' >&2; exit 2;;
esac
fi
