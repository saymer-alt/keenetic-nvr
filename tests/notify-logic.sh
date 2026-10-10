#!/bin/sh
# Offline notification logic: dedup, recovery gating, escalation, encoders.
# No network is used: curl is replaced by a fake that logs requests.
set -eu
cd "$(dirname "$0")/.."
busybox sh -n NVR/v2/nvr.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
M="$T/mount"
mkdir -p "$M/cctv" "$T/state" "$T/bin"

cat > "$T/bin/fakecurl" <<EOF
#!/bin/sh
# Reads the curl config from stdin (-K -); records the target host per call.
while IFS= read -r line; do
  case \$line in
    url\ =\ \"*api.telegram.org*) echo telegram >> "$T/sends" ;;
    url\ =\ \"*webhook.invalid*) echo webhook >> "$T/sends" ;;
  esac
done
[ "\${NVR_TEST_CURL_FAIL:-0}" = 1 ] && exit 7
printf '200'
EOF
chmod +x "$T/bin/fakecurl"

cat > "$T/conf" <<EOT
NVR_MOUNT='$M'
NVR_BASE_DIR='$M/cctv'
RTSP_USER='dummy'
RTSP_PASS='test-only-secret'
RTSP_IP='192.0.2.1'
NVR_STATE_DIR='$T/state'
NVR_MOUNTS_FILE='$T/mounts'
NVR_CAMERAS='101'
NVR_STALE_SECONDS=120
NVR_GRACE_SECONDS=0
NVR_RETENTION_SECONDS=259200
NVR_DISK_WARN_PERCENT=75
NVR_DISK_CRIT_PERCENT=90
NVR_NOTIFY_TELEGRAM_TOKEN='123456789:test-only-token-aaaaaaaaaaaaaaaaaaaaa'
NVR_NOTIFY_TELEGRAM_CHAT='42'
NVR_NOTIFY_WEBHOOK_URL='https://webhook.invalid/nvr'
NVR_NOTIFY_REPEAT_SECONDS=21600
NVR_CURL='$T/bin/fakecurl'
EOT
printf '/dev/mock %s ext4 rw,relatime 0 0\n' "$M" > "$T/mounts"

sends() { [ -f "$T/sends" ] && wc -l < "$T/sends" | tr -d ' ' || echo 0; }

# Load nvr.sh as a function library; nothing is executed in lib mode.
# Each scenario runs in its own child shell so environment overrides stay clean.
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 busybox sh -c '
  . ./NVR/v2/nvr.sh
  notify_event WARN disk-warn "first"
  notify_event WARN disk-warn "second within repeat window"
  notify_event RECOVERY disk-warn "confirmed back"
  notify_event RECOVERY disk-warn "duplicate recovery"
  notify_event WARN cam101 "camera down"
'
# Delivery failure keeps the incident open and records the attempt time.
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 NVR_TEST_CURL_FAIL=1 busybox sh -c '
  . ./NVR/v2/nvr.sh
  notify_event ERROR cam202 "send fails, incident stays open"
'
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 busybox sh -c '
  . ./NVR/v2/nvr.sh
  notify_event ERROR cam202 "still suppressed by recorded attempt"
  notify_event ERROR cam101 "escalation" 1
'
# Every counted event delivers to both transports (telegram + webhook):
# 5 successful events x 2 = 10 lines; the failed attempt is also logged.
[ "$(sends)" -eq 10 ] || { echo "FAIL expected 10 deliveries, got $(sends)" >&2; exit 1; }
grep -q '^disk-warn closed' "$T/state/notify.state" || { echo 'FAIL disk-warn must be closed after recovery' >&2; exit 1; }
grep -q '^cam202 open' "$T/state/notify.state" || { echo 'FAIL cam202 must stay open after failed delivery' >&2; exit 1; }

# 2) Recovery is gated on a confirmed open incident even across process restarts.
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 busybox sh -c '
  . ./NVR/v2/nvr.sh
  notify_event RECOVERY cam202 "camera writes again"
'
before=$(sends)
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 busybox sh -c '
  . ./NVR/v2/nvr.sh
  notify_event RECOVERY cam202 "duplicate after close"
'
[ "$(sends)" -eq "$before" ] || { echo 'FAIL duplicate recovery after close must not send' >&2; exit 1; }

# 3) Encoders.
NVR_CONFIG="$T/conf" NVR_LIB_ONLY=1 busybox sh -c '
  . ./NVR/v2/nvr.sh
  [ "$(form_enc "a%b/c d")" = "a%25b%2Fc%20d" ] || exit 3
  [ "$(url_user_enc "plain-Tok.en_~1")" = "plain-Tok.en_~1" ] || exit 4
  [ "$(url_user_enc "p@ss:wo/rd")" = "p%40ss%3Awo%2Frd" ] || exit 5
  # Literal percent must survive untouched in RTSP userinfo.
  [ "$(url_user_enc "pa%20ss")" = "pa%20ss" ] || exit 6
  printf "see rtsp://u:p@1.1.1.1:554/x and rtsp://a:b@2.2.2.2/y\n" | redact | grep -q "rtsp://\[REDACTED\]@1.1.1.1:554/x" || exit 7
  printf "rtsp://u:p@1.1.1.1:554/x" | redact | grep -qv ":p@" || exit 8
' || { echo 'FAIL encoder/redact unit cases' >&2; exit 1; }

# 4) CLI-level notify test via the fake curl transport.
NVR_CONFIG="$T/conf" busybox sh NVR/v2/nvr.sh notify test >/dev/null || {
  echo 'FAIL notify test must succeed with configured transports' >&2; exit 1
}

# 5) Webhook transport must not accept cleartext HTTP or expose tokens.
sed 's#https://webhook.invalid/nvr#http://webhook.invalid/nvr#' "$T/conf" > "$T/insecure-conf"
if NVR_CONFIG="$T/insecure-conf" busybox sh NVR/v2/nvr.sh status > "$T/out" 2> "$T/err"; then
  echo 'FAIL insecure HTTP webhook accepted' >&2; exit 1
fi
grep -q 'must use HTTPS' "$T/err" || { echo 'FAIL cleartext webhook missing diagnostic' >&2; exit 1; }

echo 'Notification logic PASS'
