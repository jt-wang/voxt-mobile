#!/usr/bin/env bash
# Reproducible "Voxt Omni Dev" checkout with Voxt's Local API for Voxt Mobile.
#
#   tools/omni-dev.sh prepare
#   tools/omni-dev.sh build
#   tools/omni-dev.sh run [--swift-backend]
#   tools/omni-dev.sh stamp APP
#   tools/omni-dev.sh release OUT_DIR
#   tools/omni-dev.sh build-command debug|release
#   tools/omni-dev.sh strip-debug APP
#
# prepare clones the pinned sglang-omni revision sparsely (the Voxt app and
# sglang_omni_mlx/native only) into build/omni-source and applies the patches
# from tools/patches in order. It verifies the patched tree by content, not
# a marker, refuses a checkout with unrelated local changes, and is idempotent.
# build reuses the native runtime at build/omni-runtime when present (building
# it there first only if missing) and builds the app into build/omni-dev. run
# starts the app with an isolated file-data home (CFFIXED_USER_HOME) and the
# Local API on an unused configurable port; preferences are isolated
# by the app's own com.voxt.Voxt.omni.dev bundle id. release builds the Release
# configuration into build/omni-dev-release with the source and build folders mapped
# out of debug info, stamps like build, and copies the app to OUT_DIR
# (ad hoc signed; tools/release-mac.py signs it for Voxt's team), with its dSYM next
# to it; the shipped executable is stripped of debug symbols. build-command
# prints the xcodebuild arguments of either configuration, one per line.
#
# Environment:
#   OMNI_DEV_SOURCE_DIR         Checkout location (default build/omni-source).
#   OMNI_DEV_LOCAL_API_PORT     Port for the Local API (default 47920, so a regular
#                               Voxt on its own port stays untouched; the earlier name
#                               OMNI_DEV_REMOTE_INPUT_PORT is still read).
#   VOXT_SHARED_MODELS          Existing <root>/mlx-audio model directory to share.
#   VOXT_DEV_HOME               Isolated home for the app (default build/omni-home).
#   OMNI_DEV_RUNTIME_DIR        Native runtime to reuse or build (default build/omni-runtime);
#                               a release from a fresh public checkout can point at an existing one.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${OMNI_DEV_SOURCE_DIR:-$repo_root/build/omni-source}"
# One patch per commit of the Voxt side of the sglang-omni pull request (the Voxt/ part
# only: the checkout is sparse), applied in the order of their number.
patch_files=("$repo_root"/tools/patches/[0-9][0-9]-*.patch)
upstream_url=https://github.com/sgl-project/sglang-omni
pinned_revision=ffd00d351200d4de72493d0c707154450da4f2d2
local_api_port_default=47920
dev_home_default="$repo_root/build/omni-home"
runtime_dir="${OMNI_DEV_RUNTIME_DIR:-$repo_root/build/omni-runtime}"
runtime_binary="$runtime_dir/bin/qwen3_asr_server"
derived_data="$repo_root/build/omni-dev"
release_derived="$repo_root/build/omni-dev-release"
app_path="$derived_data/Build/Products/Debug/Voxt Omni Dev.app"

