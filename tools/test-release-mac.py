#!/usr/bin/env python3
"""Tests for tools/release-mac.py: Developer ID signing, the release DMG and notarization.

Usage: python3 -I tools/test-release-mac.py [-v]
Signing runs for real with the ad-hoc identity on small bundles under $TMPDIR. Notarization runs
against a fake xcrun and spctl on PATH, so nothing is sent to Apple.
"""
import contextlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
MAC = TOOLS / "release-mac.py"
# The pinned dmgbuild that release-mac.py installs (tools/dmg-requirements.txt).
VENV = Path(os.environ.get("VOXT_DMGBUILD_VENV") or TOOLS.parent / "build/dmgbuild-venv")


def tool(*args, env=None):
    return subprocess.run([sys.executable, "-I", str(MAC), *map(str, args)], capture_output=True, text=True,
                          timeout=180, env={**os.environ, **(env or {})})


def bundle(path, identifier, executable="main"):
    """A minimal app bundle whose executable is a real Mach-O (a copy of /usr/bin/true)."""
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(
        {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL"}))
    shutil.copyfile("/usr/bin/true", contents / "MacOS" / executable)
    (contents / "MacOS" / executable).chmod(0o755)
    return path


def details(path):
    return subprocess.run(["codesign", "-dvvv", str(path)], capture_output=True, text=True).stderr


class SignTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-mac-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.app = bundle(self.tmp / "Voxt Connector.app", "com.example.connector")
        helpers = self.app / "Contents/Helpers"
        helpers.mkdir()
        shutil.copyfile("/usr/bin/true", helpers / "helper")
        (helpers / "helper").chmod(0o755)
        bundle(self.app / "Contents/Library/LoginItems/Inner.app", "com.example.inner")

    def sign(self, *extra):
        return tool("sign", "--identity", "-", "--no-timestamp", *extra, self.app)

    def test_signs_nested_code_with_the_hardened_runtime(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for target in (self.app / "Contents/Helpers/helper", self.app / "Contents/Library/LoginItems/Inner.app", self.app):
            info = details(target)
            self.assertIn("runtime", info.split("flags=")[1].split("\n")[0], f"{target.name}: {info}")
        verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        order = [line for line in result.stdout.splitlines() if line.startswith("signed ")]
        self.assertEqual([Path(line.removeprefix("signed ")).name for line in order], ["helper", "Inner.app", "Voxt Connector.app"],
                         "inside out: nested code before the bundle that seals it")

    def test_keeps_the_entitlements(self):
        entitlements = self.tmp / "e.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.network.client": True}))
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", entitlements, self.app], check=True, capture_output=True)
        self.assertEqual(self.sign().returncode, 0)
        shown = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(self.app)], capture_output=True).stdout
        self.assertIn(b"com.apple.security.network.client", shown)

    def test_drops_the_debugging_entitlement_notarization_refuses(self):
        # Apple's notary service rejects a Developer ID app that asks for get-task-allow; Voxt's Release build carries it.
        entitlements = self.tmp / "e.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True, "com.apple.security.network.client": True}))
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", entitlements, self.app], check=True, capture_output=True)
        self.assertEqual(self.sign().returncode, 0)
        shown = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(self.app)], capture_output=True).stdout
        self.assertNotIn(b"get-task-allow", shown)
        self.assertIn(b"com.apple.security.network.client", shown, "other entitlements stay")

    def test_strip_debug_removes_build_paths_from_the_app_executable(self):
        # A Release build's executable carries linker and source paths; the release gate refuses them.
        local = re.compile(rb"/(?:Users|Volumes)/")
        objects = self.tmp / "objects"
        objects.mkdir()
        (objects / "main.c").write_text("int helper(int x) { return x - 1; }\nint main(void) { return helper(1); }\n")
        subprocess.run(["clang", "-g", "-c", str(objects / "main.c"), "-o", str(objects / "main.o")], check=True)
        executable = self.app / "Contents/MacOS/main"
        subprocess.run(["clang", str(objects / "main.o"), "-o", str(executable)], check=True)
        self.assertTrue(local.search(executable.read_bytes()), "the probe must start with a local path")
        self.assertEqual(self.sign("--strip-debug").returncode, 0)
        self.assertIsNone(local.search(executable.read_bytes()))
        self.assertEqual(subprocess.run([str(executable)]).returncode, 0, "still runs")
        verify = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.app)], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_refuses_another_team(self):
        result = self.sign("--team", "ABCDE12345")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not signed by team ABCDE12345", result.stdout + result.stderr)

    def test_checks_a_code_requirement(self):
        good = self.sign("--requirement", 'identifier "com.example.connector"')
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        bad = self.sign("--requirement", 'identifier "com.voxt.VoxtConnector"')
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("does not satisfy", bad.stdout + bad.stderr)

    def test_makes_a_dmg_with_the_apps(self):
        self.assertEqual(self.sign().returncode, 0)
        dmg = self.tmp / "out/Voxt.dmg"
        result = tool("dmg", "--identity", "-", "--no-timestamp", "--volname", "Voxt", "--out", dmg, self.app)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(dmg.is_file())
        self.assertIn("Identifier=", details(dmg), "the DMG itself is signed")
        attached = subprocess.run(["hdiutil", "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", str(dmg)],
                                  capture_output=True, check=True)
        mount = [e["mount-point"] for e in plistlib.loads(attached.stdout)["system-entities"] if "mount-point" in e][0]
        try:
            self.assertTrue((Path(mount) / "Voxt Connector.app/Contents/Helpers/helper").is_file())
            self.assertTrue((Path(mount) / "Applications").is_symlink(), "drag-to-Applications link")
        finally:
            subprocess.run(["hdiutil", "detach", "-quiet", mount])


