#!/usr/bin/env python3
"""Mac release signing: Developer ID signatures, the release DMG, and notarization.

  release-mac.py sign --identity ID [--team TEAM] [--requirement REQ] [--strip-debug] [--no-timestamp] APP...
      Signs every nested helper, bundle and the app itself, inside out, with the hardened runtime and
      a secure timestamp, keeping entitlements except get-task-allow (the notary service refuses it). Then checks the signature, the team of every signed
      piece, and REQ (a code requirement such as the one Voxt checks before it trusts the Connector).
  release-mac.py dmg --identity ID --volname NAME --out DMG [--no-timestamp] APP...
      Puts the signed apps and an Applications link on a compressed DMG and signs the DMG.
  release-mac.py notarize DMG --log FILE
      xcrun notarytool submit --wait with the App Store Connect API key in VOXT_NOTARY_KEY (path),
      VOXT_NOTARY_KEY_ID and VOXT_NOTARY_ISSUER; on Accepted, staples the ticket and requires Gatekeeper
      (spctl) to report "source=Notarized Developer ID". FILE records the submission ID and the spctl output.
The identity "-" signs ad hoc, for tests.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BUNDLES = (".app", ".appex", ".framework", ".xpc", ".bundle")
MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"}


class Refused(Exception):
    pass


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=kwargs.pop("timeout", 300), **kwargs)


def is_macho(path):
    with open(path, "rb") as f:
        return f.read(4) in MACHO


def main_executable(bundle):
    info = bundle / "Contents/Info.plist" if (bundle / "Contents").is_dir() else bundle / "Info.plist"
    if not info.is_file():
        resources = list(bundle.glob("Versions/*/Resources/Info.plist"))
        info = resources[0] if resources else info
    try:
        name = plistlib.loads(info.read_bytes()).get("CFBundleExecutable")
    except (OSError, plistlib.InvalidFileException):
        return set()
    if not name:
        return set()
    return {bundle / "Contents/MacOS" / name, bundle / name, *bundle.glob(f"Versions/*/{name}")}


def code_inside(app):
    """Loose Mach-O files, then nested bundles, deepest first; each bundle's own executable is sealed with it."""
    bundles = sorted((p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in BUNDLES),
                     key=lambda p: len(p.parts), reverse=True)
    executables = set().union(*(main_executable(b) for b in [*bundles, app]))
    files = sorted((p for p in app.rglob("*") if p.is_file() and not p.is_symlink() and p not in executables and is_macho(p)),
                   key=lambda p: len(p.parts), reverse=True)
    return files + bundles + [app]


def team_of(path):
    match = re.search(r"^TeamIdentifier=(.*)$", run("codesign", "-dv", path).stderr, re.M)
    return match.group(1).strip() if match else "not set"


def release_entitlements(target, scratch):
    """The target's entitlements without get-task-allow, which Apple's notary service rejects in a Developer ID
    app (Voxt's Release build carries it). Returns codesign arguments: none when it has no entitlements."""
    shown = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(target)], capture_output=True).stdout
    try:
        entitlements = plistlib.loads(shown) if shown.strip() else {}
    except plistlib.InvalidFileException:
        entitlements = {}
    entitlements.pop("com.apple.security.get-task-allow", None)
    if not entitlements:
        return []
    path = Path(scratch) / f"{abs(hash(str(target)))}.entitlements"
    path.write_bytes(plistlib.dumps(entitlements))
    return ["--entitlements", path]


def strip_debug(app):
    """Removes debug symbols, and with them the linker's object and source paths, from the app's own executable
    (vendor frameworks are left as they are). Run before signing."""
    executables = [p for p in main_executable(app) if p.is_file()]
    if not executables:
        raise Refused(f"{app.name} has no executable to strip")
    for executable in executables:
        result = run("xcrun", "strip", "-S", executable)
        if result.returncode != 0:
            raise Refused(f"strip {executable.name} failed: {result.stderr.strip()}")
        print(f"stripped {executable.relative_to(app.parent)}")


def sign(args):
    timestamp = "--timestamp=none" if args.no_timestamp else "--timestamp"
    scratch = tempfile.mkdtemp()
    for app in map(Path, args.apps):
        if args.strip_debug:
            strip_debug(app)
        targets = code_inside(app)
        for target in targets:
            result = run("codesign", "--force", "--options", "runtime", timestamp, *release_entitlements(target, scratch),
                         "--sign", args.identity, target, timeout=120)
            if result.returncode != 0:
                raise Refused(f"codesign {target.relative_to(app.parent)} failed: {result.stderr.strip()}")
            print(f"signed {target.relative_to(app.parent)}")
        result = run("codesign", "--verify", "--deep", "--strict", app)
        if result.returncode != 0:
            raise Refused(f"{app.name} does not verify: {result.stderr.strip()}")
        if args.team:
            wrong = [f"{t.relative_to(app.parent)} ({team_of(t)})" for t in targets if team_of(t) != args.team]
            if wrong:
                raise Refused(f"not signed by team {args.team}: " + ", ".join(wrong))
        if args.requirement:
            result = run("codesign", "--verify", f"-R={args.requirement}", app)
            if result.returncode != 0:
                raise Refused(f"{app.name} does not satisfy {args.requirement}: {result.stderr.strip()}")
            print(f"{app.name} satisfies {args.requirement}")


