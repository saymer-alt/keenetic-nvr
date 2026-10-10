#!/bin/sh
# Offline Telegram command acceptance/auth/replay test with fake Bot API.
set -eu
cd "$(dirname "$0")/.."
busybox sh -n NVR/v2/telegram-bot.sh
busybox sh -n NVR/v2/telegram-bot-install.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/bin"
cat > "$T/conf" <<'EOT'
NVR_NOTIFY_TELEGRAM_TOKEN='123456:test-only'
NVR_NOTIFY_TELEGRAM_CHAT='42'
EOT
cat > "$T/nvr" <<'EOT'
#!/bin/sh
cat <<'REPORT'
NVR v2.4 - HEALTHY
DISK: RW, 21% used, 486.9 GB free
RETENTION: 72 hours
LAST CHECK: 2026-10-10 15:25:01
LAST CLEANUP: 2026-10-10 15:03:01 OK
LAST SUCCESSFUL CLEANUP: 2026-10-10 15:03:01
CAM 101: HEALTHY, last write 2s ago
CAM 201: HEALTHY, last write 4s ago
CAM 301: HEALTHY, last write 2s ago
ALERTS: enabled
REPORT
EOT
chmod 700 "$T/nvr"
cat > "$T/bin/fakecurl" <<'EOT'
#!/bin/sh
config=$(cat)
case $config in
    *getUpdates*)
        cat "$NVR_TEST_UPDATES"
        ;;
    *sendMessage*)
        file=$(printf '%s\n' "$config" | sed -n 's/^data-binary = "@\(.*\)"$/\1/p')
        [ -f "$file" ] || exit 14
        cat "$file" >> "$NVR_TEST_SENDS"
        printf '\n' >> "$NVR_TEST_SENDS"
        printf '{"ok":true,"result":{}}'
        ;;
    *) exit 15 ;;
esac
EOT
chmod 700 "$T/bin/fakecurl"
# Only the private chat ID 42, real sender 42, can request data.
cat > "$T/updates" <<'EOT'
{"ok":true,"result":[
 {"update_id":101,"message":{"chat":{"id":999,"type":"private"},"from":{"id":999},"text":"/status"}},
 {"update_id":102,"message":{"chat":{"id":42,"type":"private"},"from":{"id":42},"text":"/status"}},
 {"update_id":103,"message":{"chat":{"id":42,"type":"private"},"from":{"id":99},"text":"/status"}},
 {"update_id":104,"message":{"chat":{"id":42,"type":"group"},"from":{"id":42},"text":"/status"}},
 {"update_id":105,"message":{"chat":{"id":42,"type":"private"},"from":{"id":42},"text":"/disk"}}
]}
EOT
export NVR_CONFIG="$T/conf"
export NVR_BIN="$T/nvr"
export NVR_BOT_STATE_DIR="$T/state"
export NVR_BOT_CURL="$T/bin/fakecurl"
export NVR_TEST_UPDATES="$T/updates"
export NVR_TEST_SENDS="$T/sends"

busybox sh NVR/v2/telegram-bot.sh poll
[ "$(cat "$T/state/offset")" = 106 ]
[ -f "$T/state/last_poll" ]
[ "$(grep -Ec '"chat_id"[[:space:]]*:[[:space:]]*"42"' "$T/sends")" -eq 2 ]
grep -q 'CAM 101: HEALTHY' "$T/sends"
grep -q 'LAST CLEANUP' "$T/sends"
if grep -Eq '"chat_id"[[:space:]]*:[[:space:]]*"999"' "$T/sends"; then
  echo 'FAIL unauthorized chat received a reply' >&2; exit 1
fi
# No duplicate sends if poll sees already consumed updates again.
before=$(wc -l < "$T/sends")
busybox sh NVR/v2/telegram-bot.sh poll
[ "$(wc -l < "$T/sends")" -eq "$before" ]

# Fresh installation must skip old messages without answering.
rm -rf "$T/state"
mkdir -p "$T/state"
busybox sh NVR/v2/telegram-bot.sh init
[ "$(cat "$T/state/offset")" = 106 ]
[ "$(wc -l < "$T/sends")" -eq "$before" ]
busybox sh NVR/v2/telegram-bot.sh poll
[ "$(wc -l < "$T/sends")" -eq "$before" ]

echo 'Telegram bot commands PASS (auth, status, disk, offset, init, replay)'
