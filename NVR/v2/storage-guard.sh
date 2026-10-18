#!/bin/sh
# Shared read-only storage checks for KNVR. POSIX sh / BusyBox ash.
# Source this file; no mount, package or router configuration is changed.
# NVR_MOUNTS_FILE is an offline test seam. The live default is /proc/mounts.

nvr_mount_entry() {
    nvr_target=$(readlink -f "$1" 2>/dev/null) || return 1
    [ -n "$nvr_target" ] || return 1
    nvr_mounts=${NVR_MOUNTS_FILE:-/proc/mounts}
    [ -r "$nvr_mounts" ] || return 1
    awk -v p="$nvr_target" '
        $2 ~ /^\// {
            mp=$2
            if (p == mp || (mp == "/" && substr(p,1,1)=="/") ||
                index(p, mp "/") == 1) {
                if (length(mp) >= best) {
                    best=length(mp)
                    value=$1 "|" mp "|" $3 "|" $4
                    found=1
                }
            }
        }
        END { if (found) print value; else exit 1 }
    ' "$nvr_mounts"
}

nvr_opt_profile() {
    # Test override permits a synthetic /opt path; never set on production.
    nvr_opt=${NVR_OPT_PATH:-/opt}
    nvr_entry=$(nvr_mount_entry "$nvr_opt") || { echo unknown; return 1; }
    nvr_fs=$(printf '%s\n' "$nvr_entry" | cut -d '|' -f 3)
    case "$nvr_fs" in
        ubifs) echo internal-ubifs ;;
        ext4)  echo external-ext4 ;;
        *)     echo unknown; return 1 ;;
    esac
}

nvr_archive_mount() {
    nvr_dir=$1
    case "$nvr_dir" in /tmp/mnt/*) ;; *) return 1 ;; esac
    [ -d "$nvr_dir" ] && [ ! -L "$nvr_dir" ] || return 1
    nvr_mounts=${NVR_MOUNTS_FILE:-/proc/mounts}
    [ -r "$nvr_mounts" ] || return 1
    # An existing directory under /tmp/mnt is insufficient: exact mounted
    # block device, EXT4 and RW options are all mandatory.
    awk -v d="$nvr_dir" '
        $2==d {
            found=1
            good=($1 ~ /^\/dev\// && $3=="ext4" && $4 ~ /(^|,)rw(,|$)/)
        }
        END { exit !(found && good) }
    ' "$nvr_mounts"
}

nvr_physical_device() {
    # Partition 1 and partition 2 of the same USB disk are NOT independent.
    case "$1" in
        /dev/sd[a-z][0-9]*|/dev/hd[a-z][0-9]*|/dev/vd[a-z][0-9]*)
            printf '%s\n' "$1" | sed 's/[0-9]*$//' ;;
        /dev/mmcblk[0-9]*p[0-9]*|/dev/nvme[0-9]*n[0-9]*p[0-9]*)
            printf '%s\n' "$1" | sed 's/p[0-9]*$//' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

nvr_archive_dedicated() {
    nvr_archive_mount "$1" || return 1
    nvr_root=$1
    # Never point archives at the same physical partition as external /opt.
    nvr_opt_entry=$(nvr_mount_entry "${NVR_OPT_PATH:-/opt}") || return 1
    nvr_archive_entry=$(nvr_mount_entry "$nvr_root") || return 1
    nvr_opt_source=$(printf '%s\n' "$nvr_opt_entry" | cut -d '|' -f 1)
    nvr_archive_source=$(printf '%s\n' "$nvr_archive_entry" | cut -d '|' -f 1)
    [ "$nvr_opt_source" != "$nvr_archive_source" ] || return 1
    [ "$(nvr_physical_device "$nvr_opt_source")" != "$(nvr_physical_device "$nvr_archive_source")" ] || return 1
}

nvr_archive_safe() {
    nvr_archive_dedicated "$1" || return 1
    nvr_root=$1
    nvr_base=$2
    [ -d "$nvr_base" ] && [ ! -L "$nvr_base" ] || return 1
    nvr_real_root=$(readlink -f "$nvr_root" 2>/dev/null) || return 1
    nvr_real_base=$(readlink -f "$nvr_base" 2>/dev/null) || return 1
    case "$nvr_real_base" in "$nvr_real_root"/*) ;; *) return 1 ;; esac
    # Reject nested mounts and symlinked archive state/camera folders that
    # could route high-frequency writes to NAND outside the USB archive.
    nvr_base_entry=$(nvr_mount_entry "$nvr_base") || return 1
    nvr_root_entry=$(nvr_mount_entry "$nvr_root") || return 1
    [ "$nvr_base_entry" = "$nvr_root_entry" ] || return 1
    [ ! -L "$nvr_base/.nvr-v2" ] || return 1
    for nvr_camera_dir in "$nvr_base"/cam*; do
        [ ! -L "$nvr_camera_dir" ] || return 1
    done
}