def dmg(args):
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as staging:
        for app in map(Path, args.apps):
            result = run("ditto", app, Path(staging) / app.name)
            if result.returncode != 0:
                raise Refused(f"copying {app.name} failed: {result.stderr.strip()}")
        os.symlink("/Applications", Path(staging) / "Applications")
        result = run("hdiutil", "create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO", "-volname", args.volname,
                     "-srcfolder", staging, out)
        if result.returncode != 0:
            raise Refused(f"hdiutil create failed: {result.stderr.strip()}")
    timestamp = "--timestamp=none" if args.no_timestamp else "--timestamp"
    result = run("codesign", "--force", timestamp, "--sign", args.identity, out)
    if result.returncode != 0:
        raise Refused(f"signing {out.name} failed: {result.stderr.strip()}")
    print(f"dmg {out}")


def notarize(args):
    dmg_path = Path(args.dmg)
    settings = {name: os.environ.get(name, "") for name in ("VOXT_NOTARY_KEY", "VOXT_NOTARY_KEY_ID", "VOXT_NOTARY_ISSUER")}
    missing = [name for name, value in settings.items() if not value]
    if missing:
        raise Refused("set " + ", ".join(missing))
    if not Path(settings["VOXT_NOTARY_KEY"]).is_file():
        raise Refused("VOXT_NOTARY_KEY does not name a file")
    auth = ["--key", settings["VOXT_NOTARY_KEY"], "--key-id", settings["VOXT_NOTARY_KEY_ID"], "--issuer", settings["VOXT_NOTARY_ISSUER"]]
    record = {"dmg": dmg_path.name}
    log = Path(args.log)
    log.parent.mkdir(parents=True, exist_ok=True)

    def save():
        log.write_text(json.dumps(record, indent=1) + "\n")

    result = run("xcrun", "notarytool", "submit", dmg_path, *auth, "--wait", "--output-format", "json", timeout=3600)
    try:
        reply = json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        record["error"] = (result.stdout + result.stderr).strip()[-2000:]
        save()
        raise Refused(f"notarytool submit gave no result (exit {result.returncode}); see {log}")
    record.update(id=reply.get("id"), status=reply.get("status"), message=reply.get("message"))
    print(f"notarization {record['id']}: {record['status']}")
    if record["status"] != "Accepted":
        apple_log = log.with_suffix(".apple-log.json")
        details = run("xcrun", "notarytool", "log", record["id"], *auth, apple_log, timeout=300)
        record["apple_log"] = str(apple_log) if details.returncode == 0 else (details.stdout + details.stderr).strip()[-2000:]
        save()
        raise Refused(f"notarization {record['id']} is {record['status']}; Apple's log: {record['apple_log']}")
    staple = run("xcrun", "stapler", "staple", dmg_path)
    if staple.returncode != 0:
        record["staple"] = (staple.stdout + staple.stderr).strip()[-2000:]
        save()
        raise Refused(f"stapler staple failed (exit {staple.returncode})")
    record["staple"] = run("xcrun", "stapler", "validate", dmg_path).stdout.strip()[-500:]
    gatekeeper = run("spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-vv", dmg_path)
    record["spctl"] = (gatekeeper.stdout + gatekeeper.stderr).strip()
    save()
    if gatekeeper.returncode != 0 or "accepted" not in record["spctl"] or "source=Notarized Developer ID" not in record["spctl"]:
        raise Refused(f"Gatekeeper does not report Notarized Developer ID: {record['spctl']}")
    print(record["spctl"])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("sign")
    command.add_argument("--identity", required=True)
    command.add_argument("--team")
    command.add_argument("--requirement")
    command.add_argument("--no-timestamp", action="store_true")
    command.add_argument("--strip-debug", action="store_true", help="strip debug paths from each app's executable first")
    command.add_argument("apps", nargs="+")
    command = commands.add_parser("dmg")
    command.add_argument("--identity", required=True)
    command.add_argument("--volname", required=True)
    command.add_argument("--out", required=True)
    command.add_argument("--no-timestamp", action="store_true")
    command.add_argument("apps", nargs="+")
    command = commands.add_parser("notarize")
    command.add_argument("dmg")
    command.add_argument("--log", required=True)
    args = parser.parse_args()
    try:
        {"sign": sign, "dmg": dmg, "notarize": notarize}[args.command](args)
    except Refused as error:
        print(f"release-mac: refused: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
