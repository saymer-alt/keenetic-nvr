#!/bin/sh
# Offline credential-quoting and helper smoke test: never use real credentials.
set -eu
cd "$(dirname "$0")/.."
busybox ash -n NVR/v2/fresh-install.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT HUP INT TERM
# Extract only pure helpers; do not invoke hardware/terminal installation.
sed -n '/^quote_sh() {/,/^}/p' NVR/v2/fresh-install.sh > "$T/quote.sh"
sed -n '/^has_unsafe_url_chars() {/,/^}/p' NVR/v2/fresh-install.sh > "$T/unsafe.sh"
sed -n '/^status_cam_age() {/,/^}/p' NVR/v2/fresh-install.sh > "$T/age.sh"
. "$T/quote.sh"
. "$T/unsafe.sh"

sample='safe value with spaces, $dollars, a '"'"'single quote'"'"' and ; semicolon'
encoded=$(quote_sh "$sample")
eval "decoded=$encoded"
[ "$decoded" = "$sample" ] || { echo 'FAIL: quoting did not round-trip' >&2; exit 1; }

# Notification secrets must survive the same quoting path.
token='123456789:AA`Example$with specials'"'"'; rm -rf /'
encoded=$(quote_sh "$token")
eval "decoded=$encoded"
[ "$decoded" = "$token" ] || { echo 'FAIL: token quoting did not round-trip' >&2; exit 1; }

# An injected shell fragment must remain inert after source.
marker="$T/unexpected"
sample="'; touch $marker; #"
encoded=$(quote_sh "$sample")
eval "decoded=$encoded"
[ "$decoded" = "$sample" ] && [ ! -e "$marker" ] || { echo 'FAIL: shell injection risk' >&2; exit 1; }

# URL-safety classifier: structural characters are flagged, RTSP-safe are not.
has_unsafe_url_chars 'p@ss' || { echo 'FAIL: @ must be flagged' >&2; exit 1; }
has_unsafe_url_chars 'a:b' || { echo 'FAIL: : must be flagged' >&2; exit 1; }
has_unsafe_url_chars 'sp ce' || { echo 'FAIL: space must be flagged' >&2; exit 1; }
has_unsafe_url_chars 'pa%20ss' && { echo 'FAIL: literal % must stay allowed' >&2; exit 1; }
has_unsafe_url_chars 'plain-Tok.en_~1+;=&$()*!,' && { echo 'FAIL: sub-delims must stay allowed' >&2; exit 1; }
if has_unsafe_url_chars 'PlainPass123'; then
  echo 'FAIL: plain password wrongly flagged' >&2; exit 1
fi

# Installer status parsing contract (v2.4 CAM lines).
parse() { . "$T/age.sh"; status_cam_age "$1" "$2"; }
[ "$(parse 101 'CAM 101: HEALTHY, last write 2s ago')" = 2 ] || { echo 'FAIL: age parse' >&2; exit 1; }
if parse 201 'CAM 201: DOWN, last write 300s ago'; then
  echo 'FAIL: DOWN must not parse as fresh' >&2; exit 1
fi
if parse 301 'CAM 301: HEALTHY, last write no file yet'; then
  echo 'FAIL: no-file line must not parse' >&2; exit 1
fi

echo 'Fresh credentials escaping: PASS'
