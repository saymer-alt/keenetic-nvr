#!/bin/sh
# For diagnosed Keenetic 192.168.1.2. Run from downloaded NVR/v2 files.
# No GitHub downloads and no camera credentials leave the router.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
MNT='/tmp/mnt/f9bf834b-5650-d901-f0aa-834b5650d901'
BASE="$MNT/cctv"
OLD="$BASE/record_cctv.sh"
INIT='/opt/etc/init.d/S99cctv'
V2='/opt/etc/nvr-v2.sh'
CONF='/opt/etc/nvr-v2.conf'
BACKUP='/opt/etc/nvr-v2-backup'
SRC="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/nvr.sh"
ROOT_CRON_TEMP='/tmp/nvr-v2-root-crontab'
SYSTEM_CRON_TEMP='/tmp/nvr-v2-system-crontab'

# Parse a v2.4 status line: "CAM <id>: HEALTHY, last write <n>s ago".
status_cam_age() {
    id=$1; output=$2
    line=$(printf '%s\n' "$output" | grep "^CAM $id: HEALTHY, last write [0-9][0-9]*s ago\$" || :)
    [ -n "$line" ] || return 1
    age=${line##*last write }
    age=${age%s ago}
    case "$age" in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$age"
}

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
mounted_rw() { awk -v d="$MNT" '$2==d && $4 ~ /(^|,)rw(,|$)/ {ok=1} END{exit !ok}' /proc/mounts; }

preflight() {
    [ -f "$SRC" ] || err "Missing source: $SRC"
    [ -f "$OLD" ] || err "Missing previous camera config: $OLD"
    [ -f "$INIT" ] || err "Missing old init: $INIT"
    [ -x /opt/bin/ffmpeg ] || err 'FFmpeg not installed'
    mounted_rw || err 'Archive disk is not mounted read-write'
    [ -d "$BASE" ] || err "Archive directory missing: $BASE"
    [ -x /opt/sbin/cron ] || err 'Entware cron is missing'
    [ -f /opt/etc/crontab ] || err 'System crontab missing'
    sh -n "$SRC" || err 'New recorder has invalid shell syntax'
    command -v stat >/dev/null 2>&1 || err 'stat missing: run opkg update && opkg install coreutils-stat; no changes made'
    file_mtime=$(stat -c %Y "$OLD" 2>/dev/null) || err 'stat -c %Y failed: install coreutils-stat; no changes made'
    case "$file_mtime" in ''|*[!0-9]*) err 'stat returned invalid mtime: install coreutils-stat';; esac
    [ "$file_mtime" -gt 0 ] || err 'stat returned zero mtime: install coreutils-stat'
    file_size=$(stat -c %s "$OLD" 2>/dev/null) || err 'stat -c %s failed: install coreutils-stat'
    case "$file_size" in ''|*[!0-9]*) err 'stat returned invalid size';; esac
    [ "$file_size" -gt 0 ] || err 'Record script empty (stat size=0)'
    # ffmpeg 6.1 should expose `-timeout`; fail closed on incompatible builds.
    /opt/bin/ffmpeg -hide_banner -h demuxer=rtsp 2>&1 | grep -q -- '-timeout ' || err 'FFmpeg RTSP -timeout capability not detected; no changes made'
    for k in RTSP_USER RTSP_PASS RTSP_IP; do
        grep -q "^${k}=" "$OLD" || err "Missing $k in old configuration"
    done
    printf 'Preflight PASS. Mounted disk RW; stat mtime/size OK; FFmpeg RTSP timeout supported.\n'
}

save_backup() {
    if [ -d "$BACKUP" ]; then
        for required in S99cctv record_cctv.sh system-crontab root-crontab rollback.sh; do
            [ -f "$BACKUP/$required" ] || err "Incomplete existing backup: $required; refusing cutover"
        done
        printf 'Reusing original local backup at %s after previous rollback.\n' "$BACKUP"
        return 0
    fi
    [ ! -e "$BACKUP" ] || err "Backup path exists but is not a directory: $BACKUP"
    mkdir -m 700 "$BACKUP"
    cp -p "$INIT" "$BACKUP/S99cctv"
    cp "$0" "$BACKUP/rollback.sh"
    cp -p /opt/etc/crontab "$BACKUP/system-crontab"
    crontab -l > "$BACKUP/root-crontab"
    cp -p "$OLD" "$BACKUP/record_cctv.sh"
    [ ! -f "$BASE/cleanup_cctv.sh" ] || cp -p "$BASE/cleanup_cctv.sh" "$BACKUP/cleanup_cctv.sh"
}

