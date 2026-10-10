#!/bin/sh
# Secret hygiene scan for the NVR section: no real tokens, RTSP credentials,
# private keys or webhook URLs in tracked files. Run from repository root.
set -eu
cd "$(dirname "$0")/.."
fail() { printf 'SECRET SCAN FAIL: %s\n' "$*" >&2; exit 1; }

# Telegram bot tokens look like <9-10 digits>:<35 chars>. Example placeholders
# with YOUR_/EXAMPLE markers are allowed.
if grep -RInE '[0-9]{8,10}:[A-Za-z0-9_-]{30,}' NVR tests \
   | grep -v 'YOUR_BOT_TOKEN' \
   | grep -v 'test-only-token'; then
  fail 'Telegram token shape found'
fi

# rtsp:// URLs with userinfo are only allowed as variable references, documented
# placeholders, offline test fixtures or redacted output.
violations=$(grep -RInE 'rtsp://[^/@"]+:[^/@"]+@' NVR tests \
  | grep -v 'tests/secrets-scan.sh' \
  | grep -vE 'rtsp://\[REDACTED\]@' \
  | grep -vE 'rtsp://\$[A-Za-z_]+:\$[A-Za-z_]+@' \
  | grep -vE 'rtsp://(user|USER|username|YOUR_USER|dummy):' \
  | grep -vE ':(pass|PASS|password|YOUR_CAMERA_PASSWORD|YOUR_PASS|test-only-secret|secret)@' \
  | grep -vE 'rtsp://u:p@|leaked-pass' \
  || :)
[ -z "$violations" ] || { printf '%s\n' "$violations" >&2; fail 'rtsp URL with credentials found'; }

grep -RIn 'BEGIN [A-Z ]*PRIVATE KEY' NVR tests >/dev/null 2>&1 \
  && fail 'private key material found' || :

# api.telegram.org references must never embed a bot token in the URL itself.
violations=$(grep -RInE 'api\.telegram\.org/bot[0-9]+:[A-Za-z0-9_-]+' NVR tests || :)
[ -z "$violations" ] || { printf '%s\n' "$violations" >&2; fail 'token embedded in telegram URL'; }

# The home-router migration file is the only allowed place for the local disk
# UUID (operator machine binding, documented in KNOWN-LIMITATIONS.md). The UUID
# is assembled from two halves so this scanner never matches itself.
uuid="f9bf834b-5650-d901-f0aa-834b""5650d901"
violations=$(grep -RIl "$uuid" NVR tests \
  | grep -v 'NVR/v2/install-router.sh' \
  | grep -v 'NVR/v2/README.md' \
  || :)
[ -z "$violations" ] || { printf '%s\n' "$violations" >&2; fail 'home disk UUID outside allowed files'; }

echo 'Secret scan PASS'
