#!/usr/bin/env python3
"""Tests for the release gate: shipped builds come only from public source.

Usage: python3 -I tools/test-release-gate.py [-v] [--ipa path/to/old.ipa]
Builds small git repos, IPAs and one DMG under $TMPDIR. Runs no xcodebuild and no Go build.
--ipa also checks a real IPA built before the gate existed: it must be blocked.
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
GATE = TOOLS / "release-gate.py"
BUILD = TOOLS / "release-build.sh"
UPLOAD = TOOLS / "release-upload.sh"
# Built at run time so the source itself holds no local-looking path.
VOLUMES = b"/" + b"Volumes" + b"/"
OLD_IPA = None
if "--ipa" in sys.argv:
    _index = sys.argv.index("--ipa")
    OLD_IPA = Path(sys.argv[_index + 1])
    del sys.argv[_index:_index + 2]


def git(cwd, *args, env=None):
    full = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com", **(env or {})}
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True, env=full).stdout.strip()


def gate(*args):
    return subprocess.run([sys.executable, "-I", str(GATE), *map(str, args)], capture_output=True, text=True, timeout=120)


def info(bundle_id, revision=None):
    plist = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": bundle_id.rsplit(".", 1)[-1]}
    if revision is not None:
        plist["VoxtSourceRevision"] = revision
    return plistlib.dumps(plist)


def make_ipa(path, app_revision, keyboard_revision=None, binary=b"\x00code\x00", symbols=None, extra=None):
    """Payload/VoxtMobile.app with a keyboard extension; keyboard_revision defaults to the app's."""
    keyboard_revision = app_revision if keyboard_revision is None else keyboard_revision
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/VoxtMobile.app/Info.plist", info("com.example.voxtmobile", app_revision))
        z.writestr("Payload/VoxtMobile.app/VoxtMobile", binary)
        z.writestr("Payload/VoxtMobile.app/Frameworks/Lib.framework/Info.plist", info("com.example.lib"))
        z.writestr("Payload/VoxtMobile.app/PlugIns/VoxtKeyboard.appex/Info.plist",
                   info("com.example.voxtmobile.keyboard", keyboard_revision))
        if symbols is not None:
            z.writestr("Symbols/0000.symbols", symbols)
        for name, data in (extra or {}).items():
            z.writestr(name, data)
    return path


