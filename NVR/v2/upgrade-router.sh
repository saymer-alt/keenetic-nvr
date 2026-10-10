#!/bin/sh
# Safe upgrade of installed NVR v2.3 to v2.4 on Keenetic/Entware.
# Secrets and video archive remain local, untouched.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
LIVE=/opt/etc/nvr-v2.sh
CONF=/opt/etc/nvr-v2.conf
BK=/opt/etc/nvr-v24-upgrade-backup
CRON_INIT=/opt/etc/init.d/S10cron
SRC="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/nvr.sh"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
preflight() {
    [ -f "$LIVE" ] || fail 'No installed NVR v2 to upgrade'
    grep -q 'NVR v2.3' "$LIVE" || fail 'This upgrade is for v2.3 only; no changes made'
    [ -r "$CONF" ] || fail 'Local NVR config missing'
    [ -r "$SRC" ] && sh -n "$SRC" || fail 'Downloaded v2.4 script missing or invalid'
    grep -q 'NVR v2.4' "$SRC" || fail 'New script is not v2.4'
    [ -x "$CRON_INIT" ] || fail 'Entware cron init script missing'
    [ ! -e /tmp/cctv_is_running ] || fail 'Legacy v1 NVR marker detected'
    . "$CONF"
    : "${NVR_MOUNT:?}" "${NVR_BASE_DIR:?}"
    awk -v d="$NVR_MOUNT" '$2==d && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts ||
        fail 'Archive USB not mounted read-write'
    [ -d "$NVR_BASE_DIR" ] || fail 'Archive directory missing'
    if [ -d "$BK" ]; then
        for f in nvr-v23.sh root-crontab rollback.sh; do
            [ -f "$BK/$f" ] || fail "Incomplete upgrade backup: $f"
        done
        cmp -s "$BK/nvr-v23.sh" "$LIVE" || fail 'Existing backup differs from installed NVR'
    else
        [ ! -e "$BK" ] || fail 'Upgrade backup path occupied'
    fi
    count=$(crontab -l 2>/dev/null | grep -Ec '^(\*/5 \* \* \* \* /bin/sh /opt/etc/nvr-v2.sh check|3 \* \* \* \* /bin/sh /opt/etc/nvr-v2.sh cleanup)$' || :)
    [ "$count" = 2 ] || fail 'Expected exactly two NVR cron rules (*/5 check, HH:03 cleanup)'
    printf 'Upgrade preflight PASS: disk RW, config, old cron and new script OK.\n'
}
make_backup() {
    if [ -d "$BK" ]; then
        printf 'Reusing original upgrade backup: %s\n' "$BK"
        return 0
    fi
    mkdir -m 700 "$BK"
    cp -p "$LIVE" "$BK/nvr-v23.sh"
    crontab -l > "$BK/root-crontab"
    cp "$0" "$BK/rollback.sh"
    chmod 700 "$BK/rollback.sh"
}
disable_cron() {
    temp=$(mktemp /tmp/nvr-upgrade-cron.XXXXXX) || fail 'Cannot create temporary crontab'
    crontab -l | sed '/\/bin\/sh \/opt\/etc\/nvr-v2\.sh check$/d; /\/bin\/sh \/opt\/etc\/nvr-v2\.sh cleanup$/d' > "$temp"
    crontab "$temp"
    rm -f "$temp"
    "$CRON_INIT" restart
}
wait_lock() {
    n=0
    while [ -d /tmp/nvr-v2/.lock ] && [ "$n" -lt 30 ]; do
        sleep 1
        n=$((n+1))
    done
    [ ! -d /tmp/nvr-v2/.lock ] || fail 'Old NVR controller locked; refusing upgrade'
}
install_source() {
    next="/opt/etc/.nvr-v2.sh.new.$$"
    cp "$SRC" "$next"
    chmod 700 "$next"
    sh -n "$next" || { rm -f "$next"; fail 'Invalid staged script'; }
    mv -f "$next" "$LIVE"
}
verify_video() {
    . "$CONF"
    : "${NVR_CAMERAS:=101 201 301}"
    n=0
    while [ "$n" -lt 12 ]; do
        report=$(sh "$LIVE" status) || report=''
        good=1
        printf '%s\n' "$report" | grep -q '^NVR v2.4 - HEALTHY$' || good=0
        for id in $NVR_CAMERAS; do
            line=$(printf '%s\n' "$report" | grep -E "^CAM $id: HEALTHY, last write [0-9]+s ago$" || :)
            [ -n "$line" ] || { good=0; continue; }
            age=${line##*last write }
            age=${age%s ago}
            [ "$age" -lt 60 ] || good=0
        done
        [ "$good" -eq 1 ] && return 0
        n=$((n+1))
        [ "$n" -ge 12 ] || sleep 5
    done
    printf '%s\n' "$report" >&2
    return 1
}
restore() {
    [ -f "$BK/nvr-v23.sh" ] && [ -f "$BK/root-crontab" ] || fail 'Upgrade backup missing'
    printf 'Restoring the original v2.3 script and root crontab...\n'
    if [ -f "$LIVE" ] && [ -r "$CONF" ]; then sh "$LIVE" stop || :; fi
    cp -p "$BK/nvr-v23.sh" "$LIVE"
    chmod 700 "$LIVE"
    if [ -r "$CONF" ]; then
        . "$CONF"
        rm -f /tmp/nvr-v2/paused "${NVR_BASE_DIR:-/nonexistent}/.nvr-v2/paused"
        sh "$LIVE" start || printf 'WARN: old NVR did not restart, inspect status\n' >&2
    fi
    crontab "$BK/root-crontab"
    "$CRON_INIT" restart
    printf 'Rollback finished. Confirm all three camera recordings.\n'
}
upgrade() {
    preflight
    make_backup
    trap 'rc=$?; trap - EXIT; if [ "$rc" -ne 0 ]; then printf "Upgrade failed; automatic rollback\n" >&2; restore || :; fi' EXIT
    disable_cron
    wait_lock
    printf 'Stopping v2.3 recorders...\n'
    sh "$LIVE" stop || fail 'Could not stop v2.3'
    printf 'Installing v2.4...\n'
    install_source
    sh "$LIVE" start || fail 'Could not start v2.4'
    verify_video || fail 'One or more cameras did not produce a fresh MKV'
    crontab "$BK/root-crontab"
    "$CRON_INIT" restart
    trap - EXIT
    printf 'NVR upgrade PASS; three live cameras verified and cron restored.\n'
    sh "$LIVE" status
    printf 'Rollback: sh %s/rollback.sh rollback\n' "$BK"
}
case ${1:-} in
    preflight-upgrade) preflight ;;
    upgrade) upgrade ;;
    rollback) restore ;;
    *) echo 'Usage: upgrade-router.sh {preflight-upgrade|upgrade|rollback}' >&2; exit 2 ;;
esac
