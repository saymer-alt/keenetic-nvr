#!/bin/sh
# Read-only Telegram command bridge for Keenetic NVR v2.4.
# Poll once per minute via Entware cron; never changes camera state.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
CONF=${NVR_CONFIG:-/opt/etc/nvr-v2.conf}
NVR=${NVR_BIN:-/opt/etc/nvr-v2.sh}
STATE=${NVR_BOT_STATE_DIR:-/opt/var/lib/nvr-telegram}
CURL=${NVR_BOT_CURL:-curl}

fail() { printf 'NVR Telegram: %s\n' "$*" >&2; exit 1; }
[ -r "$CONF" ] || fail 'NVR config is missing'
[ -f "$NVR" ] || fail 'NVR recorder not installed'
command -v jq >/dev/null 2>&1 || fail 'jq is required: opkg update && opkg install jq'
command -v "$CURL" >/dev/null 2>&1 || fail 'curl is missing'
. "$CONF"
TOKEN=${NVR_NOTIFY_TELEGRAM_TOKEN:-}
CHAT=${NVR_NOTIFY_TELEGRAM_CHAT:-}
[ -n "$TOKEN" ] && [ -n "$CHAT" ] || fail 'Configure Telegram notifications first'
case $CHAT in ''|*[!0-9]*) fail 'Read-only bot supports a private numeric chat ID only' ;; esac
case $TOKEN in *:*) : ;; *) fail 'Malformed Telegram token' ;; esac
mkdir -p "$STATE"
chmod 700 "$STATE"

