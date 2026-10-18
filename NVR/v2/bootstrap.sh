#!/bin/sh
# Download NVR v2.5 from the owner's GitHub repository before installation.
set -eu
umask 077
ACTION=${1:-}
case "$ACTION" in
    preflight|switch|preflight-fresh|install-fresh|configure-fresh|preflight-upgrade|upgrade) ;;
    *) echo 'Usage: bootstrap.sh {preflight|switch|preflight-fresh|install-fresh|configure-fresh|preflight-upgrade|upgrade}' >&2; exit 2;;
esac
# The default follows the published main branch. To test a development branch,
# export NVR_RAW_BASE=<raw URL base of that branch> before running.
ROOT_RAW=${NVR_PROJECT_RAW_BASE:-https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main}
RAW=${NVR_RAW_BASE:-https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2}
FLASH_HELPER_URL=${NVR_FLASH_HELPER_URL:-$ROOT_RAW/tools/entware-flash-guard.sh}
if ! command -v curl >/dev/null 2>&1; then
    echo 'curl missing. Install: opkg update && opkg install curl' >&2
    exit 1
fi
DIR=$(mktemp -d /tmp/nvr-setup.XXXXXX) || exit 1
trap 'rm -rf "$DIR"' EXIT
case "$ACTION" in
    *-fresh) FILES='nvr.sh fresh-install.sh storage-guard.sh'; RUNNER='fresh-install.sh' ;;
    preflight-upgrade|upgrade) FILES='nvr.sh upgrade-router.sh'; RUNNER='upgrade-router.sh' ;;
    *) FILES='nvr.sh install-router.sh'; RUNNER='install-router.sh' ;;
esac
case "$ACTION" in
    *-fresh)
        curl -fSsL --retry 2 --connect-timeout 15 "$FLASH_HELPER_URL" -o "$DIR/entware-flash-guard.sh" ||
            { echo 'Could not fetch KAS flash helper' >&2; exit 1; }
        [ -s "$DIR/entware-flash-guard.sh" ] && sh -n "$DIR/entware-flash-guard.sh" || exit 1 ;;
esac
for file in $FILES; do
    echo "Fetching $file from GitHub..."
    curl -fSsL --retry 2 --connect-timeout 15 "$RAW/$file" -o "$DIR/$file" || { echo "Failed to fetch $file" >&2; exit 1; }
    [ -s "$DIR/$file" ] && sh -n "$DIR/$file" || exit 1
done
sh "$DIR/$RUNNER" "$ACTION"
