#!/bin/sh
# Remove NVR v2 programs only; keep configuration, archive and shared packages.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
# Offline test seams. Ordinary router use leaves these unset.
OPT=${NVR_UNINSTALL_OPT:-/opt}
CRONTAB=${NVR_UNINSTALL_CRONTAB:-crontab}
RECORDER="$OPT/etc/nvr-v2.sh"
BOT="$OPT/etc/nvr-telegram-bot.sh"
GUARD="$OPT/etc/nvr-storage-guard.sh"
CONF="$OPT/etc/nvr-v2.conf"
TMP=''
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
partial() { printf 'KNVR removal PARTIAL: %s. Correct the problem and retry.\n' "$*" >&2; exit 1; }
case ${1:-} in
    --yes) ;;
    -h|--help) echo 'Usage: sh uninstall.sh [--yes]'; echo 'Stops NVR v2 and removes its programs/cron. Keeps config, video, Entware and packages.'; exit 0 ;;
    '')
        printf 'Remove KNVR programs? Video archive and configuration will be kept.\nType REMOVE: '
        IFS= read -r answer || answer=''
        [ "$answer" = REMOVE ] || { echo 'Cancelled; nothing changed.'; exit 0; } ;;
    *) echo 'Usage: sh uninstall.sh [--yes]' >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || partial 'run as root'
for file in "$RECORDER" "$BOT" "$GUARD" "$CONF"; do
    [ ! -L "$file" ] || partial 'symlinked KNVR file; inspect it manually'
done
TMP=$(mktemp -d /tmp/knvr-remove.XXXXXX) || partial 'cannot stage cron'
if "$CRONTAB" -l > "$TMP/old" 2> "$TMP/error"; then :
elif grep -qi 'no crontab' "$TMP/error"; then :
else partial 'cannot read root crontab'; fi
# Exact installed command shape, with optional system-crontab root field.
# Comments, shell wrappers and unrelated jobs are deliberately preserved.
filter_cron() {
    awk -v rec="$RECORDER" -v bot="$BOT" '
        /^[[:space:]]*#/ {print; next}
        {
            i=6; if ($i=="root") i++
            if ($i=="/bin/sh") {
                if ($(i+1)==rec && ($(i+2)=="check" || $(i+2)=="cleanup") && NF==i+2) next
                if ($(i+1)==bot && $(i+2)=="poll" && NF==i+2) next
            }
            print
        }' "$1" > "$2"
}
filter_cron "$TMP/old" "$TMP/new"
if ! cmp -s "$TMP/old" "$TMP/new"; then
    "$CRONTAB" "$TMP/new" || partial 'cannot disable KNVR cron'
fi
# Migrated installations may also have NVR jobs in the Entware system crontab.
if [ -e "$OPT/etc/crontab" ]; then
    [ -f "$OPT/etc/crontab" ] && [ ! -L "$OPT/etc/crontab" ] || partial 'unsafe system crontab'
    filter_cron "$OPT/etc/crontab" "$TMP/system"
    if ! cmp -s "$OPT/etc/crontab" "$TMP/system"; then
        cat "$TMP/system" > "$OPT/etc/crontab" || partial 'cannot disable system cron'
    fi
fi
# Wait briefly for already running cron controllers; do not signal arbitrary shells.
controllers_active() {
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        if tr '\000' '\n' < "$proc" 2>/dev/null | grep -Fxq -e "$RECORDER" -e "$BOT"; then
            return 0
        fi
    done
    return 1
}
n=0
while controllers_active; do
    [ "$n" -lt 10 ] || partial 'KNVR controller still busy (cron is disabled)'
    sleep 1; n=$((n+1))
done
if [ -e "$RECORDER" ]; then
    [ -f "$RECORDER" ] && [ -r "$CONF" ] || partial 'recorder or configuration unavailable'
    sh "$RECORDER" stop || partial 'recorder stop failed (cron is disabled)'
fi
# Native stop may report success despite an untracked or unkillable recorder.
# Refuse success if any FFmpeg still writes to this installation archive.
if [ -r "$CONF" ]; then
    NVR_BASE_DIR=''
    . "$CONF"
    [ -n "$NVR_BASE_DIR" ] || partial 'archive path missing in configuration'
    for pid in $(pidof ffmpeg 2>/dev/null || :); do
        args=$(tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null || :)
        if printf '%s\n' "$args" | grep -Fq "$NVR_BASE_DIR/cam"; then
            partial 'FFmpeg still uses the archive; inspect the recorder before retrying'
        fi
    done
fi
rm -f "$RECORDER" "$BOT" "$GUARD" || partial 'cannot remove program files'
for file in "$RECORDER" "$BOT" "$GUARD"; do
    [ ! -e "$file" ] || partial 'program file still exists'
done
printf 'KNVR removal SUCCESS. Configuration, video archive, backups and shared packages preserved.\n'