@contextlib.contextmanager
def mounted(dmg):
    attached = subprocess.run(["hdiutil", "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", str(dmg)],
                              capture_output=True, check=True)
    mount = [e["mount-point"] for e in plistlib.loads(attached.stdout)["system-entities"] if "mount-point" in e][0]
    try:
        yield Path(mount)
    finally:
        subprocess.run(["hdiutil", "detach", "-quiet", mount])


class DmgLayoutTests(unittest.TestCase):
    """The DMG window: apps on the left, an arrow, Applications on the right, the guide below, on a background."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-dmg-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.apps = [bundle(self.tmp / "Voxt Omni Dev.app", "com.example.voxt"),
                     bundle(self.tmp / "Voxt Connector.app", "com.example.connector")]
        signed = tool("sign", "--identity", "-", "--no-timestamp", *self.apps)
        self.assertEqual(signed.returncode, 0, signed.stdout + signed.stderr)
        self.guide = self.tmp / "Start Here.html"
        self.guide.write_text("<!doctype html><title>Start here</title>\n")
        self.background = self.tmp / "background.svg"
        self.background.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="660" height="400">'
                                   '<rect width="660" height="400" fill="#F7F6F2"/></svg>\n')
        self.dmg = self.tmp / "out/Voxt Mobile.dmg"

    def make(self, *extra):
        result = tool("dmg", "--identity", "-", "--no-timestamp", "--volname", "Voxt Mobile", "--out", self.dmg,
                      *extra, *self.apps)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Identifier=", details(self.dmg), "the DMG itself is signed")

    def test_extra_files_sit_at_the_top_level_next_to_the_apps(self):
        self.make("--extra", self.guide, "--background", self.background)
        with mounted(self.dmg) as mount:
            self.assertEqual((mount / "Start Here.html").read_text(), self.guide.read_text())
            for app in self.apps:
                self.assertTrue((mount / app.name / "Contents/MacOS/main").is_file())
                verify = subprocess.run(["codesign", "--verify", "--strict", str(mount / app.name)], capture_output=True, text=True)
                self.assertEqual(verify.returncode, 0, f"{app.name} keeps its signature: {verify.stderr}")
            self.assertTrue((mount / "Applications").is_symlink(), "drag-to-Applications link")
            self.assertEqual(os.readlink(mount / "Applications"), "/Applications")

    def test_window_layout_puts_apps_left_applications_right_and_the_guide_below(self):
        self.make("--extra", self.guide, "--background", self.background)
        with mounted(self.dmg) as mount:
            self.assertTrue((mount / ".DS_Store").is_file(), "Finder's window layout")
            backgrounds = list(mount.glob(".background*"))
            self.assertTrue(backgrounds, "a background picture: " + ", ".join(p.name for p in mount.iterdir()))
            # Read the layout back with the same pinned ds_store that wrote it.
            reader = subprocess.run([str(VENV / "bin/python"), "-I", "-c", """
import json, sys
from ds_store import DSStore
with DSStore.open(sys.argv[1], "r") as store:
    spots = {entry.filename: list(entry.value) for entry in store if entry.code == b"Iloc"}
    view = store["."]["icvp"]
