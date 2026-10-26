#!/bin/sh
# Isolated prefix + crontab backend; no host /opt or live archive is touched.
# Catches deletion of archive/config, broad cron removal and false success on stop failure.
set -eu
cd "$(dirname "$0")/.."
T=$(mktemp -d /tmp/knvr-remove-test.XXXXXX)
trap 'rm -rf "$T"' EXIT HUP INT TERM
export NVR_UNINSTALL_OPT="$T/opt" NVR_UNINSTALL_CRONTAB="$T/crontab"
mkdir -p "$T/opt/etc" "$T/archive/cam101"
printf 'keep-video\n' > "$T/archive/cam101/test.mkv"
printf 'NVR_BASE_DIR=%s\n' "'$T/archive'" > "$T/opt/etc/nvr-v2.conf"
cp "$T/opt/etc/nvr-v2.conf" "$T/config.before"
cat > "$T/crontab" <<'CRON'
#!/bin/sh
case "$1" in
-l) cat "$NVR_UNINSTALL_OPT/cron";;
*) [ "${FAIL_CRON:-0}" != 1 ] || exit 1; cp "$1" "$NVR_UNINSTALL_OPT/cron";;
esac
CRON
chmod +x "$T/crontab"
cat > "$T/opt/cron" <<'CRON'
# comment mentioning /opt/etc/nvr-v2.sh check must survive
*/5 * * * * /bin/sh /opt/etc/nvr-v2.sh check
3 * * * * /bin/sh /opt/etc/nvr-v2.sh cleanup
* * * * * /bin/sh /opt/etc/nvr-telegram-bot.sh poll
0 * * * * /bin/sh /opt/etc/foreign-nvr-v2.sh check
0 * * * * echo '/opt/etc/nvr-v2.sh check'
CRON
# Paths in the test crontab describe the selected isolated install prefix.
sed "s|/opt/etc/|$T/opt/etc/|g" "$T/opt/cron" > "$T/cron.full"
cp "$T/cron.full" "$T/opt/cron"
grep -E '^#|foreign-nvr|echo' "$T/opt/cron" > "$T/cron.keep"
cat > "$T/opt/etc/nvr-v2.sh" <<'REC'
#!/bin/sh
[ "$1" = stop ] || exit 2
[ "${FAIL_STOP:-0}" != 1 ] || exit 1
REC
cp "$T/opt/etc/nvr-v2.sh" "$T/recorder"
printf '# bot\n' > "$T/opt/etc/nvr-telegram-bot.sh"
printf '# guard\n' > "$T/opt/etc/nvr-storage-guard.sh"
# Default requires confirmation and cancellation makes no changes.
printf 'NO\n' | sh uninstall.sh > "$T/cancel"
[ -f "$T/opt/etc/nvr-v2.sh" ]; cmp "$T/cron.full" "$T/opt/cron"
# A failed cron write must not stop or remove program files.
if FAIL_CRON=1 sh uninstall.sh --yes > "$T/fail-cron" 2>&1; then exit 1; fi
[ -f "$T/opt/etc/nvr-v2.sh" ]; cmp "$T/cron.full" "$T/opt/cron"
# A failed stop leaves scripts/config available to retry, but scheduler disabled.
if FAIL_STOP=1 sh uninstall.sh --yes > "$T/fail-stop" 2>&1; then exit 1; fi
grep -q PARTIAL "$T/fail-stop"
[ -f "$T/opt/etc/nvr-v2.sh" ]; cmp "$T/cron.keep" "$T/opt/cron"
sh uninstall.sh --yes > "$T/removed"
grep -q SUCCESS "$T/removed"
for f in nvr-v2.sh nvr-telegram-bot.sh nvr-storage-guard.sh; do [ ! -e "$T/opt/etc/$f" ]; done
cmp "$T/config.before" "$T/opt/etc/nvr-v2.conf"
[ "$(cat "$T/archive/cam101/test.mkv")" = keep-video ]
cmp "$T/cron.keep" "$T/opt/cron"
sh uninstall.sh --yes > "$T/repeated"
grep -q SUCCESS "$T/repeated"
# Reinstall then remove again.
cp "$T/recorder" "$T/opt/etc/nvr-v2.sh"
sh uninstall.sh --yes > /dev/null
# Never execute a symlinked recorder or erase its target.
ln -s "$T/recorder" "$T/opt/etc/nvr-v2.sh"
if sh uninstall.sh --yes > "$T/symlink" 2>&1; then exit 1; fi
[ -f "$T/recorder" ]; [ -L "$T/opt/etc/nvr-v2.sh" ]
printf 'KNVR uninstall lifecycle PASS\n'
