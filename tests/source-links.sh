#!/bin/sh
# Ensure fresh installers resolve canonical upstream; no network or router required.
set -eu
cd "$(dirname "$0")/.."
base='https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2'
for file in NVR/v2/bootstrap.sh NVR/v2/telegram-bot-install.sh; do
    if ! grep -Fq "$base" "$file"; then
        echo "FAIL: $file does not use new upstream" >&2
        exit 1
    fi
    if grep -Fq 'saymer-alt/keenetic-knowledge-base/main/NVR/v2' "$file"; then
        echo "FAIL: $file still defaults to legacy upstream" >&2
        exit 1
    fi
done
for file in NVR/v2/nvr.sh NVR/v2/upgrade-router.sh NVR/v2/fresh-install.sh NVR/v2/telegram-bot.sh NVR/v2/telegram-bot-install.sh; do
    [ -s "$file" ] || { echo "FAIL: missing $file" >&2; exit 1; }
done
if grep -Fq 'nvr/watchdog-v2-candidate' NVR/v2/README.md; then
    echo "FAIL: README refers to abandoned candidate branch" >&2
    exit 1
fi
echo 'Standalone source links PASS'
