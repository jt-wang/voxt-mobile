#!/bin/bash
# Builds release binaries only from a clean checkout of a public commit, stamps that commit into
# every app (VoxtSourceRevision), and runs the release gate on the result.
#   tools/release-build.sh --remote URL --tag vX.Y.Z [--mirror DIR]   (public repo)
#   tools/release-build.sh --local REPO --export DIR --rev SHA        (before the first push: REPO holds
#                                                                      source-export's public commits)
#   then: [--version v1.2.3] [--ios --build N] [--mac [--mac-app APP]...] [--out DIR] [--dry-run]
# Each check also requires every app of ours to be version --version (v1.2.3 -> 1.2.3).
# Last, release-gate.py release tags the public commit v1.2.3+N (or +mac) and drafts release notes;
# --version defaults to --tag. VOXT_RELEASE_TAGGER="Name <email>" names the tagger (it is public).
# iOS (default) signs for App Store Connect: VOXT_TEAM_ID, VOXT_PROFILE_APP, VOXT_PROFILE_KEYBOARD
# (provisioning profile names), and VOXT_SIGNING_LOCAL, the official build's Signing.local.xcconfig: the
# public source has only neutral IDs, so the release's bundle IDs and Keychain names come from that file. Mac builds Voxt Connector (plus any --mac-app, such as Voxt Omni Dev), signs
# every app with VOXT_DEVELOPER_ID ("Developer ID Application: Name (TEAM)"), puts them and the Start Here guide
# (mac/dmg) on a signed DMG and notarizes it with the App Store Connect key in VOXT_NOTARY_KEY, VOXT_NOTARY_KEY_ID
# and VOXT_NOTARY_ISSUER. The DMG is then copied to VoxtMobile-Mac.dmg and VoxtMobile-Mac-vX.Y.Z.dmg for upload.
# The Connector gets the neutral bundle ID of mac/VoxtConnector/Config/Signing.shared.xcconfig, or
# VOXT_CONNECTOR_BUNDLE_ID from VOXT_CONNECTOR_SIGNING_LOCAL, the official build's private xcconfig, so
# installed Connectors keep their ID; every --mac-app Voxt must trust that ID (VoxtConnectorBundleIdentifier).
# --dry-run prepares and checks the source, then prints the build commands instead of running them.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
mode=() ios=0 mac=0 mac_apps=() build="" out="" dry=0 ref="" version=""
while (( $# )); do
  case $1 in
    --remote|--local|--mirror|--export) mode+=("$1" "$2"); shift 2 ;;
    --tag|--rev) mode+=("$1" "$2"); ref=$2; [[ $1 == --tag ]] && version=${version:-$2}; shift 2 ;;
    --version) version=$2; shift 2 ;;
    --build) build=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --ios) ios=1; shift ;;
    --mac) mac=1; shift ;;
    --mac-app) mac_apps+=("$2"); shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "release-build: unknown argument $1" >&2; exit 2 ;;
  esac
done
(( ios || mac )) || ios=1
[[ -n $ref ]] || { echo "release-build: needs --tag or --rev" >&2; exit 2; }
out=${out:-$root/build/release/$ref}
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-build: --version v1.2.3 is required with --rev" >&2; exit 2; }
[[ -n ${VOXT_RELEASE_TAGGER:-} ]] || { echo "release-build: set VOXT_RELEASE_TAGGER=\"Name <email>\" (shown on the public tag)" >&2; exit 2; }
if (( ios )); then
  [[ $build =~ ^[0-9]+$ ]] || { echo "release-build: --build N is required for iOS" >&2; exit 2; }
  for name in VOXT_TEAM_ID VOXT_PROFILE_APP VOXT_PROFILE_KEYBOARD VOXT_SIGNING_LOCAL; do
    [[ -n ${!name:-} ]] || { echo "release-build: set $name" >&2; exit 2; }
  done
  [[ -f $VOXT_SIGNING_LOCAL ]] || { echo "release-build: VOXT_SIGNING_LOCAL is not a file: $VOXT_SIGNING_LOCAL" >&2; exit 2; }
  prefix=$(sed -n 's/^VOXT_MOBILE_ID_PREFIX *= *//p' "$VOXT_SIGNING_LOCAL" | tail -1)
  [[ -n $prefix ]] || { echo "release-build: VOXT_SIGNING_LOCAL sets no VOXT_MOBILE_ID_PREFIX" >&2; exit 2; }
