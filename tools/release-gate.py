#!/usr/bin/env python3
"""Release gate: a shipped build must come from a commit in the public repo.

  release-gate.py source (--remote URL [--mirror DIR] --tag TAG | --local REPO --export DIR --rev REV)
                         --dir DIR [--branch main]
      Makes DIR a clean checkout of that public commit, or refuses. Prints the commit last.
  release-gate.py check ARTIFACT... (--remote URL [--mirror DIR] | --local REPO --export DIR)
                         [--branch main] [--require-remote] [--version v1.2.3]
      Reads VoxtSourceRevision from every app and extension in each .ipa, .dmg or bundle folder,
      checks that commit, and fails on any absolute path into a home folder or a mounted disk in any file.
      With --version, every app and extension must also be version 1.2.3 (CFBundleShortVersionString),
      except a Voxt build (one with VoxtUpstreamRevision), which keeps Voxt's own version.
  release-gate.py release --version v1.2.3 [--build N --ipa IPA] [--dmg DMG] --notes FILE --tagger "Name <email>" (mode)
      Runs the same check against that version, then makes an annotated tag v1.2.3+N (v1.2.3+mac without an IPA) on the commit
      in the public repo (the mirror, or REPO in local mode) and writes a release notes draft. Pushes nothing.

Remote mode fetches the public repo into a bare mirror (default build/release-source/public.git)
and requires the commit on its public branch. Local mode is for releases before the first push:
REPO holds the public commits that source-export made, and the commit's tree must equal the
source-export tree in DIR/tree, whose privacy check passed (DIR/check.json digest = DIR/export.json).
--require-remote refuses local mode; use it for uploads once the public repo is pushed.
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import tomllib
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY = "VoxtSourceRevision"
UPSTREAM_KEY = "VoxtUpstreamRevision"  # set on Voxt builds (tools/omni-dev.sh); they carry Voxt's version, not ours
VERSION = re.compile(r"v(\d+\.\d+\.\d+)")
COMMIT = re.compile(r"[0-9a-f]{40}")
LOCAL_PATH = re.compile(rb"/(?:Users|Volumes)/[^\x00\n\r\"']*")
CONFIG = Path(__file__).resolve().parent / "release-gate.toml"
# Debug symbols at the IPA root go to Apple for crash reports and are never installed on a device, so build paths
# in them reveal nothing to the public. Only this exact place is exempt.
APPLE_SYMBOLS = re.compile(r"Symbols/[^/]+\.symbols")


def load_prebuilt(path):
    """Framework name -> its [[prebuilt]] entry from the gate config."""
    entries = tomllib.loads(Path(path).read_text()).get("prebuilt", [])
    for entry in entries:
        for key in ("framework", "project", "version", "url", "sha256", "allow"):
            if not entry.get(key):
                raise Refused(f"{path}: [[prebuilt]] {entry.get('framework', '?')} has no {key}")
    return {entry["framework"]: entry for entry in entries}


def framework_of(name):
    """The innermost .framework folder a file sits in, or None."""
    parts = Path(name).parts[:-1]
    return next((part for part in reversed(parts) if part.endswith(".framework")), None)


class Refused(Exception):
    pass


def git(*args, cwd=None, check=True):
    result = subprocess.run(["git", *map(str, args)], cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise Refused(f"git {args[0]} failed: {result.stderr.strip()}")
    return result


class Public:
    """The public commits: a mirror of the remote, or a local repo plus a source-export folder."""

    def __init__(self, args):
        self.branch = args.branch
        self.local = args.local is not None
        if self.local:
            if args.export is None:
                raise Refused("--local needs --export (the source-export folder with tree/)")
            self.repo = Path(args.local)
            self.export = Path(args.export)
            if git("rev-parse", "--git-dir", cwd=self.repo, check=False).returncode != 0:
                raise Refused(f"{self.repo} is not a git repo")
        else:
            self.repo = Path(args.mirror) if args.mirror else ROOT / "build/release-source/public.git"
            self.fetch(args.remote)

    def fetch(self, url):
        if not self.repo.exists():
            self.repo.parent.mkdir(parents=True, exist_ok=True)
            git("clone", "-q", "--mirror", url, self.repo)
            return
        current = git("config", "remote.origin.url", cwd=self.repo, check=False).stdout.strip()
        if current != str(url):
            raise Refused(f"mirror {self.repo} fetches {current or 'nothing'}, not {url}")
        # No pruning: it would delete release tags made here that are not pushed yet.
        git("fetch", "-q", "origin", cwd=self.repo)

    def resolve(self, ref):
        result = git("rev-parse", "--verify", "-q", f"{ref}^{{commit}}", cwd=self.repo, check=False)
        if result.returncode != 0:
            raise Refused(f"{ref} is unknown to the public repo")
        return result.stdout.strip()

    def verify(self, commit):
        """Refuses unless commit is on the public branch (and, locally, equals the checked export)."""
        commit = self.resolve(commit)
        if git("merge-base", "--is-ancestor", commit, f"refs/heads/{self.branch}", cwd=self.repo, check=False).returncode != 0:
            raise Refused(f"{commit} is not on the public branch {self.branch}")
        if self.local:
            self.verify_export(commit)
        return commit

    def verify_export(self, commit):
        try:
            exported = json.loads((self.export / "export.json").read_text()).get("digest")
            checked = json.loads((self.export / "check.json").read_text()).get("digest")
        except (OSError, ValueError) as error:
            raise Refused(f"cannot read the source-export check in {self.export}: {error}")
        if not exported or exported != checked:
            raise Refused("the source-export check has not passed for the exported tree; run source-export check")
        if tree_hash(self.export / "tree") != git("rev-parse", f"{commit}^{{tree}}", cwd=self.repo).stdout.strip():
            raise Refused(f"{commit} differs from the source-export tree in {self.export / 'tree'}")


def tree_hash(folder):
    """The git tree id of a folder's files, modes included, ignoring nothing. Computed here because
    git refuses a work tree inside .git/, where source-export keeps its tree."""
    folder = Path(folder)
    if not folder.is_dir():
        raise Refused(f"{folder} does not exist")

    def obj(kind, data):
        return hashlib.sha1(f"{kind} {len(data)}\0".encode() + data).digest()

    def tree(path):
        entries = []
        for child in path.iterdir():
            if child.is_symlink():
                entries.append((child.name, b"120000", obj("blob", os.readlink(child).encode())))
            elif child.is_dir():
                sub = tree(child)
                if sub is not None:
                    entries.append((child.name + "/", b"40000", sub))
            else:
                mode = b"100755" if child.stat().st_mode & stat.S_IXUSR else b"100644"
                entries.append((child.name, mode, obj("blob", child.read_bytes())))
        if not entries:
            return None  # git has no empty trees inside a commit
        entries.sort(key=lambda e: e[0].encode())
        return obj("tree", b"".join(mode + b" " + name.rstrip("/").encode() + b"\0" + digest for name, mode, digest in entries))

    digest = tree(folder)
    return digest.hex() if digest else "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def checkout(public, commit, folder):
    folder = Path(folder)
    if not folder.exists() or not any(folder.iterdir()):
        git("clone", "-q", "--no-checkout", public.repo.resolve(), folder)
        git("checkout", "-q", "--detach", commit, cwd=folder)
    elif git("rev-parse", "--show-toplevel", cwd=folder, check=False).stdout.strip() != str(folder.resolve()):
        raise Refused(f"{folder} exists and is not a checkout; use an empty folder")
    head = git("rev-parse", "HEAD", cwd=folder).stdout.strip()
    if head != commit:
        raise Refused(f"{folder} is at {head}, not {commit}")
    changes = git("status", "--porcelain", "--ignored", "--untracked-files=all", cwd=folder).stdout
    if changes.strip():
        count = len(changes.splitlines())
        raise Refused(f"{folder} has changes ({count} paths, ignored build output included); use an empty folder")


def bundles_and_files(artifact):
    """Yields (relative name, bytes) for every file in an .ipa, .dmg or folder."""
    artifact = Path(artifact)
    if artifact.is_dir():
        yield from folder_files(artifact)
    elif artifact.suffix == ".ipa":
        with zipfile.ZipFile(artifact) as z:
            for entry in z.infolist():
                if not entry.is_dir():
                    yield entry.filename, z.read(entry)
    elif artifact.suffix == ".dmg":
        # hdiutil picks the mount point: attaching at a folder on an external disk can be denied.
        attached = subprocess.run(["hdiutil", "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", str(artifact)],
                                  capture_output=True, timeout=120)
        if attached.returncode != 0:
            raise Refused(f"{artifact.name}: hdiutil attach failed: {attached.stderr.decode(errors='replace').strip()}")
        mounts = [e["mount-point"] for e in plistlib.loads(attached.stdout)["system-entities"] if "mount-point" in e]
        try:
            for mount in mounts:
                yield from folder_files(Path(mount))
        finally:
            for mount in mounts:
                subprocess.run(["hdiutil", "detach", "-quiet", mount], timeout=120)
    else:
        raise Refused(f"{artifact.name}: expected an .ipa, a .dmg or a folder")


def folder_files(folder):
    for path in sorted(folder.rglob("*")):
        if path.is_file() and not path.is_symlink():
            yield str(path.relative_to(folder)), path.read_bytes()


def is_bundle_info(name):
    """Info.plist of an app or extension (iOS layout or macOS Contents/), not of a framework."""
    parts = Path(name).parts
    if not parts or parts[-1] != "Info.plist":
        return None
    owner = parts[-3] if len(parts) >= 3 and parts[-2] == "Contents" else (parts[-2] if len(parts) >= 2 else "")
    return owner if owner.endswith((".app", ".appex")) else None


def inspect(public, artifacts, require_remote=False, prebuilt=None, version=None):
    """Checks the artifacts against the public commits, and with version (v1.2.3) each app's version.
    Returns (commit, report lines, prebuilt entries used); refuses on any problem."""
    prebuilt = prebuilt or {}
    allowed = {}
    skipped = 0
    expected = release_version(version) if version else None
    versioned, upstream = [], []
    if require_remote and public.local:
        raise Refused("--require-remote: this upload needs the commit on the public remote, not local mode")
    problems, revisions = [], {}
    for artifact in artifacts:
        found = False
        for name, data in bundles_and_files(artifact):
            # An app inside a framework (Sparkle's Updater.app) is that framework's code, not ours.
            owner = None if framework_of(name) else is_bundle_info(name)
            if owner:
                found = True
                plist = plistlib.loads(data)
                revision = plist.get(KEY, "")
                if expected and plist.get(UPSTREAM_KEY):
                    upstream.append(f"{owner} {plist.get('CFBundleShortVersionString', '?')}")
                elif expected:
                    shown = plist.get("CFBundleShortVersionString", "")
                    if not shown:
                        problems.append(f"{Path(artifact).name}: {owner} has no CFBundleShortVersionString")
                    elif shown != expected:
                        problems.append(f"{Path(artifact).name}: {owner} is version {shown}, not {expected} ({version})")
                    else:
                        versioned.append(owner)
                if not revision:
                    problems.append(f"{Path(artifact).name}: {owner} has no {KEY}")
                elif not COMMIT.fullmatch(revision):
                    problems.append(f"{Path(artifact).name}: {owner} {KEY} is not a commit hash")
                else:
                    revisions.setdefault(revision, []).append(owner)
            if Path(artifact).suffix == ".ipa" and APPLE_SYMBOLS.fullmatch(name):
                skipped += 1
                continue
            entry = prebuilt.get(framework_of(name))
            hits = 0
            for match in LOCAL_PATH.finditer(data):
                if entry and any(match.group().startswith(p.encode()) for p in entry["allow"]):
                    allowed[entry["framework"]] = allowed.get(entry["framework"], 0) + 1
                else:
                    hits += 1
            if hits:
                problems.append(f"{Path(artifact).name}: local path in {name} ({hits} times)")
        if not found:
            problems.append(f"{Path(artifact).name}: no app or extension Info.plist found")
    if len(revisions) > 1:
        problems.append("bundles were built from different commits: "
                        + "; ".join(f"{', '.join(owners)} at {rev[:12]}" for rev, owners in revisions.items()))
    for revision in revisions:
        try:
            public.verify(revision)
        except Refused as error:
            problems.append(str(error))
    if problems:
        for problem in problems:
            print("BLOCKED: " + problem)
        raise Refused(f"{len(problems)} problem(s); do not upload")
    commit = next(iter(revisions))
    mode = "matches the checked source-export tree" if public.local else f"is on the public {public.branch}"
    names = ", ".join(Path(a).name for a in artifacts)
    lines = [f"release-gate: ok, {commit} {mode}", f"checked: {names}: every app and extension names this commit; no local paths"]
    if expected:
        lines.append(f"version: {', '.join(versioned)} at {expected}"
                     + (f"; {', '.join(upstream)} is Voxt's own version ({UPSTREAM_KEY})" if upstream else ""))
    if skipped:
        lines.append(f"skipped: {skipped} Symbols/*.symbols at the IPA root (debug data for Apple's crash reports, never installed on a device)")
    used = [prebuilt[name] for name in sorted(allowed)]
    for entry in used:
        lines.append(f"prebuilt: {entry['framework']} from {entry['project'].split(',')[0]} {entry['version']}: "
                     f"{allowed[entry['framework']]} paths under {', '.join(entry['allow'])} allowed (its build machine, not this one)")
    print("\n".join(lines))
    return commit, lines, used


def release_version(version):
    """v1.2.3 -> 1.2.3, the CFBundleShortVersionString every app of the release shows."""
    match = VERSION.fullmatch(version or "")
    if not match:
        raise Refused(f"--version must look like v1.2.3, got {version!r}")
    return match[1]


def check(args):
    if args.version:
        release_version(args.version)
    inspect(Public(args), args.artifacts, args.require_remote, load_prebuilt(args.config), args.version)


def release(args):
    """After the check passes: an annotated tag on the public commit and a release notes draft. Pushes nothing."""
    release_version(args.version)
    tagger = re.fullmatch(r"(.+?) <([^<>@\s]+@[^<>\s]+)>", args.tagger or "")
    if not tagger:
        raise Refused('--tagger "Name <email>" is required; the tag shows it publicly')
    artifacts = [a for a in (args.ipa, args.dmg) if a]
    if not artifacts:
        raise Refused("release needs --ipa and/or --dmg")
    if args.ipa and not args.build:
        raise Refused("--ipa needs --build N, the iOS build number")
    public = Public(args)
    commit, lines, used = inspect(public, artifacts, args.require_remote, load_prebuilt(args.config), args.version)
    tag = f"{args.version}+{args.build}" if args.ipa else f"{args.version}+mac"
    if git("rev-parse", "--verify", "-q", f"refs/tags/{tag}", cwd=public.repo, check=False).returncode == 0:
        raise Refused(f"tag {tag} already exists in {public.repo}")
    facts = [f"Source commit: {commit}"]
    if args.ipa:
        facts.append(f"iOS build: {args.build} ({Path(args.ipa).name})")
    if args.dmg:
        facts.append(f"{Path(args.dmg).name} SHA-256: {hashlib.sha256(Path(args.dmg).read_bytes()).hexdigest()}")
    message = "\n".join([f"Voxt Mobile {tag}", "", *facts, "", *lines]) + "\n"
    noon = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT12:00:00+0000")
    env = {**os.environ, "GIT_COMMITTER_NAME": tagger[1], "GIT_COMMITTER_EMAIL": tagger[2], "GIT_COMMITTER_DATE": noon}
    result = subprocess.run(["git", "tag", "-a", tag, "-F", "-", commit], cwd=public.repo, input=message, text=True,
                            env=env, capture_output=True)
    if result.returncode != 0:
        raise Refused(f"git tag failed: {result.stderr.strip()}")
    notes = Path(args.notes)
    notes.parent.mkdir(parents=True, exist_ok=True)
    notes.write_text("\n".join([
        f"# Voxt Mobile {args.version}", "", "Draft release notes. Nothing has been posted.", "",
        "## What's new", "", "- (fill in)", "", "## Build", "", *[f"- {fact}" for fact in facts], f"- Tag: `{tag}`", "",
        *(["## Prebuilt third-party code", "",
           "These frameworks ship as their projects' own prebuilt binaries, not built from this repo:", "",
           *[f"- `{e['framework']}`: {e['project']}, version {e['version']}, {e['url']} (SHA-256 {e['sha256']})" for e in used],
           ""] if used else []),
        "To check that this release matches its source, see How to verify a release in the README.", "",
        "## Release gate", "", "```", *lines, "```", ""]))
    print(f"tagged {tag} on {commit} in {public.repo} (not pushed); notes: {notes}")
    print(f"push when the public repo is ready: git -C {public.repo} push origin refs/tags/{tag}")


def source(args):
    public = Public(args)
    ref = args.rev if public.local else args.tag
    if not ref:
        raise Refused("source needs --tag (remote) or --rev (local)")
    if not public.local and git("rev-parse", "--verify", "-q", f"refs/tags/{ref}", cwd=public.repo, check=False).returncode != 0:
        raise Refused(f"tag {ref} is unknown to the public remote")
    commit = public.verify(ref)
    checkout(public, commit, args.dir)
    print(commit)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("source", "check", "release"):
        command = commands.add_parser(name)
        mode = command.add_mutually_exclusive_group(required=True)
        mode.add_argument("--remote", help="public repo URL")
        mode.add_argument("--local", help="local repo with the public commits")
        command.add_argument("--mirror", help="bare mirror of the remote")
        command.add_argument("--export", help="source-export folder (tree/, export.json, check.json)")
        command.add_argument("--branch", default="main")
        command.add_argument("--config", default=str(CONFIG), help="gate config with the [[prebuilt]] allowlist")
    commands.choices["source"].add_argument("--tag")
    commands.choices["source"].add_argument("--rev")
    commands.choices["source"].add_argument("--dir", required=True)
    commands.choices["check"].add_argument("artifacts", nargs="+")
    commands.choices["check"].add_argument("--require-remote", action="store_true")
    commands.choices["check"].add_argument("--version", help="v1.2.3: every app and extension must be version 1.2.3")
    command = commands.choices["release"]
    command.add_argument("--version", required=True, help="v1.2.3; the tag is v1.2.3+BUILD, or v1.2.3+mac without an IPA")
    command.add_argument("--build", help="iOS build number")
    command.add_argument("--ipa")
    command.add_argument("--dmg")
    command.add_argument("--notes", required=True, help="release notes draft to write")
    command.add_argument("--tagger", help='"Name <email>" for the tag; it is public')
    command.add_argument("--require-remote", action="store_true")
    args = parser.parse_args()
    try:
        {"source": source, "check": check, "release": release}[args.command](args)
    except Refused as error:
        print(f"release-gate: refused: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