print(json.dumps({"spots": spots, "background": view.get("backgroundType"), "alias": "backgroundImageAlias" in view}))
""", str(mount / ".DS_Store")], capture_output=True, text=True, timeout=60)
            self.assertEqual(reader.returncode, 0, reader.stderr)
            layout = json.loads(reader.stdout)
        spots = layout["spots"]
        omni, connector = spots["Voxt Omni Dev.app"], spots["Voxt Connector.app"]
        applications, guide = spots["Applications"], spots["Start Here.html"]
        self.assertEqual(omni[1], connector[1], "the two apps side by side")
        self.assertLess(max(omni[0], connector[0]), applications[0], "Applications to the right of both apps")
        self.assertEqual(applications[1], omni[1], "on the same row as the apps")
        self.assertGreater(guide[1], omni[1], "the guide below the row")
        self.assertEqual(layout["background"], 2, "a picture background")
        self.assertTrue(layout["alias"])

    def test_the_only_volume_path_is_the_layouts_link_to_its_own_background(self):
        # The release gate refuses local paths; Finder's background link names the DMG's own volume.
        self.make("--extra", self.guide, "--background", self.background)
        local = re.compile(rb"/(?:Users|Volumes)/[^\x00\n\r\"']*")
        with mounted(self.dmg) as mount:
            hits = {str(p.relative_to(mount)): [m.group() for m in local.finditer(p.read_bytes())]
                    for p in mount.rglob("*") if p.is_file() and not p.is_symlink()}
        hits = {name: found for name, found in hits.items() if found}
        self.assertEqual(list(hits), [".DS_Store"], hits)
        for found in hits[".DS_Store"]:
            self.assertTrue(found.startswith(b"/" + b"Volumes/Voxt Mobile"), found)

    def test_refuses_a_missing_extra_file(self):
        result = tool("dmg", "--identity", "-", "--no-timestamp", "--volname", "Voxt Mobile", "--out", self.dmg,
                      "--extra", self.tmp / "missing.html", *self.apps)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing.html", result.stdout + result.stderr)
        self.assertFalse(self.dmg.exists())


class NotarizeTests(unittest.TestCase):
    """xcrun and spctl are fakes that log their arguments and answer from environment variables."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="release-notary-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.dmg = self.tmp / "Voxt.dmg"
        self.dmg.write_bytes(b"dmg")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        log = self.tmp / "calls.txt"
        (bin_dir / "xcrun").write_text(f"""#!/bin/sh
echo "xcrun $*" >> '{log}'
case "$1 $2" in
  "notarytool submit") echo "$FAKE_SUBMIT"; exit 0 ;;
  "notarytool log") echo '{{"issues": []}}'; exit 0 ;;
  "stapler staple") exit ${{FAKE_STAPLE:-0}} ;;
  "stapler validate") exit 0 ;;
esac
exit 1
""")
        (bin_dir / "spctl").write_text(f"""#!/bin/sh
echo "spctl $*" >> '{log}'
printf '%s\\n' "$FAKE_SPCTL" >&2
exit ${{FAKE_SPCTL_CODE:-0}}
""")
        for name in ("xcrun", "spctl"):
            (bin_dir / name).chmod(0o755)
        self.log = log
        self.env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "VOXT_NOTARY_KEY": str(self.tmp / "AuthKey_TEST.p8"),
                    "VOXT_NOTARY_KEY_ID": "TESTKEYID1", "VOXT_NOTARY_ISSUER": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                    "FAKE_SUBMIT": json.dumps({"id": "11111111-2222-3333-4444-555555555555", "status": "Accepted"}),
                    "FAKE_SPCTL": f"{self.dmg}: accepted\nsource=Notarized Developer ID"}
        (self.tmp / "AuthKey_TEST.p8").write_text("not a real key")

    def notarize(self, **env):
        return tool("notarize", self.dmg, "--log", self.tmp / "notary.json", env={**self.env, **env})

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_submits_staples_and_checks_gatekeeper(self):
        result = self.notarize()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn(f"notarytool submit {self.dmg} --key {self.tmp}/AuthKey_TEST.p8 --key-id TESTKEYID1", calls)
        self.assertIn("--wait", calls)
        self.assertLess(calls.index("notarytool submit"), calls.index("stapler staple"))
        self.assertIn(f"spctl -a -t open --context context:primary-signature -vv {self.dmg}", calls)
        record = json.loads((self.tmp / "notary.json").read_text())
        self.assertEqual(record["id"], "11111111-2222-3333-4444-555555555555")
        self.assertIn("source=Notarized Developer ID", record["spctl"])
        self.assertNotIn("not a real key", result.stdout + result.stderr + (self.tmp / "notary.json").read_text())

    def test_refuses_a_rejected_submission_and_saves_apples_log(self):
        result = self.notarize(FAKE_SUBMIT=json.dumps({"id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "status": "Invalid"}))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid", result.stdout + result.stderr)
        self.assertIn("notarytool log AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", self.calls())
        self.assertNotIn("stapler staple", self.calls())

    def test_refuses_when_gatekeeper_does_not_see_notarization(self):
        result = self.notarize(FAKE_SPCTL=f"{self.dmg}: accepted\nsource=Developer ID")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Notarized Developer ID", result.stdout + result.stderr)
        result = self.notarize(FAKE_SPCTL=f"{self.dmg}: rejected", FAKE_SPCTL_CODE="3")
        self.assertNotEqual(result.returncode, 0)

    def test_refuses_without_the_api_key_settings(self):
        result = self.notarize(VOXT_NOTARY_KEY_ID="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VOXT_NOTARY_KEY_ID", result.stdout + result.stderr)
        self.assertNotIn("notarytool", self.calls())

    def test_refuses_when_stapling_fails(self):
        result = self.notarize(FAKE_STAPLE="65")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("staple", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
