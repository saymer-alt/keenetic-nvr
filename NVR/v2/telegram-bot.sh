#!/bin/sh
# Read-only Telegram command bridge for Keenetic NVR v2.4/v2.5.
# Poll once per minute via Entware cron; never changes camera state.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
CONF=${NVR_CONFIG:-/opt/etc/nvr-v2.conf}
NVR=${NVR_BIN:-/opt/etc/nvr-v2.sh}
STATE_OVERRIDE=${NVR_BOT_STATE_DIR:-}
GUARD=${NVR_STORAGE_GUARD:-/opt/etc/nvr-storage-guard.sh}
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
[ -r "$GUARD" ] || fail 'Storage guard missing: install the updated Telegram bot'
. "$GUARD"
profile=$(nvr_opt_profile) || fail 'Unknown /opt filesystem; Telegram poll disabled'
# Before ANY mkdir or Bot API polling, verify a real, dedicated EXT4 RW
# archive. A missing USB must never redirect writes into internal NAND.
nvr_archive_safe "$NVR_MOUNT" "$NVR_BASE_DIR" ||
    fail 'Archive is unmounted, not EXT4 RW or is the /opt partition'
if [ -n "$STATE_OVERRIDE" ]; then
    STATE=$STATE_OVERRIDE
elif [ "$profile" = internal-ubifs ]; then
    STATE="$NVR_BASE_DIR/.nvr-v2/telegram"
else
    STATE=/opt/var/lib/nvr-telegram
