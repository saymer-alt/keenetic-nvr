#!/bin/sh
# Offline KAS S00ubifs matrix. No real router mounts or service changes.
set -eu
cd "$(dirname "$0")/.."
sh -n tools/entware-flash-guard.sh
busybox sh -n tools/entware-flash-guard.sh
T=$(mktemp -d /tmp/knvr-kas-test.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/root/etc/init.d" "$T/root/tmp" "$T/root/var/log" "$T/root/var/run"
export KNVR_FLASH_ROOT="$T/root"
export KNVR_FLASH_MOUNTS="$T/mounts"
export KNVR_FLASH_S00_PATH="$T/root/etc/init.d/S00ubifs"
export KNVR_FLASH_SOURCE_FILE="$T/original-kas-fixture"
cat > "$KNVR_FLASH_SOURCE_FILE" <<'EOF'
#!/bin/sh
# Based on original Entware UBIFS helper by Entware team
TMP_DIR="/opt/tmp"
LOG_DIR="/opt/var/log"
RUN_DIR="/opt/var/run"
ENABLED=yes
case "$1" in
    start)
        for d in "$KNVR_FLASH_ROOT/tmp" "$KNVR_FLASH_ROOT/var/log" "$KNVR_FLASH_ROOT/var/run"; do
            if ! awk -v p="$d" '$2==p && $3=="tmpfs" {yes=1} END {exit !yes}' "$KNVR_FLASH_MOUNTS"; then
                printf 'tmpfs %s tmpfs rw,nosuid,nodev 0 0\n' "$d" >> "$KNVR_FLASH_MOUNTS"
            fi
        done ;;
    *) exit 2 ;;
esac
EOF
. tools/entware-flash-guard.sh
printf '/dev/ubi0_0 %s ubifs rw 0 0\n' "$KNVR_FLASH_ROOT" > "$KNVR_FLASH_MOUNTS"
[ "$(knvr_flash_class)" = internal ]
knvr_flash_preflight >/dev/null
[ ! -e "$KNVR_FLASH_S00_PATH" ] || { echo 'FAIL preflight modified /opt' >&2; exit 1; }
knvr_flash_ensure >/dev/null
[ -x "$KNVR_FLASH_S00_PATH" ] && knvr_flash_mounts_ready ||
    { echo 'FAIL automatic KAS install / three mounts' >&2; exit 1; }
sha=$(sha256sum "$KNVR_FLASH_S00_PATH" | awk '{print $1}')
knvr_flash_ensure >/dev/null
[ "$(sha256sum "$KNVR_FLASH_S00_PATH" | awk '{print $1}')" = "$sha" ] ||
    { echo 'FAIL active service overwritten' >&2; exit 1; }
[ "$(grep -c '^tmpfs ' "$KNVR_FLASH_MOUNTS")" -eq 3 ] ||
    { echo 'FAIL duplicated tmpfs mounts' >&2; exit 1; }
# Simulated reboot: /opt survives; mounts need remount.
printf '/dev/ubi0_0 %s ubifs rw 0 0\n' "$KNVR_FLASH_ROOT" > "$KNVR_FLASH_MOUNTS"
knvr_flash_ensure >/dev/null
knvr_flash_mounts_ready || { echo 'FAIL restart after reboot' >&2; exit 1; }
sed -i 's/^ENABLED=yes$/ENABLED=no/' "$KNVR_FLASH_S00_PATH"
if knvr_flash_preflight >/dev/null 2>&1; then echo 'FAIL disabled service accepted' >&2; exit 1; fi
if knvr_flash_ensure >/dev/null 2>&1; then echo 'FAIL disabled service overwritten' >&2; exit 1; fi
grep -q '^ENABLED=no' "$KNVR_FLASH_S00_PATH"
rm "$KNVR_FLASH_S00_PATH"
ln -s /etc/passwd "$KNVR_FLASH_S00_PATH"
if knvr_flash_preflight >/dev/null 2>&1; then echo 'FAIL symlink accepted' >&2; exit 1; fi
rm "$KNVR_FLASH_S00_PATH"
printf '#!/bin/sh\nexit 0\n' > "$KNVR_FLASH_S00_PATH"
chmod 755 "$KNVR_FLASH_S00_PATH"
if knvr_flash_preflight >/dev/null 2>&1; then echo 'FAIL foreign file accepted' >&2; exit 1; fi
rm "$KNVR_FLASH_S00_PATH"
KNVR_FLASH_SOURCE_FILE="$T/absent"
export KNVR_FLASH_SOURCE_FILE
if knvr_flash_ensure >/dev/null 2>&1; then echo 'FAIL invalid KAS source accepted' >&2; exit 1; fi
[ ! -e "$KNVR_FLASH_S00_PATH" ]
KNVR_FLASH_SOURCE_FILE="$T/original-kas-fixture"
export KNVR_FLASH_SOURCE_FILE
printf '/dev/sda1 %s ext4 rw 0 0\n' "$KNVR_FLASH_ROOT" > "$KNVR_FLASH_MOUNTS"
[ "$(knvr_flash_class)" = external-ext4 ]
knvr_flash_ensure >/dev/null
[ ! -e "$KNVR_FLASH_S00_PATH" ] || { echo 'FAIL installed on external /opt' >&2; exit 1; }
printf '/dev/sda1 %s ntfs rw 0 0\n' "$KNVR_FLASH_ROOT" > "$KNVR_FLASH_MOUNTS"
if knvr_flash_preflight >/dev/null 2>&1; then echo 'FAIL NTFS accepted' >&2; exit 1; fi
printf 'tmpfs %s tmpfs rw 0 0\n' "$KNVR_FLASH_ROOT" > "$KNVR_FLASH_MOUNTS"
if knvr_flash_preflight >/dev/null 2>&1; then echo 'FAIL volatile /opt accepted' >&2; exit 1; fi
printf '/dev/sda1 %s ext4 rw 0 0\n' "$T" > "$KNVR_FLASH_MOUNTS"
if knvr_flash_preflight >/dev/null 2>&1; then echo 'FAIL unknown /opt accepted' >&2; exit 1; fi
grep -Fq 'knvr_flash_ensure' NVR/v2/fresh-install.sh
grep -Fq 'knvr_flash_ensure' STREAM/v1/install.sh
grep -Fq 'entware-flash-guard.sh' NVR/v2/bootstrap.sh
grep -Fq 'entware-flash-guard.sh' STREAM/v1/bootstrap.sh
grep -Fq '/keenetic-auto-setup/stable/S00ubifs' tools/entware-flash-guard.sh
echo 'KAS S00ubifs auto-install matrix PASS'
