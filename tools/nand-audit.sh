#!/bin/sh
# Read-only Keenetic Entware NAND wear audit; runs even before restoring opkg.
# Never mounts, formats, runs opkg, reads secrets or creates files.
set -eu
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
MOUNTS=${NAND_AUDIT_MOUNTS:-/proc/mounts}
OPT=${NAND_AUDIT_OPT:-/opt}
TMP=${NAND_AUDIT_TMP:-/tmp}
[ -r "$MOUNTS" ] || { echo 'ERROR: mount table inaccessible' >&2; exit 2; }
mount_entry() {
    p=$(readlink -f "$1" 2>/dev/null) || return 1
    awk -v p="$p" '
        $2 ~ /^\// {
            m=$2
            if (p==m || m=="/" || index(p,m "/")==1) {
                if (length(m)>=best) {best=length(m); line=$1 "|" m "|" $3 "|" $4}
            }
        }
        END { if (best>0) print line; else exit 1 }
    ' "$MOUNTS"
}
fs_at() {
    entry=$(mount_entry "$1") || return 1
    printf '%s\n' "$entry" | cut -d '|' -f 3
}
code=0
printf '=== Keenetic Entware NAND write audit (read-only) ===\n'
opt_fs=$(fs_at "$OPT" 2>/dev/null || echo unknown)
tmp_fs=$(fs_at "$TMP" 2>/dev/null || echo unknown)
case "$opt_fs" in
    ubifs) printf 'PASS /opt: internal UBIFS (packages/configs stay persistent)\n' ;;
    ext4) printf 'INFO /opt: external EXT4, not internal NAND\n' ;;
    *) printf 'WARN /opt: unmounted or unsupported filesystem (%s)\n' "$opt_fs"; code=2 ;;
esac
if [ "$tmp_fs" = tmpfs ]; then
    printf 'PASS /tmp: tmpfs RAM-backed runtime state\n'
else
    printf 'FAIL /tmp: not proven tmpfs (found %s); pause NVR/STREAM\n' "$tmp_fs"
    code=2
fi
# Warning only: existence on NAND does not prove active writes. Entware
# cron/syslog/swap configuration and any other packages must be audited.
for rel in tmp var/log var/run var/cache var/lib; do
    path="$OPT/$rel"
    [ -e "$path" ] || continue
    kind=$(fs_at "$path" 2>/dev/null || echo unknown)
    case "$kind" in
        tmpfs) printf 'PASS /opt/%s: tmpfs RAM\n' "$rel" ;;
        ubifs) printf 'WARN /opt/%s: still on UBIFS; inspect writer activity\n' "$rel" ;;
        *) printf 'INFO /opt/%s: %s\n' "$rel" "$kind" ;;
    esac
done
printf 'INFO NVR: recordings + durable bot state should live on verified USB EXT4.\n'
printf 'INFO STREAM: FFmpeg output is HTTP; PID/lock state belongs to /tmp.\n'
printf 'INFO Entware package DB/config and infrequent installs remain persistent on UBIFS.\n'
printf 'INFO No mounts, files or router settings changed.\n'
exit "$code"
