#!/bin/sh
# Download NVR v2.4 from the owner's GitHub repository before installation.
set -eu
umask 077
ACTION=${1:-}
case "$ACTION" in
    preflight|switch|preflight-fresh|install-fresh|configure-fresh) ;;
    *) echo 'Usage: bootstrap.sh {preflight|switch|preflight-fresh|install-fresh|configure-fresh}' >&2; exit 2;;
esac
# The default follows the published main branch. To test a development branch,
# export NVR_RAW_BASE=<raw URL base of that branch> before running.
RAW=${NVR_RAW_BASE:-https://raw.githubusercontent.com/saymer-alt/keenetic-knowledge-base/main/NVR/v2}
if ! command -v curl >/dev/null 2>&1; then
    echo 'curl missing. Install: opkg update && opkg install curl' >&2
    exit 1
fi
DIR=$(mktemp -d /tmp/nvr-setup.XXXXXX) || exit 1
trap 'rm -rf "$DIR"' EXIT
case "$ACTION" in
    *-fresh) FILES='nvr.sh fresh-install.sh'; RUNNER='fresh-install.sh' ;;
    *) FILES='nvr.sh install-router.sh'; RUNNER='install-router.sh' ;;
esac
for file in $FILES; do
    echo "Fetching $file from GitHub..."
    curl -fSsL --retry 2 --connect-timeout 15 "$RAW/$file" -o "$DIR/$file" || { echo "Failed to fetch $file" >&2; exit 1; }
    [ -s "$DIR/$file" ] && sh -n "$DIR/$file" || exit 1
done
sh "$DIR/$RUNNER" "$ACTION"