fi
if (( mac )); then
  for name in VOXT_DEVELOPER_ID VOXT_NOTARY_KEY VOXT_NOTARY_KEY_ID VOXT_NOTARY_ISSUER; do
    [[ -n ${!name:-} ]] || { echo "release-build: set $name" >&2; exit 2; }
  done
  [[ $VOXT_DEVELOPER_ID =~ \(([A-Z0-9]{10})\)$ ]] || { echo "release-build: VOXT_DEVELOPER_ID must end in (TEAMID)" >&2; exit 2; }
  team=${BASH_REMATCH[1]}
  connector_id=com.voxt.VoxtConnector
  if [[ -n ${VOXT_CONNECTOR_SIGNING_LOCAL:-} ]]; then
    [[ -f $VOXT_CONNECTOR_SIGNING_LOCAL ]] ||
      { echo "release-build: VOXT_CONNECTOR_SIGNING_LOCAL is not a file: $VOXT_CONNECTOR_SIGNING_LOCAL" >&2; exit 2; }
    connector_id=$(sed -n 's|^VOXT_CONNECTOR_BUNDLE_ID *= *\([^ /]*\).*|\1|p' "$VOXT_CONNECTOR_SIGNING_LOCAL" | tail -1)
    [[ $connector_id =~ ^[A-Za-z0-9.-]+$ ]] ||
      { echo "release-build: VOXT_CONNECTOR_SIGNING_LOCAL sets no VOXT_CONNECTOR_BUNDLE_ID" >&2; exit 2; }
  fi
  for extra in ${mac_apps[@]+"${mac_apps[@]}"}; do
    info="$extra/Contents/Info.plist"
    case $(plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null) in
      com.voxt.Voxt|com.voxt.Voxt.omni.dev)
        trusted=$(plutil -extract VoxtConnectorBundleIdentifier raw -o - "$info" 2>/dev/null || echo com.voxt.VoxtConnector)
        [[ $trusted == "$connector_id" ]] || { echo "release-build: $extra trusts the Connector $trusted" \
          "(VoxtConnectorBundleIdentifier), but the Connector is built as $connector_id" >&2; exit 2; } ;;
    esac
  done
