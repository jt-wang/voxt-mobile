#!/usr/bin/env bash
# Smoke checks for tools/omni-dev.sh. Run from anywhere; safe to repeat.
#   tools/omni-dev-smoke.sh
# Works on an isolated throwaway checkout (a unique mktemp directory, removed
# on exit) so the real build/omni-source is never mutated, and never builds or
# launches the app: run is exercised only through its refusal paths.
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dev_script="$repo_root/tools/omni-dev.sh"
source_dir="$(mktemp -d "${TMPDIR:-/tmp}/omni-dev-smoke.XXXXXX")"
app_executable="$repo_root/build/omni-dev/Build/Products/Debug/Voxt Omni Dev.app/Contents/MacOS/Voxt Omni Dev"
pinned_revision=ffd00d351200d4de72493d0c707154450da4f2d2

export OMNI_DEV_SOURCE_DIR="$source_dir"
trap 'rm -rf "$source_dir"' EXIT

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

expect_fails() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$description (expected non-zero exit)"
    else
        pass "$description"
    fi
}

if test -x "$dev_script"; then
    pass "omni-dev.sh exists and is executable"
else
    fail "omni-dev.sh exists and is executable"
fi

if test ! -x "$dev_script"; then
    echo "$failures check(s) failed"
    exit 1
fi

expect_fails "usage exits non-zero" "$dev_script" definitely-not-a-subcommand

# Usage must carry the whole documented environment block, not a truncated slice.
usage_output="$("$dev_script" definitely-not-a-subcommand 2>&1 || true)"
missing_usage_docs=""
for documented_variable in OMNI_DEV_SOURCE_DIR OMNI_DEV_LOCAL_API_PORT VOXT_SHARED_MODELS VOXT_DEV_HOME; do
    case "$usage_output" in
        *"$documented_variable"*) ;;
        *) missing_usage_docs="$missing_usage_docs $documented_variable" ;;
    esac
done
if [ -z "$missing_usage_docs" ]; then
    pass "usage documents every environment variable"
else
    fail "usage documents every environment variable (missing:$missing_usage_docs)"
fi

if "$dev_script" prepare >/dev/null; then
    pass "prepare succeeds"
else
    fail "prepare succeeds"
fi

head_revision="$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)"
if test "$head_revision" = "$pinned_revision"; then
    pass "checkout is at the pinned revision"
else
    fail "checkout is at the pinned revision (got ${head_revision:-none})"
fi

if test -f "$source_dir/Voxt/backend/run_omni_dev.sh" &&
    test -f "$source_dir/sglang_omni_mlx/native/scripts/build_runtime.sh" &&
    test ! -e "$source_dir/sglang_omni_mlx/native/../python" &&
    test ! -e "$source_dir/.github"; then
    pass "sparse checkout holds Voxt and only the native runtime"
else
    fail "sparse checkout holds Voxt and only the native runtime"
fi

if test -f "$source_dir/Voxt/Voxt/Core/LocalAPI/LocalAPIServer.swift" &&
    test -f "$source_dir/Voxt/VoxtTests/LocalAPIHTTPTests.swift"; then
    pass "Local API patch is applied"
else
    fail "Local API patch is applied"
fi

if test -f "$source_dir/Voxt/Voxt/Core/LLM/EnhancementLanguageGuard.swift" &&
    grep -q "EnhancementLanguageGuard" "$source_dir/Voxt/Voxt/App/TranscriptionFlow.swift" &&
    grep -q "EnhancementLanguageGuard" "$source_dir/Voxt/Voxt/Core/LocalAPI/LocalAPIComposePrompt.swift"; then
    pass "language guard patches are applied"
else
    fail "language guard patches are applied"
fi

if grep -q "hasConfiguredCaptureGraph" "$source_dir/Voxt/Voxt/Transcription/MLXTranscriber.swift" &&
    test -f "$source_dir/Voxt/VoxtTests/MLXTranscriberIdleReleaseTests.swift"; then
    pass "idle reclamation fix is applied"
else
    fail "idle reclamation fix is applied"
fi

if "$dev_script" prepare >/dev/null; then
    pass "prepare is idempotent"
else
    fail "prepare is idempotent"
fi

