#!/bin/sh
# Offline Telegram command acceptance/auth/replay test with fake Bot API.
set -eu
cd "$(dirname "$0")/.."
busybox sh -n NVR/v2/telegram-bot.sh
busybox sh -n NVR/v2/telegram-bot-install.sh
mkdir -p /tmp/mnt
T=$(mktemp -d /tmp/mnt/nvr-telegram-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state" "$T/bin" "$T/usb/cctv" "$T/internal/opt"
printf '/dev/ubi0_0 %s ubifs rw,relatime 0 0\n/dev/sda1 %s ext4 rw,relatime 0 0\n' "$T/internal" "$T/usb" > "$T/mounts"
cat > "$T/conf" <<EOT
NVR_NOTIFY_TELEGRAM_TOKEN='123456:test-only'
NVR_NOTIFY_TELEGRAM_CHAT='42'
NVR_MOUNT='$T/usb'
NVR_BASE_DIR='$T/usb/cctv'
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
export NVR_STORAGE_GUARD="$PWD/NVR/v2/storage-guard.sh"
export NVR_OPT_PATH="$T/internal/opt"
export NVR_MOUNTS_FILE="$T/mounts"
export NVR_BOT_CURL="$T/bin/fakecurl"
export NVR_TEST_UPDATES="$T/updates"
export NVR_TEST_SENDS="$T/sends"

# Simulate an acknowledged offset persisted by an older installation.
printf '101\n' > "$T/state/offset"
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

# A missing USB mount must fail closed without accepting/acknowledging updates.
printf '/dev/ubi0_0 %s ubifs rw,relatime 0 0\n' "$T/internal" > "$T/mounts"
prior=$(cat "$T/state/offset")
if busybox sh NVR/v2/telegram-bot.sh poll >/dev/null 2>&1; then
  echo 'FAIL: Telegram poll accepted an absent USB archive' >&2; exit 1
fi
[ "$(cat "$T/state/offset")" = "$prior" ]
# Internal-UBIFS default state must be created on the external archive, never /opt.
printf '/dev/ubi0_0 %s ubifs rw,relatime 0 0\n/dev/sda1 %s ext4 rw,relatime 0 0\n' "$T/internal" "$T/usb" > "$T/mounts"
unset NVR_BOT_STATE_DIR
busybox sh NVR/v2/telegram-bot.sh init
[ -f "$T/usb/cctv/.nvr-v2/telegram/offset" ]
# A symlink placed under external .nvr-v2 may target internal NAND:
# never follow it, even with a valid EXT4 archive mount.
mv "$T/usb/cctv/.nvr-v2/telegram" "$T/usb/cctv/.nvr-v2/telegram.saved"
ln -s "$T/internal" "$T/usb/cctv/.nvr-v2/telegram"
if busybox sh NVR/v2/telegram-bot.sh poll >/dev/null 2>&1; then
    echo 'FAIL: followed Telegram state symlink into simulated NAND' >&2; exit 1
fi
[ ! -f "$T/internal/offset" ] ||
    { echo 'FAIL: wrote Telegram offset into simulated NAND' >&2; exit 1; }
rm "$T/usb/cctv/.nvr-v2/telegram"
mv "$T/usb/cctv/.nvr-v2/telegram.saved" "$T/usb/cctv/.nvr-v2/telegram"
echo 'Telegram bot commands PASS (auth, status, disk, offset, init, replay, NAND, USB loss, symlink)'
