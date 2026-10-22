#!/usr/bin/env python3
"""Tests for `tools/omni-dev.sh stamp APP`: Voxt Omni Dev records the commits it was built from.

Usage: python3 -I tools/test-omni-dev-stamp.py [-v]
Each test copies omni-dev.sh into a throwaway voxt-mobile repo, pins it to a throwaway upstream
checkout, and stamps a small app bundle. Runs no xcodebuild.
"""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
SCRIPT = TOOLS / "omni-dev.sh"


def git(cwd, *args):
    env = {**os.environ, "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", *map(str, args)], cwd=cwd, check=True, capture_output=True, text=True, env=env).stdout.strip()


class StampTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="omni-stamp-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.upstream = self.tmp / "omni-source"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q")
        (self.upstream / "README").write_text("upstream\n")
        git(self.upstream, "add", "-A")
        git(self.upstream, "commit", "-q", "-m", "upstream")
        self.pinned = git(self.upstream, "rev-parse", "HEAD")
        self.repo = self.tmp / "voxt-mobile"
        (self.repo / "tools").mkdir(parents=True)
        text = SCRIPT.read_text()
        start = text.index("pinned_revision=") + len("pinned_revision=")
        text = text[:start] + self.pinned + text[text.index("\n", start):]
        (self.repo / "tools/omni-dev.sh").write_text(text)
        shutil.copyfile(TOOLS / "build-connector.py", self.repo / "tools/build-connector.py")
        config = self.repo / "mac/VoxtConnector/Config"
        config.mkdir(parents=True)
        shutil.copyfile(TOOLS.parent / "mac/VoxtConnector/Config/Signing.shared.xcconfig", config / "Signing.shared.xcconfig")
        (self.repo / ".gitignore").write_text("build/\nmac/VoxtConnector/Config/Signing.local.xcconfig\n")
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "public")
        self.commit = git(self.repo, "rev-parse", "HEAD")
        self.app = self.repo / "build/omni-dev/Voxt Omni Dev.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(
            {"CFBundleIdentifier": "com.example.omni.dev", "CFBundleExecutable": "Voxt Omni Dev"}))
        shutil.copyfile("/usr/bin/true", self.app / "Contents/MacOS/Voxt Omni Dev")
        (self.app / "Contents/MacOS/Voxt Omni Dev").chmod(0o755)

    def stamp(self, env=None):
        full = {**os.environ, "OMNI_DEV_SOURCE_DIR": str(self.upstream), "VOXT_CONNECTOR_SIGNING_LOCAL": "", **(env or {})}
        return subprocess.run(["bash", str(self.repo / "tools/omni-dev.sh"), "stamp", str(self.app)], capture_output=True,
                              text=True, timeout=120, env=full)

    def info(self):
        return plistlib.loads((self.app / "Contents/Info.plist").read_bytes())

    def test_stamps_both_commits_and_keeps_a_valid_signature(self):
        result = self.stamp()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.info().get("VoxtSourceRevision"), self.commit)
        self.assertEqual(self.info().get("VoxtUpstreamRevision"), self.pinned)
        verify = subprocess.run(["codesign", "--verify", "--strict", str(self.app)], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_records_the_connector_id_the_connector_is_built_with(self):
        # Voxt Omni Dev trusts on its Connector socket exactly the ID build-connector.py gives the Connector.
        self.assertEqual(self.stamp().returncode, 0)
        self.assertEqual(self.info().get("VoxtConnectorBundleIdentifier"), "com.voxt.VoxtConnector")
        (self.repo / "mac/VoxtConnector/Config/Signing.local.xcconfig").write_text(
            "VOXT_CONNECTOR_BUNDLE_ID = com.example.official.connector\n")
        result = self.stamp()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.info().get("VoxtConnectorBundleIdentifier"), "com.example.official.connector")
        self.assertEqual(self.info().get("VoxtSourceRevision"), self.commit, "the private file is not a change to the source")
        release = self.tmp / "release.xcconfig"
        release.write_text("VOXT_CONNECTOR_BUNDLE_ID = com.example.release.connector\n")
        self.assertEqual(self.stamp(env={"VOXT_CONNECTOR_SIGNING_LOCAL": str(release)}).returncode, 0)
        self.assertEqual(self.info().get("VoxtConnectorBundleIdentifier"), "com.example.release.connector")
        result = self.stamp(env={"VOXT_CONNECTOR_SIGNING_LOCAL": str(self.tmp / "missing.xcconfig")})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VOXT_CONNECTOR_SIGNING_LOCAL", result.stderr)

    def test_an_uncommitted_change_leaves_the_source_commit_out(self):
        self.assertEqual(self.stamp().returncode, 0)
        (self.repo / "tools/omni-dev.sh").write_text((self.repo / "tools/omni-dev.sh").read_text() + "\n# edit\n")
        result = self.stamp()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("VoxtSourceRevision", self.info(), "a stamp from an earlier clean build is removed too")
        self.assertEqual(self.info().get("VoxtUpstreamRevision"), self.pinned)
        self.assertIn("release gate", result.stderr)

    def test_an_untracked_file_also_counts_as_a_change(self):
        self.assertEqual(self.stamp().returncode, 0)
        self.assertIn("VoxtSourceRevision", self.info())
        (self.repo / "notes.txt").write_text("private\n")
        self.stamp()
        self.assertNotIn("VoxtSourceRevision", self.info())

    def test_refuses_an_upstream_checkout_off_the_pin(self):
        (self.upstream / "README").write_text("moved\n")
        git(self.upstream, "commit", "-q", "-am", "moved")
        result = self.stamp()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the pinned", result.stderr)
        self.assertNotIn("VoxtUpstreamRevision", self.info())

    def test_the_stamped_app_passes_the_release_gate(self):
        self.assertEqual(self.stamp().returncode, 0)
        remote = self.tmp / "public.git"
        git(self.tmp, "clone", "-q", "--bare", self.repo, remote)
        folder = self.tmp / "dmg"
        shutil.copytree(self.app, folder / self.app.name, symlinks=True)
        result = subprocess.run([sys.executable, "-I", str(TOOLS / "release-gate.py"), "check", str(folder), "--remote", str(remote),
                                 "--mirror", str(self.tmp / "mirror.git")], capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_build_stamps_after_compiling(self):
        text = SCRIPT.read_text()
        body = text[text.index("build() {"):text.index("\n}\n", text.index("build() {"))]
        self.assertIn('stamp "$app_path"', body)
        self.assertLess(body.index('xcodebuild "${xcodebuild_args[@]}"'), body.index('stamp "$app_path"'))


if __name__ == "__main__":
    unittest.main()
