#!/bin/sh
# Single-command entry point for a NEW Keenetic NVR v2.4 installation.
# Supports "curl .../setup.sh | sh" by reading all interaction from /dev/tty.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
RAW=${NVR_RAW_BASE:-https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2}
BOOTSTRAP_URL="$RAW/bootstrap.sh"
MODE=${1:-install}
TMP_DIR=''

fail() { printf 'NVR setup: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

case "$MODE" in
    install|preflight) ;;
    -h|--help|help)
        printf 'Usage: sh setup.sh [install|preflight]\n'
        printf 'Requires Entware, an interactive SSH TTY and a separate USB EXT4 archive disk.\n'
        printf 'Default: install a fresh NVR v2.4, not upgrade an existing recorder.\n'
        exit 0
        ;;
    *) fail 'Use install, preflight or --help' ;;
esac

[ "$(id -u)" = 0 ] || fail 'Run as root over SSH'
[ -x /opt/bin/opkg ] || fail 'Entware not installed: set up /opt and opkg first'
[ -r /dev/tty ] && [ -w /dev/tty ] ||
    fail 'An interactive SSH TTY is required (ssh -t)'
command -v curl >/dev/null 2>&1 ||
    fail 'curl missing; run opkg update && opkg install curl'
case "$RAW" in
    https://*) ;;
    *) fail 'NVR_RAW_BASE must use HTTPS' ;;
esac

# Never replace an existing NVR through the one-command *fresh* installer.
if [ "$MODE" = install ] &&     { [ -e /opt/etc/nvr-v2.conf ] || [ -e /opt/etc/nvr-v2.sh ]; }; then
    fail 'NVR is already installed; use the documented upgrade procedure instead'
fi

printf 'Keenetic NVR v2.4 — %s\n' "$MODE"
printf 'Entware found. The fresh installer will check FFmpeg, Cron, the archive disk and RTSP streams.\n'
if [ "$MODE" = preflight ]; then
    printf 'Preflight may offer to install missing Entware packages after confirmation.\n'
fi

TMP_DIR=$(mktemp -d /tmp/nvr-entry.XXXXXX) || fail 'Cannot create temporary directory'
curl -fSsL --retry 2 --connect-timeout 15 --max-time 45     "$BOOTSTRAP_URL" -o "$TMP_DIR/bootstrap.sh" ||
    fail 'Could not download NVR bootstrap from GitHub'
[ -s "$TMP_DIR/bootstrap.sh" ] && sh -n "$TMP_DIR/bootstrap.sh" ||
    fail 'Downloaded bootstrap failed shell syntax validation'

case "$MODE" in
    install) sh "$TMP_DIR/bootstrap.sh" install-fresh ;;
    preflight) sh "$TMP_DIR/bootstrap.sh" preflight-fresh ;;
esac