class Fixture(unittest.TestCase):
    """A public remote with main at `released` (tagged v1.0.0), a commit only on a side branch,
    and a local export folder whose tree matches `released`."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-gate-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        work = self.tmp / "work"
        work.mkdir()
        git(work, "init", "-q", "-b", "main")
        (work / "README.md").write_text("public\n")
        (work / "tools").mkdir()
        (work / "tools/run.sh").write_text("#!/bin/sh\necho hi\n")
        (work / "tools/run.sh").chmod(0o755)
        (work / ".gitignore").write_text("build/\n")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "first")
        self.released = git(work, "rev-parse", "HEAD")
        git(work, "tag", "-a", "v1.0.0", "-m", "v1.0.0")
        git(work, "checkout", "-q", "-b", "side")
        (work / "side.txt").write_text("side\n")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "side")
        self.side = git(work, "rev-parse", "HEAD")
        git(work, "tag", "-a", "v0.9-side", "-m", "side")
        git(work, "checkout", "-q", "main")
        self.remote = self.tmp / "public.git"
        git(self.tmp, "clone", "-q", "--bare", str(work), str(self.remote))
        self.work = work
        # source-export layout: <export>/tree, export.json, check.json (the scan passed for this digest).
        self.export = self.tmp / "export"
        shutil.copytree(work, self.export / "tree", ignore=shutil.ignore_patterns(".git", "side.txt"))
        (self.export / "export.json").write_text('{"digest": "d1", "files": 3}')
        (self.export / "check.json").write_text('{"digest": "d1", "sha": "x"}')
        self.mirror = self.tmp / "mirror.git"

    def remote_args(self):
        return ["--remote", self.remote, "--mirror", self.mirror]

    def local_args(self):
        return ["--local", self.work, "--export", self.export]

    def assertBlocked(self, result, reason):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(reason, result.stdout + result.stderr)

    def assertPassed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class SourceTests(Fixture):
    """release-gate.py source: a clean checkout of a public commit, or a refusal."""

    def test_checks_out_a_public_tag(self):
        result = gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src")
        self.assertPassed(result)
        self.assertEqual(result.stdout.strip().splitlines()[-1], self.released)
        self.assertEqual(git(self.tmp / "src", "rev-parse", "HEAD"), self.released)
        self.assertEqual(git(self.tmp / "src", "status", "--porcelain", "--ignored"), "")

    def test_reuses_a_clean_checkout(self):
        self.assertPassed(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"))
        self.assertPassed(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"))

    def test_refuses_a_changed_tracked_file(self):
        self.assertPassed(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"))
        (self.tmp / "src/README.md").write_text("edited\n")
        self.assertBlocked(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"), "has changes")

    def test_refuses_an_untracked_or_ignored_file(self):
        self.assertPassed(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"))
        (self.tmp / "src/build").mkdir()
        (self.tmp / "src/build/stale.a").write_text("old build output")
        self.assertBlocked(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"), "has changes")

    def test_refuses_a_checkout_of_another_commit(self):
        self.assertPassed(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"))
        git(self.tmp / "src", "checkout", "-q", "--detach", self.side)
        self.assertBlocked(gate("source", *self.remote_args(), "--tag", "v1.0.0", "--dir", self.tmp / "src"), "is at")

    def test_refuses_a_tag_off_the_public_branch(self):
        self.assertBlocked(gate("source", *self.remote_args(), "--tag", "v0.9-side", "--dir", self.tmp / "src"),
                           "not on the public branch")

    def test_refuses_an_unknown_tag(self):
        self.assertBlocked(gate("source", *self.remote_args(), "--tag", "v9.9.9", "--dir", self.tmp / "src"), "unknown")

    def test_local_mode_checks_out_a_commit_matching_the_export(self):
        result = gate("source", *self.local_args(), "--rev", self.released, "--dir", self.tmp / "src")
        self.assertPassed(result)
        self.assertEqual(result.stdout.strip().splitlines()[-1], self.released)

    def test_local_mode_refuses_a_tree_that_differs_from_the_export(self):
        (self.export / "tree/README.md").write_text("changed after export\n")
        self.assertBlocked(gate("source", *self.local_args(), "--rev", self.released, "--dir", self.tmp / "src"),
                           "differs from the source-export tree")

    def test_local_mode_refuses_an_export_that_did_not_pass_its_check(self):
        (self.export / "check.json").write_text('{"digest": "older"}')
        self.assertBlocked(gate("source", *self.local_args(), "--rev", self.released, "--dir", self.tmp / "src"),
                           "source-export check")

    def test_local_mode_refuses_an_unknown_commit(self):
        self.assertBlocked(gate("source", *self.local_args(), "--rev", "1" * 40, "--dir", self.tmp / "src"), "unknown")


class CheckTests(Fixture):
    """release-gate.py check: what an IPA or DMG says about its source, before upload."""

    def test_passes_an_ipa_built_from_the_public_branch(self):
        self.assertPassed(gate("check", make_ipa(self.tmp / "a.ipa", self.released), *self.remote_args()))

    def test_blocks_a_missing_key(self):
        result = gate("check", make_ipa(self.tmp / "a.ipa", self.released, keyboard_revision=""), *self.remote_args())
        self.assertBlocked(result, "VoxtKeyboard.appex has no VoxtSourceRevision")
        result = gate("check", make_ipa(self.tmp / "b.ipa", None, keyboard_revision=self.released), *self.remote_args())
        self.assertBlocked(result, "VoxtMobile.app has no VoxtSourceRevision")

    def test_blocks_bundles_from_different_commits(self):
        result = gate("check", make_ipa(self.tmp / "a.ipa", self.released, keyboard_revision=self.side), *self.remote_args())
        self.assertBlocked(result, "different commits")

    def test_blocks_an_unknown_commit(self):
        self.assertBlocked(gate("check", make_ipa(self.tmp / "a.ipa", "2" * 40), *self.remote_args()), "unknown")

    def test_blocks_a_commit_off_the_public_branch(self):
        self.assertBlocked(gate("check", make_ipa(self.tmp / "a.ipa", self.side), *self.remote_args()), "not on the public branch")

    def test_blocks_a_local_path(self):
        users = make_ipa(self.tmp / "a.ipa", self.released, binary=b"\x00/Users/you/project/x.go\x00")
        self.assertBlocked(gate("check", users, *self.remote_args()), "local path")
        in_binary = make_ipa(self.tmp / "b.ipa", self.released, binary=b"\x00" + VOLUMES + b"Disk/build/y.swift\x00")
        result = gate("check", in_binary, *self.remote_args())
        self.assertBlocked(result, "VoxtMobile.app/VoxtMobile")
        self.assertNotIn((VOLUMES + b"Disk").decode(), result.stdout + result.stderr, "the report names files, not the paths")

    def test_debug_symbols_for_apples_crash_reports_may_hold_build_paths(self):
        # Symbols/*.symbols at the IPA root go to Apple for crash reports and are never installed on a device.
        # Everything that ships is still checked.
        path = b"\x00" + VOLUMES + b"Disk/build/y.swift\x00"
        result = gate("check", make_ipa(self.tmp / "a.ipa", self.released, symbols=path), *self.remote_args())
        self.assertPassed(result)
        self.assertIn("Symbols/", result.stdout, "the report says what it skipped")
        inside_app = make_ipa(self.tmp / "b.ipa", self.released, extra={"Payload/VoxtMobile.app/Symbols/x.symbols": path})
        self.assertBlocked(gate("check", inside_app, *self.remote_args()), "Payload/VoxtMobile.app/Symbols/x.symbols")
        other_file = make_ipa(self.tmp / "c.ipa", self.released, extra={"Symbols/notes.txt": path})
        self.assertBlocked(gate("check", other_file, *self.remote_args()), "Symbols/notes.txt")

    def test_local_mode_passes_a_commit_matching_the_export(self):
        self.assertPassed(gate("check", make_ipa(self.tmp / "a.ipa", self.released), *self.local_args()))

    def test_local_mode_blocks_an_export_mismatch(self):
        (self.export / "tree/extra.txt").write_text("not in the commit\n")
        self.assertBlocked(gate("check", make_ipa(self.tmp / "a.ipa", self.released), *self.local_args()),
                           "differs from the source-export tree")

    def test_require_remote_blocks_local_mode(self):
        result = gate("check", make_ipa(self.tmp / "a.ipa", self.released), *self.local_args(), "--require-remote")
        self.assertBlocked(result, "--require-remote")

    def test_reads_a_dmg(self):
        folder = self.tmp / "dmg"
        app = folder / "Voxt Connector.app/Contents"
        app.mkdir(parents=True)
        (app / "Info.plist").write_bytes(info("com.example.connector", self.released))
        (app / "MacOS").mkdir()
        (app / "MacOS/Voxt Connector").write_bytes(b"\x00binary\x00")
        good = self.tmp / "good.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-volname", "T", "-srcfolder", folder, good], check=True)
        self.assertPassed(gate("check", good, *self.remote_args()))
        (app / "MacOS/Voxt Connector").write_bytes(b"\x00" + VOLUMES + b"Disk/build/host.go\x00")
        bad = self.tmp / "bad.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-volname", "T", "-srcfolder", folder, bad], check=True)
        self.assertBlocked(gate("check", bad, *self.remote_args()), "local path")

    def test_a_dmg_gets_no_symbols_exemption(self):
        folder = self.tmp / "dmg"
        (folder / "Voxt Connector.app/Contents").mkdir(parents=True)
        (folder / "Voxt Connector.app/Contents/Info.plist").write_bytes(info("com.example.connector", self.released))
        (folder / "Symbols").mkdir()
        (folder / "Symbols/x.symbols").write_bytes(b"\x00" + VOLUMES + b"Disk/y.swift\x00")
        dmg = self.tmp / "s.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-fs", "HFS+", "-volname", "T", "-srcfolder", folder, dmg], check=True)
        self.assertBlocked(gate("check", dmg, *self.remote_args()), "Symbols/x.symbols")

    def test_blocks_an_artifact_with_no_app(self):
        empty = self.tmp / "empty.ipa"
        with zipfile.ZipFile(empty, "w") as z:
            z.writestr("Payload/readme.txt", "nothing")
        self.assertBlocked(gate("check", empty, *self.remote_args()), "no app")

    @unittest.skipUnless(OLD_IPA, "pass --ipa to check a real IPA")
    def test_an_ipa_from_before_the_gate_is_blocked(self):
        result = gate("check", OLD_IPA, *self.remote_args())
        self.assertBlocked(result, "has no VoxtSourceRevision")
        self.assertIn("local path", result.stdout + result.stderr)


class ReleaseTests(Fixture):
    """release-gate.py release: after the check passes, an annotated tag and a release notes draft."""

    TAGGER = "Release Bot <release@example.com>"

    def dmg(self, revision):
        folder = self.tmp / "dmg-src"
        app = folder / "Voxt Connector.app/Contents"
        app.mkdir(parents=True, exist_ok=True)
        (app / "Info.plist").write_bytes(info("com.example.connector", revision))
        path = self.tmp / "VoxtConnector.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-ov", "-fs", "HFS+", "-volname", "T", "-srcfolder", folder, path], check=True)
        return path

    def release(self, *args, tagger=TAGGER):
        extra = ["--tagger", tagger] if tagger else []
        return gate("release", "--version", "v1.0.0", "--notes", self.tmp / "notes.md", *extra, *self.remote_args(), *args)

    def tags(self):
        return git(self.mirror, "tag", "--list").split()

    def test_tags_the_commit_and_writes_notes(self):
        import hashlib
        dmg = self.dmg(self.released)
        result = self.release("--build", "7", "--ipa", make_ipa(self.tmp / "a.ipa", self.released), "--dmg", dmg)
        self.assertPassed(result)
        self.assertEqual(git(self.mirror, "cat-file", "-t", "v1.0.0+7"), "tag", "an annotated tag")
        self.assertEqual(git(self.mirror, "rev-parse", "v1.0.0+7^{commit}"), self.released)
        message = git(self.mirror, "tag", "-l", "--format=%(contents)", "v1.0.0+7")
        digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
        for text in (self.released, "iOS build: 7", digest, "release-gate: ok"):
            self.assertIn(text, message)
        self.assertEqual(git(self.mirror, "tag", "-l", "--format=%(taggername) %(taggeremail)", "v1.0.0+7"),
                         "Release Bot <release@example.com>")
        self.assertRegex(git(self.mirror, "tag", "-l", "--format=%(taggerdate:iso-strict)", "v1.0.0+7"), r"T12:00:00(Z|\+00:00)$",
                         "noon UTC, like source-export's public commits")
        notes = (self.tmp / "notes.md").read_text()
        for text in (self.released, "v1.0.0+7", "7", digest, "release-gate: ok", "How to verify a release"):
            self.assertIn(text, notes)
        self.assertIn("git -C", result.stdout, "prints the push command")
        self.assertNotIn("v1.0.0+7", git(self.remote, "tag", "--list"), "nothing is pushed")

    def test_a_mac_only_release_is_tagged_mac(self):
        self.assertPassed(self.release("--dmg", self.dmg(self.released)))
        self.assertIn("v1.0.0+mac", self.tags())

    def test_refuses_and_tags_nothing_when_the_check_fails(self):
        result = self.release("--build", "7", "--ipa", make_ipa(self.tmp / "a.ipa", self.released, keyboard_revision=""))
        self.assertBlocked(result, "has no VoxtSourceRevision")
        self.assertNotIn("v1.0.0+7", self.tags())
        self.assertFalse((self.tmp / "notes.md").exists())

    def test_refuses_an_existing_tag(self):
        ipa = make_ipa(self.tmp / "a.ipa", self.released)
        self.assertPassed(self.release("--build", "7", "--ipa", ipa))
        self.assertBlocked(self.release("--build", "7", "--ipa", ipa), "already exists")

    def test_refuses_without_a_tagger(self):
        result = self.release("--build", "7", "--ipa", make_ipa(self.tmp / "a.ipa", self.released), tagger=None)
        self.assertBlocked(result, "--tagger")

    def test_local_mode_tags_the_local_public_repo(self):
        result = gate("release", "--version", "v1.0.0", "--build", "3", "--notes", self.tmp / "notes.md", "--tagger", self.TAGGER,
                      *self.local_args(), "--ipa", make_ipa(self.tmp / "a.ipa", self.released))
        self.assertPassed(result)
        self.assertEqual(git(self.work, "rev-parse", "v1.0.0+3^{commit}"), self.released)


class PrebuiltTests(Fixture):
    """CI paths are allowed only inside the third-party frameworks listed in the gate config."""

    LLAMA = "Payload/VoxtMobile.app/Frameworks/llama.framework/llama"
    RUNNER = b"\x00/Users/runner/work/llama.cpp/llama.cpp/ggml/src/ggml.c\x00"

    def config(self):
        path = self.tmp / "gate.toml"
        path.write_text('''
[[prebuilt]]
framework = "llama.framework"
project = "llama.cpp"
version = "b10549"
url = "https://example.com/llama-b10549-xcframework.zip"
sha256 = "636709d4a7b49ac7f2ed6dc8a4de3f278c257cac7248fe40d6a513f671e4bff4"
allow = ["/Users/runner/"]
''')
        return ["--config", path]

    def check(self, extra, binary=b"\x00code\x00"):
        ipa = make_ipa(self.tmp / "a.ipa", self.released, binary=binary, extra=extra)
        return gate("check", ipa, *self.remote_args(), *self.config())

    def test_an_allowlisted_framework_may_hold_ci_paths(self):
        result = self.check({self.LLAMA: self.RUNNER})
        self.assertPassed(result)
        self.assertIn("llama.framework", result.stdout)
        self.assertIn("llama.cpp b10549", result.stdout, "the report names the prebuilt's source")

    def test_this_macs_paths_fail_even_inside_an_allowlisted_framework(self):
        self.assertBlocked(self.check({self.LLAMA: self.RUNNER + b"\x00" + VOLUMES + b"Disk/x.c\x00"}), "llama.framework")
        self.assertBlocked(self.check({self.LLAMA: self.RUNNER + b"\x00/Users/you/project/x.c\x00"}), "local path")

    def test_an_unlisted_framework_may_not_hold_ci_paths(self):
        self.assertBlocked(self.check({"Payload/VoxtMobile.app/Frameworks/Other.framework/Other": self.RUNNER}), "Other.framework")

    def test_ci_paths_outside_a_framework_still_fail(self):
        self.assertBlocked(self.check({}, binary=self.RUNNER), "VoxtMobile.app/VoxtMobile")

    def test_a_framework_named_like_a_listed_one_elsewhere_does_not_count(self):
        self.assertBlocked(self.check({"Payload/VoxtMobile.app/Resources/llama.framework.txt": self.RUNNER}), "local path")

    def test_an_app_inside_a_framework_needs_no_source_commit(self):
        # Sparkle ships Updater.app inside Sparkle.framework; it is the framework's code, not ours.
        updater = "Payload/VoxtMobile.app/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/Info.plist"
        self.assertPassed(self.check({updater: info("org.sparkle-project.Sparkle.Updater")}))

    def test_release_notes_record_the_prebuilt_source(self):
        ipa = make_ipa(self.tmp / "a.ipa", self.released, extra={self.LLAMA: self.RUNNER})
        result = gate("release", "--version", "v1.0.0", "--build", "9", "--ipa", ipa, "--notes", self.tmp / "notes.md",
                      "--tagger", "Release Bot <release@example.com>", *self.remote_args(), *self.config())
        self.assertPassed(result)
        notes = (self.tmp / "notes.md").read_text()
        for text in ("llama.framework", "llama.cpp", "b10549", "https://example.com/llama-b10549-xcframework.zip",
                     "636709d4a7b49ac7f2ed6dc8a4de3f278c257cac7248fe40d6a513f671e4bff4"):
            self.assertIn(text, notes)

    def test_the_shipped_config_records_llama(self):
        import tomllib
        entries = tomllib.loads((TOOLS / "release-gate.toml").read_text())["prebuilt"]
        llama = next(e for e in entries if e["framework"] == "llama.framework")
        self.assertEqual(llama["allow"], ["/Users/runner/"])
        self.assertTrue(llama["url"].startswith("https://github.com/ggml-org/llama.cpp/releases/download/"))
        self.assertRegex(llama["sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(llama["version"])


class UploadTests(Fixture):
    """release-upload.sh runs the upload command only after the check passes."""

    def upload(self, ipa, *mode):
        marker = self.tmp / "uploaded"
        result = subprocess.run(["bash", str(UPLOAD), *map(str, mode), ipa, "--", "touch", str(marker)],
                                capture_output=True, text=True, timeout=120)
        return result, marker.exists()

    def test_uploads_a_passing_ipa(self):
        result, uploaded = self.upload(make_ipa(self.tmp / "a.ipa", self.released), *self.remote_args())
        self.assertPassed(result)
        self.assertTrue(uploaded)

    def test_does_not_upload_a_blocked_ipa(self):
        result, uploaded = self.upload(make_ipa(self.tmp / "a.ipa", "3" * 40), *self.remote_args())
        self.assertBlocked(result, "unknown")
        self.assertFalse(uploaded)

    def test_require_remote_refuses_a_local_upload(self):
        result, uploaded = self.upload(make_ipa(self.tmp / "a.ipa", self.released), *self.local_args(), "--require-remote")
        self.assertBlocked(result, "--require-remote")
        self.assertFalse(uploaded)


class BuildTests(Fixture):
    """release-build.sh builds in the clean checkout and stamps the commit; checked with --dry-run."""

    def build(self, *args, env=None):
        full = {**os.environ, "VOXT_RELEASE_TAGGER": "Release Bot <release@example.com>",
                "VOXT_TEAM_ID": "ABCDE12345", "VOXT_PROFILE_APP": "App Profile",
                "VOXT_PROFILE_KEYBOARD": "Keyboard Profile", **(env or {})}
        return subprocess.run(["bash", str(BUILD), *map(str, args)], capture_output=True, text=True, timeout=120, env=full)

    def test_dry_run_builds_in_the_checkout_with_the_revision_and_path_maps(self):
        out = self.tmp / "out"
        result = self.build(*self.remote_args(), "--tag", "v1.0.0", "--build", "7", "--out", out, "--dry-run")
        self.assertPassed(result)
        text = result.stdout
        src = str(out / "source")
        self.assertIn(f"{src}/tools/build-tailcat-native.sh", text, "the Go library is built from the public checkout")
        self.assertIn(f"{src}/ios/VoxtMobile.xcodeproj", text)
        self.assertIn(f"VOXT_SOURCE_REVISION={self.released}", text)
        self.assertIn("CURRENT_PROJECT_VERSION=7", text)
        self.assertIn(f"-file-prefix-map", text)
        self.assertIn(f"-ffile-prefix-map=", text)
        self.assertIn("release-gate.py check", text, "the IPA is checked after export")
        self.assertIn("release-gate.py release --version v1.0.0 --notes", text, "tags and drafts notes last")
        self.assertIn("--build 7", text)

    def test_refuses_a_dirty_checkout_before_building(self):
        out = self.tmp / "out"
        self.assertPassed(self.build(*self.remote_args(), "--tag", "v1.0.0", "--build", "7", "--out", out, "--dry-run"))
        (out / "source/README.md").write_text("edited\n")
        result = self.build(*self.remote_args(), "--tag", "v1.0.0", "--build", "7", "--out", out, "--dry-run")
        self.assertBlocked(result, "has changes")
        self.assertNotIn("xcodebuild", result.stdout)

    def test_refuses_without_signing_settings(self):
        result = self.build(*self.remote_args(), "--tag", "v1.0.0", "--build", "7", "--out", self.tmp / "out",
                            "--dry-run", env={"VOXT_TEAM_ID": ""})
        self.assertBlocked(result, "VOXT_TEAM_ID")

    def test_refuses_without_a_release_tagger(self):
        result = self.build(*self.remote_args(), "--tag", "v1.0.0", "--build", "7", "--out", self.tmp / "out",
                            "--dry-run", env={"VOXT_RELEASE_TAGGER": ""})
        self.assertBlocked(result, "VOXT_RELEASE_TAGGER")

    MAC_ENV = {"VOXT_TEAM_ID": "", "VOXT_DEVELOPER_ID": "Developer ID Application: Example (ABCDE12345)",
               "VOXT_NOTARY_KEY": "/keys/AuthKey_TEST.p8", "VOXT_NOTARY_KEY_ID": "TESTKEYID1",
               "VOXT_NOTARY_ISSUER": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"}

    def test_mac_dry_run_signs_notarizes_then_checks_and_tags(self):
        out = self.tmp / "out"
        result = self.build(*self.local_args(), "--rev", self.released, "--version", "v2.0.0", "--mac", "--out", out, "--dry-run",
                            env=self.MAC_ENV)
        self.assertPassed(result)
        text = result.stdout
        self.assertIn(f"{out}/source/tools/build-connector.py --source-revision {self.released}", text)
        sign = next(line for line in text.splitlines() if "release-mac.py sign" in line)
        for line in text.splitlines():
            if "release-mac.py sign" in line:
                self.assertIn("--strip-debug", line, "every Mac app is stripped of build paths before signing")
        self.assertIn("--identity Developer ID Application: Example (ABCDE12345) --team ABCDE12345", sign)
        # Voxt's ConnectorLinkServer only trusts a Connector with Voxt's team and this identifier.
        self.assertIn('certificate leaf[subject.OU] = "ABCDE12345" and identifier "com.voxtmobile.connector"', sign)
        steps = ["release-mac.py sign", "release-mac.py dmg", "release-mac.py notarize", "release-gate.py check", "release-gate.py release"]
        self.assertEqual([s for s in steps if s in text], steps)
        self.assertEqual(sorted(steps, key=text.index), steps, "notarized and stapled before the check and the tag")
        self.assertNotIn("/keys/AuthKey_TEST.p8", text.split("release-mac.py notarize")[0], "the key path only goes to notarize")

    def test_mac_refuses_without_developer_id_or_notary_settings(self):
        for name in ("VOXT_DEVELOPER_ID", "VOXT_NOTARY_KEY_ID"):
            result = self.build(*self.local_args(), "--rev", self.released, "--version", "v2.0.0", "--mac", "--out",
                                self.tmp / "out", "--dry-run", env={**self.MAC_ENV, name: ""})
            self.assertBlocked(result, name)


class SourceTreeTests(unittest.TestCase):
    """The shipped targets carry the key, and Go builds drop local paths."""

    def test_every_go_build_trims_paths(self):
        for script in sorted(TOOLS.glob("*.sh")):
            for line in script.read_text().splitlines():
                if '"$GO_BIN" build' in line or line.strip().startswith("go build"):
                    self.assertIn("-trimpath", line, f"{script.name}: {line.strip()}")

    def test_ios_bundles_carry_the_source_revision(self):
        for plist in ("ios/App/Info.plist", "ios/Keyboard/Info.plist"):
            values = plistlib.loads((ROOT / plist).read_bytes())
            self.assertEqual(values.get("VoxtSourceRevision"), "$(VOXT_SOURCE_REVISION)", plist)

    def test_connector_build_stamps_the_source_revision_before_signing(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("build_connector", TOOLS / "build-connector.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Voxt Connector.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(info("com.example.connector"))
            module.add_source_revision(app, "a" * 40)
            values = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(values["VoxtSourceRevision"], "a" * 40)
            with self.assertRaises(SystemExit):
                module.add_source_revision(app, "not-a-commit")


if __name__ == "__main__":
    unittest.main()