fetch() {
    # Bot token enters curl via its stdin config, never /proc/cmdline.
    endpoint=$1
    printf 'silent\nurl = "https://api.telegram.org/bot%s/%s"\n' "$TOKEN" "$endpoint" |
        "$CURL" -K - -fsS --connect-timeout 8 --max-time 22
}
valid_response() {
    printf '%s\n' "$1" | jq -e '.ok == true and (.result | type == "array")' >/dev/null 2>&1
}
atomic_offset() {
    next=$1
    printf '%s\n' "$next" > "$STATE/offset.tmp.$$"
    mv -f "$STATE/offset.tmp.$$" "$STATE/offset"
}
offset() {
    x=$(cat "$STATE/offset" 2>/dev/null || :)
    case $x in ''|*[!0-9]*) echo 0 ;; *) echo "$x" ;; esac
}
lock() {
    if mkdir "$STATE/.lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$STATE/.lock/pid"
    else
        old=$(cat "$STATE/.lock/pid" 2>/dev/null || :)
        case $old in ''|*[!0-9]*) old=0 ;; esac
        if [ "$old" -gt 1 ] && kill -0 "$old" 2>/dev/null; then
            exit 0
        fi
        rm -f "$STATE/.lock/pid"
        rmdir "$STATE/.lock" 2>/dev/null || exit 0
        mkdir "$STATE/.lock" 2>/dev/null || exit 0
        printf '%s\n' "$$" > "$STATE/.lock/pid"
    fi
    trap 'rm -f "$STATE/.lock/pid"; rmdir "$STATE/.lock" 2>/dev/null || :' EXIT
}
send_reply() {
    msg=$1
    payload=$(mktemp "$STATE/message.XXXXXX") || return 1
    # jq escapes quotes, Unicode, line breaks and control chars for the JSON body.
    printf '%s' "$msg" | jq -Rs --arg chat "$CHAT" '{chat_id: $chat, text: .}' > "$payload" ||
        { rm -f "$payload"; return 1; }
    response=$(printf 'silent\nurl = "https://api.telegram.org/bot%s/sendMessage"\nheader = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$TOKEN" "$payload" |
        "$CURL" -K - -fsS --connect-timeout 8 --max-time 22) ||
        { rm -f "$payload"; return 1; }
    rm -f "$payload"
    printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null 2>&1
}
nvr_report() {
    sh "$NVR" status 2>/dev/null || printf 'NVR ERROR: cannot read recorder status\n'
}
render_reply() {
    cmd=$1
    case $cmd in
        /start|/start@*|/help|/help@*)
            printf 'Keenetic NVR v2.4\n/status - disk, cameras, cron and archive\n/cameras - recording status per camera\n/disk - free space and cleanup\n/help - command list\n\nRead-only bot: camera control is not available.\n' ;;
        /status|/status@*)
            printf 'NVR status (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
            nvr_report ;;
        /cameras|/cameras@*)
            report=$(nvr_report)
            printf '%s\n' "$report" | sed -n '1p;/^CAM [0-9][0-9]*:/p'
            ;;
        /disk|/disk@*)
            report=$(nvr_report)
            printf '%s\n' "$report" | sed -n '1p;/^DISK:/p;/^RETENTION:/p;/^LAST CLEANUP:/p;/^LAST SUCCESSFUL CLEANUP:/p;/^REMOVED FILES:/p'
            ;;
        /*) printf 'Unknown read-only command. Send /help.\n' ;;
        *) return 2 ;;
    esac
}
handle_update() {
    event=$1
    # Only the exact configured PRIVATE Telegram chat and its real sender.
    authorized=$(printf '%s\n' "$event" |
        jq -r --arg chat "$CHAT" 'if .message.chat.type == "private"
            and (.message.chat.id | tostring) == $chat
            and (.message.from.id | tostring) == $chat
            then "yes" else "no" end' 2>/dev/null) || return 1
    [ "$authorized" = yes ] || return 0
    cmd=$(printf '%s\n' "$event" | jq -r '.message.text // ""' 2>/dev/null) || return 1
    # No shell execution or remote modification; only four read-only commands.
    case $cmd in
        /*) : ;;
        *) return 0 ;;
    esac
    reply=$(render_reply "$cmd") || return 0
    send_reply "$reply" || return 1
}
init() {
    lock
    # Negative offset returns only the most recent pending update and drops old
    # backlog; never replays historical /start on the first cron run.
    result=$(fetch 'getUpdates?offset=-1&limit=1&timeout=0') ||
        fail 'getUpdates failed (network/token/webhook); no setup change'
    valid_response "$result" || fail 'getUpdates rejected (possibly a webhook is active)'
    latest=$(printf '%s\n' "$result" | jq -r '[.result[].update_id] | max // -1')
    if [ "$latest" -ge 0 ]; then atomic_offset "$((latest+1))"
    else atomic_offset 0; fi
    printf 'NVR Telegram commands initialised, offset=%s.\n' "$(offset)"
}
poll() {
    lock
    start=$(offset)
    result=$(fetch "getUpdates?offset=$start&limit=30&timeout=0") ||
        fail 'getUpdates failed; will retry next minute'
    valid_response "$result" || fail 'getUpdates rejected; check webhook, token or network'
    # Process each update independently, checkpointing only after success.
    # In particular, unauthorised chats never trigger a response.
    printf '%s\n' "$result" | jq -c '.result[]' |
    while IFS= read -r event; do
        uid=$(printf '%s\n' "$event" | jq -r '.update_id | numbers')
        case $uid in ''|*[!0-9]*) continue ;; esac
        [ "$uid" -ge "$(offset)" ] || continue
        handle_update "$event" || exit 1
        atomic_offset "$((uid+1))"
    done
    # A fresh timestamp is useful for checking cron without exposing secrets.
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/last_poll"
}
case ${1:-} in
    init) init ;;
    poll) poll ;;
    status)
        printf 'Telegram poller: %s\n' "$(test -f "$STATE/last_poll" && cat "$STATE/last_poll" || echo never)"
        printf 'Next update offset: %s\n' "$(offset)"
        ;;
    *) printf 'Usage: telegram-bot.sh {init|poll|status}\n' >&2; exit 2 ;;
esac
