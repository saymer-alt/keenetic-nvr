#!/bin/sh
# Read-only mount classification, EXT4 validation and independent archive tests.
set -eu
cd "$(dirname "$0")/.."
sh -n NVR/v2/storage-guard.sh
busybox sh -n NVR/v2/storage-guard.sh
mkdir -p /tmp/mnt
T=$(mktemp -d /tmp/mnt/nvr-storage-test.XXXXXX)
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/internal/opt" "$T/usb/cctv" "$T/external/opt" "$T/unrelated" "$T/unknown"
ln -s "$T/internal/opt" "$T/opt-link"
NVR_MOUNTS_FILE="$T/mounts"
NVR_OPT_PATH="$T/internal/opt"
export NVR_MOUNTS_FILE NVR_OPT_PATH
. NVR/v2/storage-guard.sh

write_mounts() {
    printf '/dev/ubi0_0 %s ubifs rw,relatime 0 0\n/dev/sda1 %s ext4 rw,relatime 0 0\n' \
        "$T/internal" "$T/usb" > "$NVR_MOUNTS_FILE"
}
write_mounts
[ "$(nvr_opt_profile)" = internal-ubifs ]
NVR_OPT_PATH="$T/opt-link"
[ "$(nvr_opt_profile)" = internal-ubifs ] || { echo 'FAIL UBIFS symlink' >&2; exit 1; }
NVR_OPT_PATH="$T/internal/opt"
nvr_archive_safe "$T/usb" "$T/usb/cctv" ||
    { echo 'FAIL dedicated EXT4 RW mount' >&2; exit 1; }

printf '/dev/ubi0_0 %s ubifs rw 0 0\n/dev/sda1 %s ext4 ro 0 0\n' \
    "$T/internal" "$T/usb" > "$NVR_MOUNTS_FILE"
if nvr_archive_safe "$T/usb" "$T/usb/cctv"; then
    echo 'FAIL read-only EXT4 mount accepted' >&2; exit 1
fi
printf '/dev/ubi0_0 %s ubifs rw 0 0\n/dev/sda1 %s ntfs rw 0 0\n' \
    "$T/internal" "$T/usb" > "$NVR_MOUNTS_FILE"
if nvr_archive_safe "$T/usb" "$T/usb/cctv"; then
    echo 'FAIL non-EXT4 mount accepted' >&2; exit 1
fi
printf '/dev/ubi0_0 %s ubifs rw 0 0\n' "$T/internal" > "$NVR_MOUNTS_FILE"
if nvr_archive_safe "$T/usb" "$T/usb/cctv"; then
    echo 'FAIL unmounted directory accepted' >&2; exit 1
fi

write_mounts
NVR_OPT_PATH="$T/usb/opt"
mkdir -p "$NVR_OPT_PATH"
if nvr_archive_safe "$T/usb" "$T/usb/cctv"; then
    echo 'FAIL shared physical partition accepted' >&2; exit 1
fi

# Deepest matching mount must win, including an /opt bind mount.
NVR_OPT_PATH="$T/external/opt"
printf '/dev/ubi0_0 %s ubifs rw 0 0\n/dev/sdc2 %s ext4 rw 0 0\n/dev/sda1 %s ext4 rw 0 0\n' \
    "$T" "$T/external" "$T/usb" > "$NVR_MOUNTS_FILE"
[ "$(nvr_opt_profile)" = external-ext4 ] ||
    { echo 'FAIL nested external /opt' >&2; exit 1; }
nvr_archive_safe "$T/usb" "$T/usb/cctv" ||
    { echo 'FAIL independently mounted /opt and archive' >&2; exit 1; }

NVR_OPT_PATH="$T/unknown"
printf '/dev/loop0 %s squashfs ro 0 0\n/dev/sda1 %s ext4 rw 0 0\n' \
    "$T/unknown" "$T/usb" > "$NVR_MOUNTS_FILE"
if nvr_opt_profile >/dev/null; then
    echo 'FAIL unsupported /opt accepted' >&2; exit 1
fi
echo 'NAND/EXT4 guard matrix PASS'