fi
case "$STATE" in /*) ;; *) fail 'Telegram state path must be absolute' ;; esac
# A stale telegram-state symlink can silently redirect hourly/minute writes
# back to internal UBIFS even if the archive itself remains mounted.
[ ! -L "$STATE" ] || fail 'Symlinked Telegram state is unsafe'
if [ "$profile" = internal-ubifs ]; then
    # First create only the verified archive's own metadata directory.
    mkdir -p "$NVR_BASE_DIR/.nvr-v2" || fail 'Archive metadata is inaccessible'
    nvr_archive_safe "$NVR_MOUNT" "$NVR_BASE_DIR" ||
        fail 'Archive disappeared while preparing Telegram state'
    state_parent=$(readlink -f "$(dirname "$STATE")" 2>/dev/null) ||
        fail 'Cannot resolve Telegram state parent'
    # For real devices, explicit overrides MUST remain on the EXT4 archive.
    # Offline fixture mountfiles intentionally permit an alternate test dir.
    if [ -z "${NVR_MOUNTS_FILE:-}" ]; then
        real_meta=$(readlink -f "$NVR_BASE_DIR/.nvr-v2") ||
            fail 'Cannot resolve EXT4 metadata'
        case "$state_parent" in
            "$real_meta"|"$real_meta"/*) ;;
            *) fail 'Telegram state override on NAND/other disk is forbidden' ;;
        esac
    fi
fi
mkdir -p "$STATE" || fail 'Could not create Telegram state'
# Detect mount changes and submounts before creating state files.
if [ "$profile" = internal-ubifs ] && [ -z "${NVR_MOUNTS_FILE:-}" ]; then
    archive_entry=$(nvr_mount_entry "$NVR_MOUNT") || fail 'Archive mount missing'
    state_entry=$(nvr_mount_entry "$STATE") || fail 'Telegram state mount missing'
    [ "$archive_entry" = "$state_entry" ] ||
        fail 'Telegram state must use the archive EXT4 filesystem'
fi
chmod 700 "$STATE" || fail 'Could not protect Telegram state'

fetch() {
    # Bot token enters curl via its stdin config, never /proc/cmdline.
    endpoint=$1
    printf 'silent\nurl = "https://api.telegram.org/bot%s/%s"\n' "$TOKEN" "$endpoint" |
        "$CURL" -K - -fsS --connect-timeout 8 --max-time 22
}
valid_response() {
    printf '%s\n' "$1" | jq -e '.ok == true and (.result | type == "array")' >/dev/null 2>&1
}
archive_available() {
    nvr_archive_safe "$NVR_MOUNT" "$NVR_BASE_DIR" ||
        fail 'Archive was disconnected; refusing Telegram command acknowledgement'
}
atomic_offset() {
    archive_available
    next=$1
    printf '%s\n' "$next" > "$STATE/offset.tmp.$$"
    archive_available
    mv -f "$STATE/offset.tmp.$$" "$STATE/offset"
}
offset() {
    x=$(cat "$STATE/offset" 2>/dev/null || :)
    case $x in ''|*[!0-9]*) return 1 ;; *) echo "$x" ;; esac
}
lock() {
    archive_available
    if mkdir "$STATE/.lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$STATE/.lock/pid"
    else
        old=$(cat "$STATE/.lock/pid" 2>/dev/null || :)
        case $old in ''|*[!0-9]*) old=0 ;; esac
        if [ "$old" -gt 1 ] && kill -0 "$old" 2>/dev/null; then exit 0; fi
        # Do not steal a newly created lock before its owner writes the PID.
        stamp=$(stat -c %Y "$STATE/.lock" 2>/dev/null || :)
        case $stamp in ''|*[!0-9]*) exit 0 ;; esac
        [ $(( $(date +%s) - stamp )) -gt 120 ] || exit 0
        rm -f "$STATE/.lock/pid"
        rmdir "$STATE/.lock" 2>/dev/null || exit 0
        mkdir "$STATE/.lock" 2>/dev/null || exit 0
        printf '%s\n' "$$" > "$STATE/.lock/pid"
    fi
    trap 'rm -f "$STATE/.lock/pid"; rmdir "$STATE/.lock" 2>/dev/null || :' EXIT
}
send_reply() {
    archive_available
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
            printf 'Keenetic NVR v2.5\n/status - disk, cameras, cron and archive\n/cameras - recording status per camera\n/disk - free space and cleanup\n/help - command list\n\nRead-only bot: camera control is not available.\n' ;;
        /status|/status@*)
            printf 'NVR status (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
            nvr_report ;;
        /cameras|/cameras@*)
            report=$(nvr_report)
            printf '%s\n' "$report" | sed -n '1p;/^CAM [0-9][0-9]*:/p'
            ;;
        /disk|/disk@*)
            report=$(nvr_report)
            printf '%s\n' "$report" | sed -n '1p;/^DISK:/p;/^STORAGE MODE:/p;/^RETENTION:/p;/^FREE RESERVE:/p;/^LAST CLEANUP:/p;/^LAST SUCCESSFUL CLEANUP:/p;/^REMOVED FILES:/p'
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
    if [ "$latest" -ge 0 ]; then next=$((latest+1)); else next=0; fi
    # Preserve any already acknowledged update ID during migrations/restarts.
    current=$(offset 2>/dev/null || :)
    case $current in ''|*[!0-9]*) : ;; *) [ "$current" -le "$next" ] || next=$current ;; esac
    if [ "$profile" = internal-ubifs ] && [ -z "$STATE_OVERRIDE" ]; then
        # Read-only legacy import: the old minute poller used internal NAND.
        old=$(cat /opt/var/lib/nvr-telegram/offset 2>/dev/null || :)
        case $old in ''|*[!0-9]*) : ;; *) [ "$old" -le "$next" ] || next=$old ;; esac
    fi
    atomic_offset "$next"
    printf 'NVR Telegram commands initialised, offset=%s.\n' "$(offset)"
}
poll() {
    lock
    start=$(offset) || fail 'Missing or invalid offset; run telegram-bot.sh init first'
    result=$(fetch "getUpdates?offset=$start&limit=30&timeout=0") ||
        fail 'getUpdates failed; will retry next minute'
    valid_response "$result" || fail 'getUpdates rejected; check webhook, token or network'
    # Process each update independently, checkpointing only after success.
    # In particular, unauthorised chats never trigger a response.
    printf '%s\n' "$result" | jq -c '.result[]' |
    while IFS= read -r event; do
        uid=$(printf '%s\n' "$event" | jq -r '.update_id | numbers')
        case $uid in ''|*[!0-9]*) continue ;; esac
        current=$(offset) || exit 1
        [ "$uid" -ge "$current" ] || continue
        handle_update "$event" || exit 1
        atomic_offset "$((uid+1))"
    done
    # A fresh timestamp is useful for checking cron without exposing secrets.
    archive_available
    date '+%Y-%m-%d %H:%M:%S' > "$STATE/last_poll"
}
case ${1:-} in
    init) init ;;
    poll) poll ;;
    status)
        printf 'Telegram poller: %s\n' "$(test -f "$STATE/last_poll" && cat "$STATE/last_poll" || echo never)"
        printf 'Storage profile: %s\n' "$profile"
        printf 'Next update offset: %s\n' "$(offset 2>/dev/null || echo uninitialised)"
        ;;
    *) printf 'Usage: telegram-bot.sh {init|poll|status}\n' >&2; exit 2 ;;
esac
