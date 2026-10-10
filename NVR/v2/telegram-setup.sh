#!/bin/sh
# Configure Telegram on existing Keenetic NVR v2.4 without exposing tokens.
set -eu
umask 077
PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin
CONF=/opt/etc/nvr-v2.conf
TMP=''
SAVED_TTY=''

cleanup() {
    if [ -n "$SAVED_TTY" ]; then stty "$SAVED_TTY" </dev/tty 2>/dev/null || :; fi
    if [ -n "$TMP" ]; then rm -f "$TMP"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ -f "$CONF" ] || fail 'NVR config not found; install NVR v2.4 first'
grep -q 'NVR v2.4' /opt/etc/nvr-v2.sh || fail 'NVR v2.4 is not installed'
command -v curl >/dev/null 2>&1 || fail 'curl not installed'
SAVED_TTY=$(stty -g </dev/tty) || fail 'This installer needs an interactive SSH TTY'

printf 'Open your new Telegram bot, press Start, send /start and a test message.\n' >/dev/tty
printf 'Paste only the BotFather API token (hidden input): ' >/dev/tty
stty -echo </dev/tty
IFS= read -r TOKEN </dev/tty || fail 'Could not read token'
stty "$SAVED_TTY" </dev/tty
printf '\n' >/dev/tty

case $TOKEN in *:*) : ;; *) fail 'Not a bot token. Copy the API token, not @username or bot link' ;; esac
ID=${TOKEN%%:*}
KEY=${TOKEN#*:}
case $ID in ''|*[!0-9]*) fail 'Invalid token prefix; expected digits before the colon' ;; esac
case $KEY in ''|*[!A-Za-z0-9_-]*) fail 'Token contains invalid characters. Copy only the BotFather API token' ;; esac

# All bot API calls keep the token in curl stdin, never command arguments.
BOT=$(printf 'silent\nurl = "https://api.telegram.org/bot%s/getMe"\n' "$TOKEN" |
    curl -K - -fSs --connect-timeout 10 --max-time 20) ||
    fail 'getMe failed: invalid token or Telegram unreachable'
printf '%s' "$BOT" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' ||
    fail 'getMe did not confirm the bot token'
BOT_NAME=$(printf '%s' "$BOT" |
    grep -oE '"username"[[:space:]]*:[[:space:]]*"[^"]+"' |
    head -n 1 | cut -d '"' -f 4) || :
[ -n "$BOT_NAME" ] || fail 'Could not read bot username from getMe'
printf 'Token belongs to Telegram bot: @%s\n' "$BOT_NAME" >/dev/tty
printf 'Check that this is the SAME bot you sent /start to.\n' >/dev/tty

# getUpdates may be empty if the token belongs to a different bot, another
# client consumes updates, or the bot has a webhook. None is a recorder error.
get_chat_id() {
    CHAT=''
    UPDATES=$(printf 'silent\nurl = "https://api.telegram.org/bot%s/getUpdates"\n' "$TOKEN" |
        curl -K - -fSs --connect-timeout 10 --max-time 20) || return 1
    printf '%s' "$UPDATES" | grep -q '"ok"[[:space:]]*:[[:space:]]*true' || return 1
    CHAT=$(printf '%s' "$UPDATES" | tr '\n' ' ' |
        grep -oE '"chat"[[:space:]]*:[[:space:]]*\{[^}]*\}' |
        grep -oE '"id"[[:space:]]*:[[:space:]]*-?[0-9]+' |
        tail -n 1 | sed 's/.*:[[:space:]]*//') || :
    [ -n "$CHAT" ]
}
if ! get_chat_id; then
    printf 'No chat ID in getUpdates for @%s.\n' "$BOT_NAME" >/dev/tty
    printf 'Send a NEW message (for example: nvr test) to @%s, then press Enter here: ' "$BOT_NAME" >/dev/tty
    IFS= read -r RETRY </dev/tty || fail 'Input interrupted'
    get_chat_id || :
fi
if [ -z "$CHAT" ]; then
    printf 'Still no updates. Another client may consume them, or a webhook is active.\n' >/dev/tty
    printf 'Enter your numeric Telegram Chat ID manually (Enter cancels): ' >/dev/tty
    IFS= read -r CHAT </dev/tty || fail 'Input interrupted'
fi
case $CHAT in -*) CHAT_DIGITS=${CHAT#-} ;; *) CHAT_DIGITS=$CHAT ;; esac
case $CHAT_DIGITS in ''|*[!0-9]*) fail 'Chat ID missing or invalid; original config unchanged' ;; esac
printf 'Telegram Chat ID: %s\n' "$CHAT" >/dev/tty
printf 'Use this Chat ID? [y/N] ' >/dev/tty
IFS= read -r OK </dev/tty || fail 'Confirmation not received'
case $OK in y|Y) : ;; *) fail 'Cancelled, original config unchanged' ;; esac

TMP=$(mktemp /opt/etc/.nvr-v2.conf.XXXXXX) || fail 'Cannot create temporary config'
sed '/^NVR_NOTIFY_TELEGRAM_TOKEN=/d; /^NVR_NOTIFY_TELEGRAM_CHAT=/d' "$CONF" >"$TMP"
printf "\nNVR_NOTIFY_TELEGRAM_TOKEN='%s'\nNVR_NOTIFY_TELEGRAM_CHAT='%s'\n" "$TOKEN" "$CHAT" >>"$TMP"
chmod 600 "$TMP"
sh -n "$TMP" || fail 'Generated configuration is invalid'
BACKUP=$(mktemp /opt/etc/.nvr-v2.conf.pre-telegram.XXXXXX) || fail 'Cannot back up configuration'
cp -p "$CONF" "$BACKUP" || fail 'Cannot back up existing config'
chmod 600 "$BACKUP"
mv -f "$TMP" "$CONF"
TMP=''
unset TOKEN KEY ID BOT BOT_NAME UPDATES CHAT_DIGITS RETRY
printf 'Telegram settings saved in local NVR config (mode 600).\n'
sh /opt/etc/nvr-v2.sh notify test || fail 'Config saved but test delivery failed; inspect bot and WAN'
sh /opt/etc/nvr-v2.sh status
