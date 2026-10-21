#!/bin/bash
# Sets the Apple team (a free Personal Team works) and a unique ID prefix for device builds.
#
#   ios/tools/set-team.sh                 find the team in this Mac's "Apple Development" certificate
#   ios/tools/set-team.sh TEAM_ID         use this team
#   ios/tools/set-team.sh TEAM_ID PREFIX  and this bundle ID prefix (default com.voxtmobile.<team>)
#
# Writes ios/Config/Signing.local.xcconfig (not committed). Xcode makes the certificate when you
# add your Apple ID in Xcode → Settings → Accounts and build once for a phone.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${VOXT_SIGNING_DIR:-$here/../Config}/Signing.local.xcconfig

teams_in_certificates() {
  local dir; dir=$(mktemp -d); trap 'rm -rf "$dir"' RETURN
  if [ -n "${VOXT_CERT_PEM:-}" ]; then cp "$VOXT_CERT_PEM" "$dir/all.pem"   # tests
  else security find-certificate -a -c "Apple Development" -p > "$dir/all.pem" 2>/dev/null || true; fi
  # One file per certificate, then the team ID from each subject's OU field.
  awk -v d="$dir" '/BEGIN CERTIFICATE/{n++} n{print > (d "/cert-" n ".pem")}' "$dir/all.pem"
  for cert in "$dir"/cert-*.pem; do
    [ -e "$cert" ] || continue
    openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p'
  done | sort -u
}

team=${1:-}
if [ -z "$team" ]; then
  teams=$(teams_in_certificates)
  count=$(printf '%s' "$teams" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "No \"Apple Development\" certificate on this Mac." >&2
    echo "In Xcode: Settings → Accounts → + → Apple ID, then build once for your iPhone; then run this again." >&2
    exit 1
  elif [ "$count" -gt 1 ]; then
    echo "This Mac has certificates for more than one team:" >&2
    printf '  %s\n' $teams >&2
    echo "Run: ios/tools/set-team.sh <one of these>" >&2
    exit 2
  fi
  team=$teams
fi
if ! [[ "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "\"$team\" isn't a team ID (10 capital letters and digits)." >&2
  exit 1
fi
prefix=${2:-com.voxtmobile.$(printf '%s' "$team" | tr 'A-Z' 'a-z')}
if ! [[ "$prefix" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "\"$prefix\" isn't a bundle ID prefix like com.example.voxt." >&2
  exit 1
fi
mkdir -p "$(dirname "$out")"
printf '// Written by ios/tools/set-team.sh. Not committed.\nDEVELOPMENT_TEAM = %s\nVOXT_MOBILE_ID_PREFIX = %s\n' "$team" "$prefix" > "$out"
echo "Team $team. App $prefix, keyboard $prefix.keyboard, App Group group.$prefix.shared."
echo "Wrote $out. Now open ios/VoxtMobile.xcodeproj, choose your iPhone and press Run."
