#!/usr/bin/env python3
"""Tests for the Release build in tools/omni-dev.sh (`release OUT_DIR`, `build-command debug|release`).

Usage: python3 -I tools/test-omni-dev-release.py [-v]
Checks the xcodebuild arguments each configuration uses and that release refuses to overwrite an
existing app. Runs no xcodebuild: a fake on PATH records any call.
"""
import os
import plistlib
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
SCRIPT = TOOLS / "omni-dev.sh"


def omni(*args, env=None):
    return subprocess.run(["bash", str(SCRIPT), *map(str, args)], capture_output=True, text=True, timeout=60,
                          env={**os.environ, **(env or {})})


def command(configuration):
    result = omni("build-command", configuration)
    assert result.returncode == 0, result.stderr
    return result.stdout.splitlines()


class BuildCommandTests(unittest.TestCase):
    def test_release_maps_source_and_build_folders_out_of_debug_info(self):
        args = command("release")
        source = os.environ.get("OMNI_DEV_SOURCE_DIR", str(ROOT / "build/omni-source"))
        derived = str(ROOT / "build/omni-dev-release")
        self.assertIn("Release", args[args.index("-configuration") + 1])
        self.assertEqual(args[args.index("-derivedDataPath") + 1], derived)
        swift = next(a for a in args if a.startswith("OTHER_SWIFT_FLAGS="))
        self.assertEqual(shlex.split(swift.split("=", 1)[1]),
                         ["$(inherited)", "-file-prefix-map", f"{source}=/voxt-source", "-file-prefix-map", f"{derived}=/DerivedData"],
                         "paths with spaces stay one argument each")
        c = next(a for a in args if a.startswith("OTHER_CFLAGS="))
        self.assertEqual(shlex.split(c.split("=", 1)[1]),
                         ["$(inherited)", f"-ffile-prefix-map={source}=/voxt-source", f"-ffile-prefix-map={derived}=/DerivedData"])

    def test_both_configurations_keep_build_output_on_the_project_disk(self):
        for configuration in ("debug", "release"):
            args = command(configuration)
            self.assertTrue(args[args.index("-resultBundlePath") + 1].startswith(str(ROOT / "build/")), configuration)
            self.assertEqual(args[args.index("-packageCachePath") + 1], str(ROOT / "build/swiftpm-cache"), configuration)
            self.assertEqual(args[args.index("-jobs") + 1], "4", "a shared Mac: four compile jobs")

    def test_debug_is_the_development_build_as_before(self):
        args = command("debug")
        self.assertEqual(args[args.index("-configuration") + 1], "Debug")
        self.assertEqual(args[args.index("-derivedDataPath") + 1], str(ROOT / "build/omni-dev"))
        self.assertFalse(any("prefix-map" in a for a in args), "debugger source paths stay real")

    def test_an_unknown_configuration_is_refused(self):
        self.assertNotEqual(omni("build-command", "profile").returncode, 0)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="omni-release-"))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        self.calls = self.tmp / "xcodebuild-calls.txt"
        (bin_dir / "xcodebuild").write_text(f"#!/bin/sh\necho \"$*\" >> '{self.calls}'\nexit 1\n")
        (bin_dir / "xcodebuild").chmod(0o755)
        self.env = {"PATH": f"{bin_dir}:{os.environ['PATH']}"}

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def test_release_needs_an_output_folder(self):
        result = omni("release", env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_release_refuses_to_overwrite_an_app(self):
        out = self.tmp / "release"
        (out / "Voxt Omni Dev.app/Contents").mkdir(parents=True)
        result = omni("release", out, env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already has", result.stderr)
        self.assertFalse(self.calls.exists(), "refused before any build")

    def test_release_builds_stamps_embeds_then_copies_out(self):
        text = SCRIPT.read_text()
        body = text[text.index("release() {"):text.index("\n}\n", text.index("release() {"))]
        steps = ["prepare", 'build_command release', 'strip_debug "$release_app"', 'stamp "$release_app"',
                 'ditto "$release_app"', 'ditto "$release_dsym"']
        for step in steps:
            self.assertIn(step, body)
        self.assertEqual(sorted(steps, key=body.index), steps)

    def test_strip_debug_removes_object_paths_and_keeps_the_app_working(self):
        # The linker records each object file's absolute path for debugging (over a thousand in a
        # Release Voxt Omni Dev); the dSYM keeps them for symbolication, the shipped binary must not.
        app = self.tmp / "Probe.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Probe", "CFBundleIdentifier": "com.example.probe"}))
        source = self.tmp / "probe.c"
        source.write_text("int helper(int x) { return x - 1; }\nint main(void) { return helper(1); }\n")
        objects = self.tmp / "objects"
        objects.mkdir()
        subprocess.run(["clang", "-g", "-c", str(source), "-o", str(objects / "probe.o")], check=True)
        subprocess.run(["clang", str(objects / "probe.o"), "-o", str(app / "Contents/MacOS/Probe")], check=True)
        binary = app / "Contents/MacOS/Probe"
        local = re.compile(rb"/(?:Users|Volumes)/")
        self.assertTrue(local.search(binary.read_bytes()), "the probe must start with a local path, or the test proves nothing")
        result = omni("strip-debug", app, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(local.search(binary.read_bytes()))
        self.assertEqual(subprocess.run([str(binary)]).returncode, 0, "still runs")

    def test_strip_debug_needs_the_app_executable(self):
        app = self.tmp / "Empty.app"
        (app / "Contents").mkdir(parents=True)
        self.assertNotEqual(omni("strip-debug", app, env=self.env).returncode, 0)

    def test_no_build_embeds_a_tailcat_helper(self):
        # The phone reaches Voxt through Voxt Connector's helper; Voxt Omni Dev carries none of its own.
        text = SCRIPT.read_text()
        for function in ("build() {", "release() {"):
            body = text[text.index(function):text.index("\n}\n", text.index(function))]
            self.assertNotIn("tailcat", body.lower(), function)

    def test_debug_build_uses_the_debug_command(self):
        text = SCRIPT.read_text()
        body = text[text.index("build() {"):text.index("\n}\n", text.index("build() {"))]
        self.assertIn("build_command debug", body)


if __name__ == "__main__":
    unittest.main()