fi
check_mode=()  # the same public source, for release-gate.py check
for (( i = 0; i < ${#mode[@]}; i += 2 )); do
  [[ ${mode[i]} == --tag || ${mode[i]} == --rev ]] || check_mode+=("${mode[i]}" "${mode[i+1]}")
done

mkdir -p "$out"
src="$out/source"
sha=$(python3 -I "$here/release-gate.py" source "${mode[@]}" --dir "$src" | tail -1)
echo "release-build: $sha in $src"
run() { if (( dry )); then echo "+ $*"; else "$@"; fi; }
export TMPDIR="$out/tmp/"; mkdir -p "$TMPDIR"
# Go module downloads are shared with the working repo; -trimpath keeps their paths out of the binary.
export VOXT_TAILCAT_GO_CACHE=${VOXT_TAILCAT_GO_CACHE:-$root/build/voxt-tailcat-go}
derived="$out/DerivedData"
# Source and build folders appear in debug info and .symbols as /voxt-mobile and /DerivedData.
swift_maps="-file-prefix-map \"$src=/voxt-mobile\" -file-prefix-map \"$derived=/DerivedData\""
c_maps="\"-ffile-prefix-map=$src=/voxt-mobile\" \"-ffile-prefix-map=$derived=/DerivedData\""

if (( ios )); then
  cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>export</string>
<key>teamID</key><string>$VOXT_TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Apple Distribution</string>
<key>provisioningProfiles</key><dict>
  <key>$prefix</key><string>$VOXT_PROFILE_APP</string>
  <key>$prefix.keyboard</key><string>$VOXT_PROFILE_KEYBOARD</string>
</dict>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
  run "$src/tools/build-tailcat-native.sh"
  run xcodebuild archive -project "$src/ios/VoxtMobile.xcodeproj" -scheme VoxtMobile -configuration Release \
    -destination generic/platform=iOS -archivePath "$out/VoxtMobile-$build.xcarchive" -derivedDataPath "$derived" \
    -resultBundlePath "$out/archive-$build.xcresult" -packageCachePath "$root/build/swiftpm-cache" \
    -xcconfig "$VOXT_SIGNING_LOCAL" CURRENT_PROJECT_VERSION="$build" VOXT_SOURCE_REVISION="$sha" \
    DEVELOPMENT_TEAM="$VOXT_TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
    'PROVISIONING_PROFILE_SPECIFIER=$(VOXT_PROFILE_$(TARGET_NAME))' \
    "VOXT_PROFILE_VoxtMobile=$VOXT_PROFILE_APP" "VOXT_PROFILE_VoxtKeyboard=$VOXT_PROFILE_KEYBOARD" \
    "OTHER_SWIFT_FLAGS=\$(inherited) $swift_maps" "OTHER_CFLAGS=\$(inherited) $c_maps"
  run xcodebuild -exportArchive -archivePath "$out/VoxtMobile-$build.xcarchive" \
    -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export-$build"
  run python3 -I "$here/release-gate.py" check "$out/export-$build/VoxtMobile.ipa" --version "$version" "${check_mode[@]}"
fi

if (( mac )); then
  run env VOXT_CONNECTOR_SIGNING_IDENTITY="$VOXT_DEVELOPER_ID" python3 -I "$src/tools/build-connector.py" --source-revision "$sha" \
    --bundle-id "$connector_id"
  app="$src/build/connector-derived/Build/Products/Release/Voxt Connector.app"
  # Voxt's ConnectorLinkServer trusts only a Connector signed by Voxt's own team with the Connector's
  # bundle ID, so Voxt Omni Dev must be signed by the same team.
  requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team\" and identifier \"$connector_id\""
  run python3 -I "$here/release-mac.py" sign --identity "$VOXT_DEVELOPER_ID" --team "$team" --strip-debug --requirement "$requirement" "$app"
  for extra in ${mac_apps[@]+"${mac_apps[@]}"}; do
    run python3 -I "$here/release-mac.py" sign --identity "$VOXT_DEVELOPER_ID" --team "$team" --strip-debug "$extra"
  done
  # The setup guide and the window background come from the public checkout.
  run python3 -I "$here/release-mac.py" dmg --identity "$VOXT_DEVELOPER_ID" --volname "Voxt Mobile" \
    --out "$out/VoxtConnector.dmg" --extra "$src/mac/dmg/Start Here.html" --background "$src/mac/dmg/background.svg" \
    "$app" ${mac_apps[@]+"${mac_apps[@]}"}
  run python3 -I "$here/release-mac.py" notarize "$out/VoxtConnector.dmg" --log "$out/notarization.json"
  run python3 -I "$here/release-gate.py" check "$out/VoxtConnector.dmg" --version "$version" "${check_mode[@]}"
  # Upload names: VoxtMobile-Mac.dmg keeps .../releases/latest/download/VoxtMobile-Mac.dmg on the newest release.
  run cp "$out/VoxtConnector.dmg" "$out/VoxtMobile-Mac.dmg"
  run cp "$out/VoxtConnector.dmg" "$out/VoxtMobile-Mac-$version.dmg"
fi
release=(--version "$version" --notes "$out/release-notes-$version.md")
(( ios )) && release+=(--build "$build" --ipa "$out/export-$build/VoxtMobile.ipa")
(( mac )) && release+=(--dmg "$out/VoxtConnector.dmg")
run python3 -I "$here/release-gate.py" release "${release[@]}" --tagger "$VOXT_RELEASE_TAGGER" "${check_mode[@]}"
(( dry )) && echo "release-build: dry run, nothing built" || echo "release-build: done in $out"
