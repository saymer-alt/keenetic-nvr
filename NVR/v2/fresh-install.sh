#!/bin/sh
# First-time Keenetic/Entware installation. Credentials never leave the router.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
HERE=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SOURCE="$HERE/nvr.sh"
RECORDER=/opt/etc/nvr-v2.sh
CONFIG=/opt/etc/nvr-v2.conf
CRON=/opt/etc/init.d/S10cron
OPKG=/opt/bin/opkg
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
number() { case ${1:-} in ''|*[!0-9]*) return 1;; esac; }

# Parse a v2.4 status line: "CAM <id>: HEALTHY, last write <n>s ago".
status_cam_age() {
    id=$1; output=$2
    line=$(printf '%s\n' "$output" | grep "^CAM $id: HEALTHY, last write [0-9][0-9]*s ago\$" || :)
    [ -n "$line" ] || return 1
    age=${line##*last write }
    age=${age%s ago}
    case "$age" in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$age"
}
missing_deps() {
    need=''
    [ -x /opt/bin/ffmpeg ] || need="$need ffmpeg"
    { [ -x /opt/sbin/cron ] && [ -x "$CRON" ]; } || need="$need cron"
    command -v curl >/dev/null 2>&1 || need="$need curl"
    if ! command -v stat >/dev/null 2>&1; then need="$need coreutils-stat"
    else
        stat -c %Y "$SOURCE" >/dev/null 2>&1 || need="$need coreutils-stat"
    fi
    printf '%s' "$need"
}
prerequisites() {
    [ -r "$SOURCE" ] && sh -n "$SOURCE" || fail 'Missing or invalid nvr.sh'
    need=$(missing_deps)
    if [ -n "$need" ]; then
        printf 'Missing Entware packages:%s\n' "$need" > /dev/tty
        printf 'Install them now with opkg? [y/N]: ' > /dev/tty
        IFS= read -r answer < /dev/tty || fail 'Input cancelled'
        case $answer in y|Y|yes|YES)
            [ -x "$OPKG" ] || fail "opkg missing at $OPKG; install packages manually"
            opkg update || fail 'opkg update failed; check Entware feed and disk'
            opkg install $need || fail 'opkg install failed; install packages manually and retry'
            need=$(missing_deps)
            [ -z "$need" ] || fail "Still missing:$need; install manually and retry"
            ;;
        *) fail "Install missing packages:$need; then re-run";; esac
    fi
    /opt/bin/ffmpeg -hide_banner -h demuxer=rtsp 2>&1 | grep -q -- '-timeout ' || fail 'FFmpeg RTSP -timeout unsupported'
    [ ! -e /opt/etc/init.d/S99cctv ] && [ ! -e /tmp/cctv_is_running ] || fail 'Legacy NVR found: use preflight/switch instead of install-fresh'
    printf 'Fresh preflight PASS: FFmpeg, cron, curl, stat available; no legacy NVR.\n'
}
quote_sh() {
    # Store untrusted single-line credentials as safely quoted POSIX shell literals.
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}
ask() {
    printf '%s' "$1" > /dev/tty
    IFS= read -r answer < /dev/tty || fail 'Input cancelled'
}
ask_secret() {
    # Hidden single-line input; empty input allowed only with ALLOW_EMPTY=1.
    [ -r /dev/tty ] && [ -w /dev/tty ] || fail 'Interactive SSH terminal required (ssh -t)'
    printf '%s' "$1" > /dev/tty
    tty_state=$(stty -g < /dev/tty) || fail 'Unable to configure terminal'
    stty -echo < /dev/tty || fail 'Unable to hide input'
    trap 'stty "$tty_state" < /dev/tty 2>/dev/null || :' EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    if IFS= read -r answer < /dev/tty; then secret=$answer; else fail 'Input cancelled'; fi
    stty "$tty_state" < /dev/tty
    trap - EXIT INT HUP TERM
    printf '\n' > /dev/tty
    if [ -z "$secret" ] && [ "${ALLOW_EMPTY:-0}" != 1 ]; then
        fail 'Empty input is not allowed here'
    fi
}
configured_mount() {
    awk -v d="$1" '$2==d && $4 ~ /(^|,)rw(,|$)/ {ok=1} END{exit !ok}' /proc/mounts
}
# Characters that must survive RTSP userinfo only when percent-encoded; the
# installer verifies live which variant the camera accepts.
has_unsafe_url_chars() {
    # grep keeps the character class free of shell expansion pitfalls.
    printf '%s' "$1" | grep -q '[^A-Za-z0-9._%~!$&()*+,;=-]'
}
pick_mount() {
    printf '\nExternal USB mounts that are mounted read-write:\n' > /dev/tty
    i=1; list=''
    for m in $(awk '$2 ~ /^\/tmp\/mnt\// && $4 ~ /(^|,)rw(,|$)/ {print $2}' /proc/mounts); do
        printf '  %d) %s\n' "$i" "$m" > /dev/tty
        list="$list $m"
        i=$((i+1))
    done
    [ "$list" != '' ] || fail 'No external USB mounts found; connect an EXT4 USB disk and retry'
    ask 'Choose mount by number, or type the /tmp/mnt/... path: '
    case $answer in
        *[!0-9]*) mount_path=$answer ;;
        *)
            picked=''
            j=1
            for m in $list; do
                [ "$j" = "$answer" ] && picked=$m
                j=$((j+1))
            done
            [ -n "$picked" ] || fail 'No such mount number'
            mount_path=$picked ;;
    esac
    case "$mount_path" in /tmp/mnt/*) ;; *) fail 'Only external /tmp/mnt/ paths are supported';; esac
    case "$mount_path" in *' '*|*'..'*) fail 'Mount path contains unsupported characters';; esac
    configured_mount "$mount_path" || fail 'USB disk is not mounted read-write'
    # The Entware system disk must not hold the video archive.
    opt_real=$(readlink -f /opt 2>/dev/null || :)
    case "$opt_real" in
        "$mount_path"|"$mount_path"/*) fail 'This mount hosts /opt (Entware system). Choose a dedicated archive disk';;
    esac
}
configure_notifications() {
    ask 'Configure notifications now (Telegram/webhook)? [y/N]: '
    case $answer in y|Y|yes|YES) ;;
        *) return 0;;
    esac
    ALLOW_EMPTY=1
    ask_secret 'Telegram bot token (hidden, empty to skip): '
    tg_token=$secret
    tg_chat=''
    if [ -n "$tg_token" ]; then
        ask 'Telegram chat ID (numeric or @channel): '
        tg_chat=$answer
        case $tg_chat in -?[0-9]*|@*) ;; *) fail 'Chat ID must be numeric or @channel';; esac
    fi
    ask_secret 'Webhook URL, http(s), (hidden, empty to skip): '
    webhook=$secret
    ALLOW_EMPTY=0
    case $webhook in ''|http://*|https://*) ;; *) fail 'Webhook URL must start with http:// or https://';; esac
    if [ -n "$tg_token" ] || [ -n "$webhook" ]; then
        {
            [ -z "$tg_token" ] || { printf 'NVR_NOTIFY_TELEGRAM_TOKEN='; quote_sh "$tg_token"; printf '\n'; }
            [ -z "$tg_chat" ] || { printf 'NVR_NOTIFY_TELEGRAM_CHAT='; quote_sh "$tg_chat"; printf '\n'; }
            [ -z "$webhook" ] || { printf 'NVR_NOTIFY_WEBHOOK_URL='; quote_sh "$webhook"; printf '\n'; }
        } >> "$temp"
        unset tg_token tg_chat webhook secret
        printf 'Notification settings saved into the local config (mode 600).\n' > /dev/tty
        printf 'After installation verify with: sh %s notify test\n' "$RECORDER" > /dev/tty
    fi
}
configure() {
    [ -r /dev/tty ] && [ -w /dev/tty ] || fail 'Run through interactive SSH with TTY'
    if [ -e "$CONFIG" ]; then
        for pidfile in /tmp/nvr-v2/cam*.pid; do
            [ -f "$pidfile" ] || continue
            pid=$(cat "$pidfile" 2>/dev/null || :)
            case "$pid" in ''|*[!0-9]*) continue;; esac
            if kill -0 "$pid" 2>/dev/null; then
                fail 'Stop v2 recorder before changing credentials: sh /opt/etc/nvr-v2.sh stop'
            fi
        done
        ask 'Local config already exists. Replace it? [type YES]: '
        [ "$answer" = YES ] || fail 'No changes to existing config'
    fi
    pick_mount
    ask 'RTSP IP/hostname (one recorder/source): '
    host=$answer
    case "$host" in ''|*[!a-zA-Z0-9.-]*) fail 'Expected IPv4 address or DNS hostname without URL/port';; esac
    ask 'RTSP username: '
    username=$answer
    [ -n "$username" ] || fail 'Empty username is not allowed'
    ask_secret 'RTSP password (input hidden): '
    password=$secret
    ask 'RTSP channel IDs, space-separated [101 201 301]: '
    channels=${answer:-101 201 301}
    seen=' '
    for id in $channels; do
        number "$id" || fail 'Channel IDs must be numeric'
        case "$seen" in *" $id "*) fail "Duplicate channel: $id";; esac
        seen="$seen$id "
    done
    [ "$seen" != ' ' ] || fail 'At least one channel required'
    temp=$(mktemp /opt/etc/.nvr-v2.conf.XXXXXX) || fail 'Cannot create temporary config'
    trap 'rm -f "$temp"' EXIT HUP INT TERM
    {
        printf 'NVR_MOUNT='; quote_sh "$mount_path"; printf '\n'
        printf 'NVR_BASE_DIR='; quote_sh "$mount_path/cctv"; printf '\n'
        printf 'RTSP_IP='; quote_sh "$host"; printf '\n'
        printf 'RTSP_USER='; quote_sh "$username"; printf '\n'
        printf 'RTSP_PASS='; quote_sh "$password"; printf '\n'
        printf 'NVR_CAMERAS='; quote_sh "$channels"; printf '\n'
        printf 'NVR_RETENTION_SECONDS=259200\nNVR_DISK_WARN_PERCENT=75\nNVR_DISK_CRIT_PERCENT=90\n'
    } > "$temp"
    chmod 600 "$temp"
    sh -n "$temp" || fail 'Generated config has invalid syntax'
    if has_unsafe_url_chars "$username" || has_unsafe_url_chars "$password"; then
        printf 'Credentials contain URL-special characters; the installer will verify\n' > /dev/tty
        printf 'both raw and percent-encoded RTSP URLs and keep the working one.\n' > /dev/tty
    fi
    configure_notifications
    mkdir -p "$mount_path/cctv"
    for id in $channels; do mkdir -p "$mount_path/cctv/cam$id"; done
    mv -f "$temp" "$CONFIG"
    trap - EXIT HUP INT TERM
    unset password answer secret
    printf 'Local configuration saved at %s (mode 600). Password not displayed.\n' "$CONFIG"
}
check_config() {
    [ -r "$CONFIG" ] && [ -f "$RECORDER" ] || fail 'Local config or recorder missing'
    sh -n "$CONFIG" || fail 'Invalid local config'
    . "$CONFIG"
    configured_mount "$NVR_MOUNT" || fail 'Configured disk not mounted read-write'
}
verify_video() {
    count=0
    while [ "$count" -lt 12 ]; do
        good=1
        result=$(sh "$RECORDER" status) || good=0
        for id in $NVR_CAMERAS; do
            age=$(status_cam_age "$id" "$result") || { good=0; continue; }
            [ "$age" -lt 60 ] || good=0
        done
        [ "$good" -eq 1 ] && return 0
        count=$((count+1))
        [ "$count" -ge 12 ] || sleep 5
    done
    printf '%s\n' "$result" >&2
    return 1
}
# The camera decides whether it wants raw or percent-encoded userinfo, so both
# variants are tried when credentials contain URL-special characters.
verify_with_encoding_fallback() {
    if verify_video; then return 0; fi
    if [ "${NVR_RTSP_ENCODE:-0}" = 0 ] && \
       { has_unsafe_url_chars "$RTSP_USER" || has_unsafe_url_chars "$RTSP_PASS"; }; then
        printf 'Raw RTSP URL failed; retrying with percent-encoded credentials...\n'
        sh "$RECORDER" stop || :
        sed -i 's/^NVR_RTSP_ENCODE=.*/NVR_RTSP_ENCODE=1/' "$CONFIG"
        grep -q '^NVR_RTSP_ENCODE=' "$CONFIG" || printf 'NVR_RTSP_ENCODE=1\n' >> "$CONFIG"
        . "$CONFIG"
        sh "$RECORDER" start || return 1
        if verify_video; then
            printf 'Percent-encoded credentials confirmed working.\n'
            return 0
        fi
    fi
    return 1
}
schedule() {
    tempfile=$(mktemp /tmp/nvr-fresh-cron.XXXXXX) || fail 'Cannot create cron temp file'
    trap 'rm -f "$tempfile"' EXIT HUP INT TERM
    oldcron=$(mktemp /tmp/nvr-fresh-oldcron.XXXXXX) || fail 'Cannot create cron backup temp file'
    if crontab -l > "$oldcron" 2>"$tempfile.err"; then
        :
    elif grep -qi 'no crontab' "$tempfile.err"; then
        :
    else
        fail 'Cannot read existing root crontab; refusing to overwrite other jobs'
    fi
    sed '/\/opt\/etc\/nvr-v2\.sh check/d; /\/opt\/etc\/nvr-v2\.sh cleanup/d' "$oldcron" > "$tempfile"
    rm -f "$oldcron" "$tempfile.err"
    printf '\n*/5 * * * * /bin/sh /opt/etc/nvr-v2.sh check\n' >> "$tempfile"
    printf '3 * * * * /bin/sh /opt/etc/nvr-v2.sh cleanup\n' >> "$tempfile"
    crontab "$tempfile" || fail 'Unable to install cron'
    "$CRON" restart || fail 'Unable to restart cron'
    rm -f "$tempfile"
    trap - EXIT HUP INT TERM
}
install_fresh() {
    prerequisites
    [ -e "$RECORDER" ] && [ ! -e "$CONFIG" ] && fail 'Recorder exists without config; inspect manually'
    if [ ! -e "$CONFIG" ]; then configure; fi
    cp "$SOURCE" "$RECORDER"
    chmod 700 "$RECORDER"
    check_config
    sh "$RECORDER" start || fail 'NVR start failed; cron unchanged'
    if ! verify_with_encoding_fallback; then
        sh "$RECORDER" stop || :
        printf 'Video verification failed; cron not added, recorder stopped.\n' >&2
        printf 'Inspect local FFmpeg logs and retry; config kept at %s\n' "$CONFIG" >&2
        exit 1
    fi
    schedule
    printf '\nFresh NVR installation PASS. Cron configured.\n'
    sh "$RECORDER" status
    printf '\nCheck notifications with: sh %s notify test\n' "$RECORDER"
}
case ${1:-} in
    preflight-fresh) prerequisites ;;
    install-fresh) install_fresh ;;
    configure-fresh) prerequisites; configure ;;
    *) echo 'Usage: fresh-install.sh {preflight-fresh|install-fresh|configure-fresh}' >&2; exit 2;;
esac