remove_old_cron() {
    # system crontab has a user field; leave unrelated jobs untouched.
    sed '/cleanup_cctv\.sh/d; /S99cctv start/d; /nvr-cron-watch\.sh/d' /opt/etc/crontab > "$SYSTEM_CRON_TEMP"
    cp "$SYSTEM_CRON_TEMP" /opt/etc/crontab
    chmod 644 /opt/etc/crontab
    # user crontab must NOT have the root field.
    sed '/cleanup_cctv\.sh/d; /S99cctv start/d; /nvr-cron-watch\.sh/d; /nvr-v2\.sh/d' "$BACKUP/root-crontab" > "$ROOT_CRON_TEMP"
    crontab "$ROOT_CRON_TEMP"
    /opt/etc/init.d/S10cron restart
}

verify_started() {
    # RTSP handshake + first video frames can take longer than eight seconds.
    attempt=0
    while [ "$attempt" -lt 12 ]; do
        all_good=1
        status_output=$(sh "$V2" status) || all_good=0
        for id in 101 201 301; do
            age=$(status_cam_age "$id" "$status_output") || { all_good=0; continue; }
            [ "$age" -lt 60 ] || all_good=0
        done
        if [ "$all_good" -eq 1 ]; then return 0; fi
        attempt=$((attempt+1))
        [ "$attempt" -ge 12 ] || sleep 5
    done
    printf 'NVR verification after 60 seconds:\n%s\n' "$status_output" >&2
    err 'At least one camera did not produce a fresh MKV; automatic rollback initiated'
}

restore() {
    [ -d "$BACKUP" ] || err "No backup at $BACKUP"
    printf 'Disabling v2 cron, stopping v2 and restoring previous setup...\n'
    # Stop v2 FIRST, before re-enabling legacy boot/cron.
    if [ -f "$V2" ] && [ -f "$CONF" ]; then sh "$V2" stop || :; fi
    crontab "$BACKUP/root-crontab"
    cp -p "$BACKUP/system-crontab" /opt/etc/crontab
    /opt/etc/init.d/S10cron restart || :
    cp -p "$BACKUP/S99cctv" "$INIT"
    chmod 755 "$INIT"
    "$INIT" start
    printf 'Rollback requested. Check FFmpeg processes and camera MKV creation now.\n'
}

switch() {
    preflight
    save_backup
    # Restore legacy setup on a partial cutover.
    trap 'code=$?; trap - EXIT; if [ "$code" -ne 0 ]; then echo "Cutover failed; rolling back" >&2; restore || :; fi' EXIT
    cp "$SRC" "$V2"
    chmod 700 "$V2"
    # Secrets are extracted locally. Never print or upload this config.
    {
        printf "NVR_MOUNT='%s'\nNVR_BASE_DIR='%s'\n" "$MNT" "$BASE"
        sed -n '/^RTSP_USER=/p; /^RTSP_PASS=/p; /^RTSP_IP=/p' "$OLD"
        printf "NVR_CAMERAS='101 201 301'\n"
    } > "$CONF"
    chmod 600 "$CONF"
    sh -n "$CONF" || err 'Extracted config is invalid; old recorder is still running'
    # Stop old scheduled jobs before changing old camera processes.
    remove_old_cron
    printf 'Stopping legacy NVR (up to 12 seconds)...\n'
    "$INIT" stop
    # Old auto init must not revive v1 after reboot.
    mv "$INIT" "$BACKUP/S99cctv.disabled"
    if [ -f /tmp/cctv_is_running ]; then
        err 'Legacy running marker persists; run rollback'
    fi
    # Do not adopt a still-running legacy camera FFmpeg during cutover.
    for p in $(pidof ffmpeg 2>/dev/null || :); do
        if tr '\000' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -Eq '/Streaming/Channels/(101|201|301)$'; then
            err "Legacy FFmpeg pid=$p still alive; run rollback or investigate before v2 start"
        fi
    done
    printf 'Starting new NVR...\n'
    sh "$V2" start || err 'NVR v2 start failed; run rollback'
    verify_started
    {
        cat "$ROOT_CRON_TEMP"
        printf '\n*/5 * * * * /bin/sh /opt/etc/nvr-v2.sh check\n'
        printf '3 * * * * /bin/sh /opt/etc/nvr-v2.sh cleanup\n'
    } > /tmp/nvr-v2-new-crontab
    crontab /tmp/nvr-v2-new-crontab
    /opt/etc/init.d/S10cron restart
    printf '\nNVR v2.4 activated with three running cameras.\n'
    sh "$V2" status
    printf '\nCron rules:\n'
    crontab -l
    printf '\nRollback: sh %s rollback\n' "$BACKUP/rollback.sh"
    printf '\nOptional notifications (Telegram/webhook): add NVR_NOTIFY_* keys to %s (mode 600)\nand run: sh %s notify test\nSee NVR/v2/README.md, section Notifications.\n' "$CONF" "$V2"
    trap - EXIT
}

case ${1:-} in
    preflight) preflight;;
    switch) switch;;
    rollback) restore;;
    *) printf 'Usage: sh install-router.sh {preflight|switch|rollback}\n' >&2; exit 2;;
esac