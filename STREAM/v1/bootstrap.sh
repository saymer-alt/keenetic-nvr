#!/bin/sh
# Remote bootstrap solely for STREAM/v1. Does not call root NVR setup.sh.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
RAW=${STREAM_RAW_BASE:-https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/STREAM/v1}
MODE=${1:-preflight}
case "$MODE" in preflight|install) ;; *) echo 'Usage: bootstrap.sh {preflight|install}' >&2; exit 2 ;; esac
case "$RAW" in https://*) ;; *) echo 'STREAM_RAW_BASE must be HTTPS' >&2; exit 1 ;; esac
command -v curl >/dev/null 2>&1 || { echo 'curl missing' >&2; exit 1; }
TMP=$(mktemp -d /tmp/keenetic-stream-setup.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
mkdir -p "$TMP/init.d"
for path in install.sh stream.sh stream.conf.example init.d/S99stream; do
    curl -fSsL --connect-timeout 10 --max-time 30 "$RAW/$path" -o "$TMP/$path" ||
        { echo "Download failed: $path" >&2; exit 1; }
    [ -s "$TMP/$path" ] || exit 1
done
for file in "$TMP/install.sh" "$TMP/stream.sh" "$TMP/init.d/S99stream"; do
    sh -n "$file" || exit 1
done
/bin/sh "$TMP/install.sh" "$MODE"