# A checkout prepared with only the first patch gets the rest from prepare instead
# of needing a fresh clone.
for patch in $(ls "$repo_root"/tools/patches/*.patch | sort -r | sed '$d'); do
    git -C "$source_dir" apply -R "$patch"
done
if "$dev_script" prepare >/dev/null && test -f "$source_dir/Voxt/Voxt/Core/LLM/EnhancementLanguageGuard.swift"; then
    pass "prepare adds the later patches to a checkout with only the first"
else
    fail "prepare adds the later patches to a checkout with only the first"
fi

echo "local edit" >>"$source_dir/Voxt/README.md"
if "$dev_script" prepare >/dev/null 2>&1; then
    fail "prepare rejects a dirty unrelated checkout"
else
    pass "prepare rejects a dirty unrelated checkout"
fi
git -C "$source_dir" checkout -- Voxt/README.md

if "$dev_script" prepare >/dev/null; then
    pass "prepare recovers after the unrelated edit is reverted"
else
    fail "prepare recovers after the unrelated edit is reverted"
fi

echo "// drifted outside any hunk" >>"$source_dir/Voxt/Voxt/App/VoxtApp.swift"
if "$dev_script" prepare >/dev/null 2>&1; then
    fail "prepare detects drift outside hunks in a patched tracked file"
else
    pass "prepare detects drift outside hunks in a patched tracked file"
fi
# git checkout -- would restore the stock file (patch undone); undo just the
# appended line so the patched content is intact again.
sed -i '' -e '$d' "$source_dir/Voxt/Voxt/App/VoxtApp.swift"

if "$dev_script" prepare >/dev/null; then
    pass "prepare recovers after the tracked-file drift is undone"
else
    fail "prepare recovers after the tracked-file drift is undone"
fi

echo "// drifted" >>"$source_dir/Voxt/Voxt/Core/LocalAPI/LocalAPIServer.swift"
if "$dev_script" prepare >/dev/null 2>&1; then
    fail "prepare detects a modified patched file"
else
    pass "prepare detects a modified patched file"
fi
rm -rf "$source_dir"
if "$dev_script" prepare >/dev/null; then
    pass "prepare rebuilds the checkout from scratch after drift"
else
    fail "prepare rebuilds the checkout from scratch after drift"
fi

# run is checked only through its refusals. Each check runs while the default port is
# busy, so a run that misread its port would still refuse instead of launching the app;
# the message says which port it read.
run_refusal() {
    local description="$1" expected="$2" output
    shift 2
    output="$(env "$@" "$dev_script" run 2>&1 || true)"
    case "$output" in
        *"$expected"*) pass "$description" ;;
        *) fail "$description (got: $output)" ;;
    esac
}

if [ ! -x "$app_executable" ]; then
    expect_fails "run refuses before build" "$dev_script" run
else
    nc -l 127.0.0.1 47920 >/dev/null 2>&1 &
    default_listener_pid=$!
    local_listener_port=54831
    nc -l 127.0.0.1 "$local_listener_port" >/dev/null 2>&1 &
    listener_pid=$!
    sleep 1
    listener_owner="$(lsof -nP -iTCP:"$local_listener_port" -sTCP:LISTEN -t 2>/dev/null || true)"
    if ! lsof -nP -iTCP:47920 -sTCP:LISTEN -t 2>/dev/null | grep -q .; then
        echo "SKIP run refusals (the default port 47920 could not be held)"
    elif ! kill -0 "$listener_pid" 2>/dev/null || [ "$listener_owner" != "$listener_pid" ]; then
        echo "SKIP run refusals (no listener owned by this script on $local_listener_port)"
    else
        run_refusal "run rejects an out-of-range port" "must be within 1024..65534, got 99999" OMNI_DEV_LOCAL_API_PORT=99999
        run_refusal "run rejects a port that is already in use" "port $local_listener_port is already in use" \
            OMNI_DEV_LOCAL_API_PORT="$local_listener_port"
        run_refusal "run reads the old OMNI_DEV_REMOTE_INPUT_PORT name" "port $local_listener_port is already in use" \
            OMNI_DEV_REMOTE_INPUT_PORT="$local_listener_port"
    fi
    kill "$listener_pid" "$default_listener_pid" 2>/dev/null
    wait "$listener_pid" "$default_listener_pid" 2>/dev/null || true
fi

echo "$failures check(s) failed"
exit "$failures"