usage() { awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0" >&2; exit 2; }

die() { echo "$1" >&2; exit 1; }

patched_paths() {
    for patch in "${patch_files[@]}"; do git apply --numstat "$patch"; done | awk '{ print $3 }' | sort -u
}

# The worktree must match HEAD plus the first N patches (default all) byte for
# byte. A plain reverse apply --check only proves the hunks survive; edits
# outside them (an appended line in a patched tracked file) would still pass.
# Build the expected tree in a throwaway index and diff it against the worktree.
verify_patched_content() {
    local count="${1:-${#patch_files[@]}}" temp_index index
    temp_index="$(mktemp "${TMPDIR:-/tmp}/omni-dev-index.XXXXXX")"
    trap 'rm -f "${temp_index:-}"' RETURN
    GIT_INDEX_FILE="$temp_index" git -C "$source_dir" read-tree HEAD 2>/dev/null ||
        die "cannot read the pinned tree at $source_dir"
    for ((index = 0; index < count; index++)); do
        GIT_INDEX_FILE="$temp_index" git -C "$source_dir" apply --cached "${patch_files[$index]}" 2>/dev/null ||
            die "cannot stage $(basename "${patch_files[$index]}") at the pinned revision"
    done
    # Compare only the patched paths: the sparse worktree intentionally lacks
    # every other file that read-tree pulled into the throwaway index.
    GIT_INDEX_FILE="$temp_index" git -C "$source_dir" diff --exit-code --quiet -- $(patched_paths)
}

unrelated_dirty_files() {
    git -C "$source_dir" status --porcelain -uall | while IFS= read -r status_line; do
        [ -z "$status_line" ] && continue
        status_path="${status_line:3}"
        status_path="${status_path#\"}"
        status_path="${status_path%\"}"
        if ! patched_paths | grep -qx "$status_path"; then
            echo "$status_path"
        fi
    done
}

clone_pinned() {
    git clone --filter=blob:none --no-checkout "$upstream_url" "$source_dir"
    git -C "$source_dir" sparse-checkout init --cone
    git -C "$source_dir" sparse-checkout set Voxt sglang_omni_mlx/native
    git -C "$source_dir" fetch --quiet --depth 1 origin "$pinned_revision"
    git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
}

prepare() {
    if test -d "$source_dir/.git"; then
        dirty="$(unrelated_dirty_files)"
        [ -z "$dirty" ] || die "checkout carries unrelated local changes:
$dirty
Revert or commit them, or delete $source_dir to start over."
        if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$pinned_revision" ]; then
            git -C "$source_dir" fetch --quiet --depth 1 origin "$pinned_revision"
            git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
        fi
        git -C "$source_dir" sparse-checkout set Voxt sglang_omni_mlx/native
    else
        clone_pinned
    fi

    # A checkout may already carry the first few patches; apply only the rest.
    local applied="" count index
    for ((count = ${#patch_files[@]}; count >= 0; count--)); do
        if verify_patched_content "$count"; then applied=$count; break; fi
    done
    [ -n "$applied" ] ||
        die "the patches neither verify nor apply; patched files were modified. Delete $source_dir to start over."
    for ((index = applied; index < ${#patch_files[@]}; index++)); do
        git -C "$source_dir" apply "${patch_files[$index]}" ||
            die "cannot apply $(basename "${patch_files[$index]}"). Delete $source_dir to start over."
    done
    verify_patched_content ||
        die "the freshly applied patches do not verify; $source_dir is inconsistent"

    test -f "$source_dir/Voxt/Voxt/Core/LocalAPI/LocalAPIServer.swift" ||
        die "Local API sources missing after prepare"
    echo "prepare: $(git -C "$source_dir" rev-parse --short HEAD) + ${#patch_files[@]} patches at $source_dir"
}

# Sets xcodebuild_args for the debug or release build. Release maps the checkout and the
# build folder out of debug info and symbols, as tools/release-build.sh does for the iPhone app.
build_command() {
    local configuration derived
    case "$1" in
        debug) configuration=Debug; derived="$derived_data" ;;
        release) configuration=Release; derived="$release_derived" ;;
        *) die "build-command takes debug or release, got '$1'" ;;
    esac
    xcodebuild_args=(build
        -project "$source_dir/Voxt/Voxt.xcodeproj"
        -scheme Voxt
        -configuration "$configuration"
        -destination 'platform=macOS'
        -xcconfig "$source_dir/Voxt/Config/OmniDev.xcconfig"
        -derivedDataPath "$derived"
        -resultBundlePath "$derived/results/build-$(date +%Y%m%d-%H%M%S).xcresult"
        -packageCachePath "$repo_root/build/swiftpm-cache"
        -jobs 4
        -skipPackagePluginValidation)
    if [ "$1" = release ]; then
        xcodebuild_args+=(
            "OTHER_SWIFT_FLAGS=\$(inherited) -file-prefix-map \"$source_dir=/voxt-source\" -file-prefix-map \"$derived=/DerivedData\""
            "OTHER_CFLAGS=\$(inherited) \"-ffile-prefix-map=$source_dir=/voxt-source\" \"-ffile-prefix-map=$derived=/DerivedData\"")
    fi
}

ensure_runtime() {
    if [ ! -x "$runtime_binary" ]; then
        echo "build: native runtime missing, building into $runtime_dir"
        "$source_dir/sglang_omni_mlx/native/scripts/build_runtime.sh" "$runtime_dir"
    else
        echo "build: reusing $runtime_binary"
    fi
}

build() {
    prepare
    ensure_runtime
    build_command debug
    xcodebuild "${xcodebuild_args[@]}"
    stamp "$app_path"
    echo "build: $app_path"
}

# Removes the debug symbols, and with them the absolute object-file paths the linker records (over a
# thousand in a Release Voxt Omni Dev), from the app's executable; Xcode's dSYM keeps them for symbolication.
# Re-signs the executable ad hoc so it still runs; stamp re-signs the bundle afterwards.
strip_debug() {
    local app="$1" executable
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)" ||
        die "strip-debug: $app has no Info.plist with an executable"
    test -f "$app/Contents/MacOS/$executable" || die "strip-debug: $app/Contents/MacOS/$executable not found"
    xcrun strip -S "$app/Contents/MacOS/$executable" 2>/dev/null || die "strip-debug: strip failed"
    /usr/bin/codesign --force --sign - "$app/Contents/MacOS/$executable" >/dev/null 2>&1 || die "strip-debug: re-signing failed"
}

release() {
    local out="${1:-}"
    [ -n "$out" ] || usage
    [ ! -e "$out/Voxt Omni Dev.app" ] || die "release: $out already has Voxt Omni Dev.app; use a new folder"
    prepare
    ensure_runtime
    build_command release
    xcodebuild "${xcodebuild_args[@]}"
    local release_app="$release_derived/Build/Products/Release/Voxt Omni Dev.app"
    local release_dsym="$release_derived/Build/Products/Release/Voxt Omni Dev.app.dSYM"
    strip_debug "$release_app"
    stamp "$release_app"
    mkdir -p "$out"
    ditto "$release_app" "$out/Voxt Omni Dev.app"
    ditto "$release_dsym" "$out/Voxt Omni Dev.app.dSYM"
    echo "release: $out/Voxt Omni Dev.app"
}

# Records in Info.plist which commits built the app; tools/release-gate.py checks it before a release.
# VoxtUpstreamRevision is the pinned sglang-omni commit. VoxtSourceRevision is this repo's commit, and
# only when the checkout has no uncommitted or untracked files: otherwise the app isn't that commit.
# VoxtConnectorBundleIdentifier is the Connector ID this app trusts on its Connector socket: the one
# tools/build-connector.py gives the Connector (VOXT_CONNECTOR_SIGNING_LOCAL or mac/VoxtConnector/Config).
stamp() {
    local app="$1" plist="$1/Contents/Info.plist" upstream source="" connector
    test -f "$plist" || die "stamp: $plist not found"
    connector="$(python3 -I "$repo_root/tools/build-connector.py" --print-bundle-id)" ||
        die "stamp: no Connector bundle ID (see the message above)"
    upstream="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)" || die "stamp: no checkout at $source_dir"
    [ "$upstream" = "$pinned_revision" ] || die "stamp: $source_dir is at $upstream, not the pinned $pinned_revision"
    if [ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all 2>&1)" ]; then
        source="$(git -C "$repo_root" rev-parse HEAD)"
    fi
    plutil -replace VoxtUpstreamRevision -string "$upstream" "$plist"
    plutil -replace VoxtConnectorBundleIdentifier -string "$connector" "$plist"
    if [ -n "$source" ]; then
        plutil -replace VoxtSourceRevision -string "$source" "$plist"
    else
        plutil -remove VoxtSourceRevision "$plist" 2>/dev/null || true
        echo "stamp: $repo_root has uncommitted or untracked files, so VoxtSourceRevision is left out and the release gate will refuse this app" >&2
    fi
    /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,flags,runtime "$app" >/dev/null 2>&1 ||
        die "stamp: re-signing $app failed"
    echo "stamp: VoxtSourceRevision=${source:-none} VoxtUpstreamRevision=$upstream VoxtConnectorBundleIdentifier=$connector"
}

app_executable="$derived_data/Build/Products/Debug/Voxt Omni Dev.app/Contents/MacOS/Voxt Omni Dev"

run() {
    test -x "$app_executable" || die "Build first: $0 build"
    local local_api_port="${OMNI_DEV_LOCAL_API_PORT:-${OMNI_DEV_REMOTE_INPUT_PORT:-$local_api_port_default}}"
    case "$local_api_port" in
        '' | *[!0-9]*) die "OMNI_DEV_LOCAL_API_PORT must be a number, got '$local_api_port'" ;;
    esac
    [ "$local_api_port" -ge 1024 ] && [ "$local_api_port" -le 65534 ] ||
        die "OMNI_DEV_LOCAL_API_PORT must be within 1024..65534, got $local_api_port"
    if lsof -nP -iTCP:"$local_api_port" -sTCP:LISTEN | grep -q .; then
        die "port $local_api_port is already in use; set OMNI_DEV_LOCAL_API_PORT"
    fi
    local dev_home="${VOXT_DEV_HOME:-$dev_home_default}"
    local model_root="$dev_home/Library/Application Support/Voxt/model-storage"
    mkdir -p "$model_root"
    if [ -n "${VOXT_SHARED_MODELS:-}" ] && [ ! -e "$model_root/mlx-audio" ]; then
        ln -s "$VOXT_SHARED_MODELS" "$model_root/mlx-audio"
    fi
    # Preferences travel by bundle id through cfprefsd, written in domain
    # form: path-form defaults writes are invisible to the app (the file
    # holds the value, the app reads the default). CFFIXED_USER_HOME does
    # not isolate UserDefaults domains (one domain write is read in both
    # fixed homes); isolation from an installed Voxt comes
    # from the separate com.voxt.Voxt.omni.dev bundle id. CFFIXED_USER_HOME
    # isolates the app's file data: database, history and models. No launch
    # arguments are passed, so the in-app Settings toggle and port stay
    # authoritative.
    CFFIXED_USER_HOME="$dev_home" defaults write com.voxt.Voxt.omni.dev localAPIServerEnabled -bool true
    CFFIXED_USER_HOME="$dev_home" defaults write com.voxt.Voxt.omni.dev localAPIServerPort -int "$local_api_port"

    local backend_env=()
    if [ "${1:-}" != "--swift-backend" ]; then
        [ -x "$runtime_binary" ] || die "Build the runtime first: $0 build"
        backend_env=(VOXT_ASR_BACKEND=omni VOXT_OMNI_RUNTIME="$runtime_binary")
    else
        backend_env=(VOXT_ASR_BACKEND=swift)
    fi
    echo "run: Local API on 127.0.0.1:$local_api_port, home $dev_home"
    exec env CFFIXED_USER_HOME="$dev_home" ${backend_env[@]+"${backend_env[@]}"} \
        "$app_executable"
}

case "${1:-}" in
    prepare) prepare ;;
    build) build ;;
    run) run "${2:-}" ;;
    stamp) [ -n "${2:-}" ] || usage; stamp "$2" ;;
    release) release "${2:-}" ;;
    strip-debug) [ -n "${2:-}" ] || usage; strip_debug "$2" ;;
    build-command) build_command "${2:-}"; printf '%s\n' "${xcodebuild_args[@]}" ;;
    *) usage ;;
esac
