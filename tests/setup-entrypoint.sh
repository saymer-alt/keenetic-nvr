#!/bin/sh
# Offline entrypoint contract; must not touch router disks or install packages.
set -eu
cd "$(dirname "$0")/.."

sh -n setup.sh
busybox sh -n setup.sh
help=$(busybox sh setup.sh --help)
printf '%s\n' "$help" | grep -q 'Usage: sh setup.sh' ||
    { echo 'FAIL: setup help missing' >&2; exit 1; }
printf '%s\n' "$help" | grep -q 'Entware' ||
    { echo 'FAIL: setup requirements missing' >&2; exit 1; }

# Verify that the default action runs the full interactive installer and
# existing installations are protected, without trying to run it in CI.
grep -Fq 'MODE=${1:-install}' setup.sh ||
    { echo 'FAIL: default must be install' >&2; exit 1; }
grep -Fq 'sh "$TMP_DIR/bootstrap.sh" install-fresh' setup.sh ||
    { echo 'FAIL: full fresh installation not reached' >&2; exit 1; }
grep -Fq '/opt/etc/nvr-v2.conf' setup.sh ||
    { echo 'FAIL: existing configuration not protected' >&2; exit 1; }
grep -Fq '/opt/etc/nvr-v2.sh' setup.sh ||
    { echo 'FAIL: existing recorder not protected' >&2; exit 1; }
grep -Fq '/dev/tty' setup.sh ||
    { echo 'FAIL: interactive TTY requirement not checked' >&2; exit 1; }
grep -Fq 'https://raw.githubusercontent.com/saymer-alt/keenetic-nvr/main/NVR/v2' setup.sh ||
    { echo 'FAIL: incorrect source repository' >&2; exit 1; }
echo 'NVR setup entrypoint contract PASS'
