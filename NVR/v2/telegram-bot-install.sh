#!/bin/sh
# Install the read-only Telegram command poller alongside an existing NVR v2.4.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
RAW=${NVR_BOT_RAW_BASE:-https://raw.githubusercontent.com/saymer-alt/keenetic-knowledge-base/main/NVR/v2}
DEST=/opt/etc/nvr-telegram-bot.sh
CRON_INIT=/opt/etc/init.d/S10cron
CRON_LINE='* * * * * /bin/sh /opt/etc/nvr-telegram-bot.sh poll'
BACKUP=/opt/etc/nvr-telegram-backup
TEMP=''
cleanup() { [ -z "$TEMP" ] || rm -f "$TEMP"; }
trap cleanup EXIT
fail() { printf 'NVR Telegram install: %s\n' "$*" >&2; exit 1; }
preflight() {
    [ -r /opt/etc/nvr-v2.conf ] || fail 'NVR config missing'
    grep -q 'NVR v2.4' /opt/etc/nvr-v2.sh || fail 'NVR v2.4 required'
    . /opt/etc/nvr-v2.conf
    [ -n "${NVR_NOTIFY_TELEGRAM_TOKEN:-}" ] || fail 'First connect Telegram notifications'
    [ -n "${NVR_NOTIFY_TELEGRAM_CHAT:-}" ] || fail 'Telegram chat ID missing'
    command -v jq >/dev/null 2>&1 ||
        fail 'Missing jq; run opkg update && opkg install jq and retry'
    command -v curl >/dev/null 2>&1 || fail 'curl missing'
    [ -x "$CRON_INIT" ] || fail 'Entware cron init missing'
    crontab -l >/dev/null 2>&1 || fail 'Cannot read root crontab'
    printf 'NVR Telegram prerequisites PASS (jq, curl, existing NVR and chat).\n'
}
install_bot() {
    preflight
    TEMP=$(mktemp /opt/etc/.nvr-telegram-bot.XXXXXX) || fail 'Could not stage bot'
    curl -fSsL --connect-timeout 10 --max-time 25 "$RAW/telegram-bot.sh" -o "$TEMP" ||
        fail 'Could not fetch Telegram bot script'
    [ -s "$TEMP" ] && sh -n "$TEMP" || fail 'Downloaded bot script has syntax errors'
    chmod 700 "$TEMP"
    mkdir -p "$BACKUP"
    chmod 700 "$BACKUP"
    [ -e "$DEST" ] && cp -p "$DEST" "$BACKUP/nvr-telegram-bot.previous.sh"
    # Same-directory rename avoids a partially copied script if already scheduled.
    mv -f "$TEMP" "$DEST"
    TEMP=''
    # Import update offset before enabling minute cron. This never replies.
    if ! sh "$DEST" init; then
        if [ -f "$BACKUP/nvr-telegram-bot.previous.sh" ]; then
            cp -p "$BACKUP/nvr-telegram-bot.previous.sh" "$DEST"
        else
            rm -f "$DEST"
        fi
        fail 'Telegram getUpdates setup failed; cron left unchanged'
    fi
    # Never replace or remove another service's crontab entries.
    if ! crontab -l | grep -Fqx "$CRON_LINE"; then
        crontab -l > "$BACKUP/root-crontab.before-bot"
        TEMP=$(mktemp /tmp/nvr-telegram-cron.XXXXXX) || fail 'Cannot stage crontab'
        crontab -l > "$TEMP"
        printf '%s\n' "$CRON_LINE" >> "$TEMP"
        crontab "$TEMP" || fail 'Could not add bot cron entry'
        "$CRON_INIT" restart || fail 'Cron restart failed'
    fi
    printf 'Read-only Telegram commands installed. Try /status in your bot in 1 minute.\n'
    sh "$DEST" status
}
remove_bot() {
    TEMP=$(mktemp /tmp/nvr-telegram-cron.XXXXXX) || fail 'Cannot stage crontab'
    crontab -l | grep -Fvx "$CRON_LINE" > "$TEMP" || :
    crontab "$TEMP" || fail 'Cannot remove Telegram poller from crontab'
    "$CRON_INIT" restart || fail 'Cron restart failed'
    rm -f "$DEST"
    printf 'Telegram command poller disabled; normal NVR alerts remain enabled.\n'
}
case ${1:-} in
    preflight) preflight ;;
    install) install_bot ;;
    remove) remove_bot ;;
    status)
        if [ -f "$DEST" ]; then sh "$DEST" status
        else printf 'Telegram command poller is not installed.\n'; fi
        ;;
    *) printf 'Usage: telegram-bot-install.sh {preflight|install|remove|status}\n' >&2; exit 2 ;;
esac
