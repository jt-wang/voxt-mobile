#!/bin/bash
# Tests set-team.sh with throwaway certificates; never reads this Mac's keychain.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3], got [$2]"; fail=1; fi; }
cert() { openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -days 1 -subj "/UID=X/CN=Apple Development: Example (ABCDE12345)/OU=$1/O=Test/C=US" 2>/dev/null; }

export VOXT_SIGNING_DIR="$tmp/config"
cert ABCDE12345 > "$tmp/one.pem"
VOXT_CERT_PEM="$tmp/one.pem" "$here/set-team.sh" > "$tmp/out" 2>&1; check "one certificate: exit" $? 0
check "one certificate: team" "$(sed -n 's/DEVELOPMENT_TEAM = //p' "$VOXT_SIGNING_DIR/Signing.local.xcconfig")" ABCDE12345
check "one certificate: prefix" "$(sed -n 's/VOXT_MOBILE_ID_PREFIX = //p' "$VOXT_SIGNING_DIR/Signing.local.xcconfig")" com.voxtmobile.abcde12345
check "one certificate: says the App Group" "$(grep -c 'group.com.voxtmobile.abcde12345.shared' "$tmp/out")" 1
check "one certificate: says the IDs" "$(grep -c 'App com.voxtmobile.abcde12345, keyboard com.voxtmobile.abcde12345.keyboard,' "$tmp/out")" 1

{ cert ABCDE12345; cert ABCDE12345; } > "$tmp/same.pem"
VOXT_CERT_PEM="$tmp/same.pem" "$here/set-team.sh" > /dev/null 2>&1; check "two certificates, same team" $? 0

{ cert ABCDE12345; cert ZYXWV98765; } > "$tmp/two.pem"
VOXT_CERT_PEM="$tmp/two.pem" "$here/set-team.sh" > "$tmp/out" 2>&1; check "two teams: exit" $? 2
check "two teams: lists both" "$(grep -cE 'ABCDE12345|ZYXWV98765' "$tmp/out")" 2

: > "$tmp/none.pem"
VOXT_CERT_PEM="$tmp/none.pem" "$here/set-team.sh" > "$tmp/out" 2>&1; check "no certificate: exit" $? 1
check "no certificate: says what to do" "$(grep -c 'Settings → Accounts' "$tmp/out")" 1

"$here/set-team.sh" ZYXWV98765 com.example.voxt > /dev/null 2>&1; check "explicit team and prefix" $? 0
check "explicit prefix written" "$(sed -n 's/VOXT_MOBILE_ID_PREFIX = //p' "$VOXT_SIGNING_DIR/Signing.local.xcconfig")" com.example.voxt
"$here/set-team.sh" notateam > /dev/null 2>&1; check "bad team rejected" $? 1
"$here/set-team.sh" ZYXWV98765 'bad prefix' > /dev/null 2>&1; check "bad prefix rejected" $? 1
exit $fail
