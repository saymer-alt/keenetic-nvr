#!/bin/sh
# KAS S00ubifs integration for standalone NVR/STREAM installers.
# Upstream unchanged: keenetic-auto-setup/stable/S00ubifs.
# Based on KAS setup.sh opt_storage_class + install.sh TMPFS PROTECTION v1.
: "${KNVR_FLASH_ROOT:=/opt}"
: "${KNVR_FLASH_MOUNTS:=/proc/mounts}"
: "${KNVR_KAS_S00_URL:=https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/S00ubifs}"

knvr_flash_err() { printf 'ERROR KNVR flash protection: %s\n' "$*" >&2; return 1; }

knvr_flash_class() {
    _kf_path=$(readlink -f "$KNVR_FLASH_ROOT" 2>/dev/null) || return 1
    [ -r "$KNVR_FLASH_MOUNTS" ] || return 1
    awk -v p="$_kf_path" '
        $2 ~ /^\// {
            m=$2
            if (p==m || m=="/" || index(p,m "/")==1) {
                if (length(m)>=best) {best=length(m); source=$1; fs=$3; found=1}
            }
        }
        END {
            if (!found) exit 1
            if (fs=="ubifs" || fs=="squashfs" || source ~ /^(ubi|mtd)/) print "internal"
            else if (fs=="tmpfs" || fs=="ramfs") print "ram"
            else if (fs=="ext4" && source ~ /^\/dev\/(sd|nvme)/) print "external-ext4"
            else print "unknown"
        }
    ' "$KNVR_FLASH_MOUNTS"
}

knvr_flash_script_path() {
    printf '%s\n' "${KNVR_FLASH_S00_PATH:-$KNVR_FLASH_ROOT/etc/init.d/S00ubifs}"
}
knvr_flash_enabled() {
    grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes([[:space:]]*(#.*)?)?$' "$1"
}
knvr_flash_candidate() {
    [ -s "$1" ] && [ "$(head -n 1 "$1" 2>/dev/null)" = '#!/bin/sh' ] &&
        sh -n "$1" &&
        grep -Fq 'Based on original Entware UBIFS helper by Entware team' "$1" &&
        grep -Fq 'TMP_DIR="/opt/tmp"' "$1" &&
        grep -Fq 'LOG_DIR="/opt/var/log"' "$1" &&
        grep -Fq 'RUN_DIR="/opt/var/run"' "$1" &&
        knvr_flash_enabled "$1"
}
knvr_flash_mounts_ready() {
    _kf_mounts=$KNVR_FLASH_MOUNTS
    [ -r "$_kf_mounts" ] || return 1
    for _kf_dir in "$KNVR_FLASH_ROOT/tmp" "$KNVR_FLASH_ROOT/var/log" "$KNVR_FLASH_ROOT/var/run"; do
        awk -v path="$_kf_dir" '$2==path && $3=="tmpfs" {found=1} END {exit !found}' \
            "$_kf_mounts" || return 1
    done
}
knvr_flash_preflight() {
    _kf_class=$(knvr_flash_class) ||
        { knvr_flash_err "Could not classify $KNVR_FLASH_ROOT storage"; return 1; }
    case "$_kf_class" in
        external-ext4)
            printf 'INFO KNVR: Entware /opt is external EXT4; S00ubifs not required.\n'
            return 0 ;;
        internal) : ;;
        ram|unknown|*)
            knvr_flash_err "Unsupported /opt storage class: $_kf_class"
            return 1 ;;
    esac
    _kf_dest=$(knvr_flash_script_path)
    [ ! -L "$_kf_dest" ] || { knvr_flash_err 'S00ubifs target is a symlink'; return 1; }
    if [ -e "$_kf_dest" ]; then
        [ -x "$_kf_dest" ] && knvr_flash_candidate "$_kf_dest" ||
            { knvr_flash_err 'Existing S00ubifs disabled/invalid/foreign; refusing overwrite'; return 1; }
        if knvr_flash_mounts_ready; then
            printf 'INFO KNVR: KAS S00ubifs already active; no reinstall needed.\n'
        else
            printf 'INFO KNVR: KAS S00ubifs present; will start and verify tmpfs.\n'
        fi
    else
        command -v curl >/dev/null 2>&1 ||
            { knvr_flash_err 'curl needed to fetch KAS S00ubifs'; return 1; }
        printf 'INFO KNVR: Internal UBIFS detected; KAS S00ubifs will be installed automatically.\n'
    fi
}
knvr_flash_ensure() {
    knvr_flash_preflight || return 1
    _kf_class=$(knvr_flash_class) || return 1
    [ "$_kf_class" = internal ] || return 0
    _kf_dest=$(knvr_flash_script_path)
    if [ -x "$_kf_dest" ] && knvr_flash_mounts_ready; then return 0; fi

    if [ ! -e "$_kf_dest" ]; then
        # Fetch canonical KAS code into RAM first; never execute partial files.
        _kf_stage=$(mktemp /tmp/knvr-kas-s00ubifs.XXXXXX) ||
            { knvr_flash_err 'Cannot stage S00ubifs in RAM'; return 1; }
        if [ -n "${KNVR_FLASH_SOURCE_FILE:-}" ]; then
            cp "$KNVR_FLASH_SOURCE_FILE" "$_kf_stage" || {
                rm -f "$_kf_stage"; knvr_flash_err 'Could not stage local KAS fixture'; return 1;
            }
        else
            curl -fSsL --connect-timeout 10 --max-time 30 "$KNVR_KAS_S00_URL" -o "$_kf_stage" || {
                rm -f "$_kf_stage"; knvr_flash_err 'Could not fetch original KAS S00ubifs'; return 1;
            }
        fi
        knvr_flash_candidate "$_kf_stage" || {
            rm -f "$_kf_stage"; knvr_flash_err 'Downloaded KAS S00ubifs is invalid'; return 1;
        }
        _kf_install_tmp=$(mktemp "$_kf_dest.tmp.XXXXXX") || {
            rm -f "$_kf_stage"; knvr_flash_err 'Cannot stage S00ubifs in init.d'; return 1;
        }
        if ! cp "$_kf_stage" "$_kf_install_tmp" || ! chmod 755 "$_kf_install_tmp" ||
            ! mv -f "$_kf_install_tmp" "$_kf_dest"; then
            rm -f "$_kf_stage" "$_kf_install_tmp"
            knvr_flash_err 'Could not atomically install S00ubifs'; return 1
        fi
        rm -f "$_kf_stage"
        printf 'INFO KNVR: Original KAS S00ubifs installed; starting RAM protection.\n'
    fi
    # KAS "start" skips active tmpfs, refuses competing mounts.
    "$_kf_dest" start || {
        knvr_flash_err 'KAS S00ubifs start failed; refusing service installation'; return 1;
    }
    knvr_flash_mounts_ready || {
        knvr_flash_err 'KAS S00ubifs incomplete: three active tmpfs mounts required'; return 1;
    }
    printf 'PASS KNVR: KAS S00ubifs active (/opt/tmp, /opt/var/log, /opt/var/run).\n'
}
