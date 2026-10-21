"""Build orchestration contracts; fixture runner never launches an app."""
import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ConnectorBuildTests(unittest.TestCase):
    def test_sources_and_scheme_ship_in_repository(self):
        app = ROOT / "mac/VoxtConnector"
        self.assertTrue((app / "Sources/VoxtConnectorApp.swift").is_file())
        self.assertTrue((app / "project.yml").is_file())
        self.assertTrue((app / "VoxtConnector.xcodeproj/xcshareddata/xcschemes/VoxtConnector.xcscheme").is_file())
        self.assertNotIn("app-draft", (app / "project.yml").read_text())

    def test_builder_signs_runtime_then_app_with_timeout(self):
        spec = importlib.util.spec_from_file_location("connector_build", ROOT / "tools/build-connector.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        calls = []
        def run(args, **kwargs):
            calls.append((args, kwargs))
            class Result: stderr = "flags=0x10000(runtime)"
            return Result()
        app = ROOT / "build/fixture/Voxt Connector.app"
        module.sign(app, "fixture-identity", run=run)
        self.assertEqual([call[0][-1] for call in calls[:2]],
                         [str(app / "Contents/Helpers/voxt-tailcat-host"), str(app)])
        self.assertTrue(all(call[1]["timeout"] == 90 for call in calls))
        self.assertEqual(calls[2][0][1:4], ["--verify", "--deep", "--strict"])

    def test_helper_and_app_are_signed_with_the_hardened_runtime(self):
        # Voxt trusts the Connector by signature only with the hardened runtime: without it an
        # injected library passed the signature check.
        spec = importlib.util.spec_from_file_location("connector_build", ROOT / "tools/build-connector.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        calls = []
        def run(args, **kwargs):
            calls.append(args)
            class Result: stderr = "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1"
            return Result()
        app = ROOT / "build/fixture/Voxt Connector.app"
        module.sign(app, "fixture-identity", run=run)
        signing = [call for call in calls if "--sign" in call]
        self.assertEqual(len(signing), 2)
        self.assertTrue(all(call[call.index("--options") + 1] == "runtime" for call in signing if "--options" in call))
        self.assertTrue(all("--options" in call for call in signing))

    def test_build_fails_when_a_signature_lacks_the_runtime_flag(self):
        spec = importlib.util.spec_from_file_location("connector_build", ROOT / "tools/build-connector.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        def run(args, **kwargs):
            class Result: stderr = "CodeDirectory v=20400 size=1 flags=0x0(none) hashes=1+1"
            return Result()
        with self.assertRaises(SystemExit):
            module.sign(Path("/nonexistent/Voxt Connector.app"), "fixture-identity", run=run)

    def _builder(self):
        spec = importlib.util.spec_from_file_location("connector_build", ROOT / "tools/build-connector.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _bare_app(self, folder):
        app = Path(folder) / "Voxt Connector.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        plistlib_dump(app / "Contents/Info.plist", {"CFBundleIdentifier": "com.voxtmobile.connector"})
        return app

    def test_icon_check_fails_on_a_bundle_without_an_icon(self):
        # Without Contents/Resources the Dock shows a blank icon.
        builder = self._builder()
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(SystemExit):
                builder.check_icon(self._bare_app(folder))

    def test_add_icon_copies_the_icns_and_names_it_in_info_plist(self):
        builder = self._builder()
        with tempfile.TemporaryDirectory() as folder:
            app = self._bare_app(folder)
            builder.add_icon(app)
            builder.check_icon(app)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleIconFile"], "AppIcon")
            self.assertEqual(info["CFBundleIdentifier"], "com.voxtmobile.connector")
            self.assertEqual((app / "Contents/Resources/AppIcon.icns").read_bytes()[:4], b"icns")

    def test_icon_check_fails_when_the_plist_names_a_missing_file(self):
        builder = self._builder()
        with tempfile.TemporaryDirectory() as folder:
            app = self._bare_app(folder)
            plistlib_dump(app / "Contents/Info.plist", {"CFBundleIconFile": "AppIcon"})
            with self.assertRaises(SystemExit):
                builder.check_icon(app)


def plistlib_dump(path, value):
    path.write_bytes(plistlib.dumps(value))


if __name__ == "__main__": unittest.main()
