#!/bin/sh
# Offline, non-destructive installation of STREAM v1 (not NVR).
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SCRIPT_SRC="$HERE/stream.sh"
INIT_SRC="$HERE/init.d/S99stream"
EXAMPLE="$HERE/stream.conf.example"
FLASH_HELPER="$HERE/entware-flash-guard.sh"
[ -r "$FLASH_HELPER" ] || FLASH_HELPER="$HERE/../../tools/entware-flash-guard.sh"
DEST_SCRIPT=/opt/etc/keenetic-stream.sh
DEST_INIT=/opt/etc/init.d/S99stream
DEST_CONFIG=/opt/etc/keenetic-stream.conf
BACKUP_DIR=/opt/etc/keenetic-stream-backups
fail() { printf 'STREAM installer: %s\n' "$*" >&2; exit 1; }

preflight() {
    [ "$(id -u)" = 0 ] || fail 'Root required'
    [ -x /opt/bin/opkg ] || fail 'Entware is missing; restore /opt before STREAM'
    [ -x /opt/bin/ffmpeg ] || fail 'ffmpeg missing; install it separately using opkg'
    [ -d /opt/etc/init.d ] || fail 'Entware init directory missing'
    [ -r "$FLASH_HELPER" ] && sh -n "$FLASH_HELPER" ||
        fail 'KAS S00ubifs helper missing/invalid'
    . "$FLASH_HELPER"
    knvr_flash_preflight || fail 'Entware flash-protection preflight failed'
    for file in "$SCRIPT_SRC" "$INIT_SRC" "$EXAMPLE"; do
        [ -r "$file" ] && sh -n "$file" || fail "Source missing or invalid: $file"
    done
    # Never seize the old S99stream service without explicit authorization.
    if [ -e "$DEST_INIT" ] &&
       ! grep -Fq '# Keenetic STREAM v1 standalone init' "$DEST_INIT"; then
        [ "${STREAM_REPLACE_LEGACY:-0}" = 1 ] ||
            fail 'Foreign/legacy S99stream exists. Back it up and re-run with STREAM_REPLACE_LEGACY=1'
    fi
    printf 'STREAM preflight PASS: Entware + FFmpeg found, NVR unaffected.\n'
}
copy_atomic() {
    src=$1; dest=$2
    stage="$dest.tmp.$$"
    cp "$src" "$stage" || fail "Cannot stage $dest"
    chmod 700 "$stage"
    mv -f "$stage" "$dest" || fail "Cannot install $dest"
}
install() {
    preflight
    knvr_flash_ensure || fail 'KAS S00ubifs installation/activation failed'
    mkdir -p "$BACKUP_DIR" || fail 'Cannot create backup directory'
    chmod 700 "$BACKUP_DIR"
    if [ -e "$DEST_SCRIPT" ]; then cp -p "$DEST_SCRIPT" "$BACKUP_DIR/keenetic-stream.previous.sh"; fi
    if [ -e "$DEST_INIT" ]; then cp -p "$DEST_INIT" "$BACKUP_DIR/S99stream.previous"; fi
    # Save local credentials: never overwrite an existing configured file.
    if [ ! -e "$DEST_CONFIG" ]; then
        copy_atomic "$EXAMPLE" "$DEST_CONFIG"
        chmod 600 "$DEST_CONFIG"
        printf 'New config is a template. Edit locally: %s\n' "$DEST_CONFIG"
    else
        printf 'Existing config preserved: %s\n' "$DEST_CONFIG"
    fi
    copy_atomic "$SCRIPT_SRC" "$DEST_SCRIPT"
    copy_atomic "$INIT_SRC" "$DEST_INIT"
    printf 'STREAM installed but NOT started. No opkg packages or NVR files changed.\n'
    printf 'Configure %s, then run:\n' "$DEST_CONFIG"
    printf '  sh %s check\n  sh %s start\n  sh %s playlist\n' \
        "$DEST_SCRIPT" "$DEST_SCRIPT" "$DEST_SCRIPT"
}
case ${1:-} in
    preflight) preflight ;;
    install) install ;;
    -h|--help|help)
        printf 'Usage: sh install.sh [preflight|install]\n'
        printf 'Use STREAM_REPLACE_LEGACY=1 only to replace an existing foreign S99stream.\n' ;;
    *) fail 'Use install, preflight or --help' ;;
esac
