#!/usr/bin/env python3
"""The design-tour fixture reports the version it was started with on /v1/health.

Usage: python3 -I tools/test-design-tour-fixture.py [path/to/design-tour-fixture.py]
Starts the fixture on loopback twice (default, then --version 1.16.0) in a temporary
folder under $TMPDIR, and fails within 10 s if it doesn't come up.
"""
import json
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

FIXTURE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "design-tour-fixture.py"


def health(extra_args):
    with tempfile.TemporaryDirectory() as folder:
        process = subprocess.Popen([sys.executable, "-I", str(FIXTURE), "--output", folder, *extra_args],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            endpoint = Path(folder) / "endpoint.txt"
            deadline = time.time() + 10
            while not endpoint.exists() or not endpoint.read_text():
                if process.poll() is not None:
                    raise AssertionError(f"fixture exited: {process.stderr.read().strip()}")
                if time.time() > deadline:
                    raise AssertionError("fixture did not start within 10 s")
                time.sleep(0.1)
            request = urllib.request.Request(endpoint.read_text() + "/v1/health",
                                             headers={"Authorization": "Bearer design-review"})
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.load(response)
        finally:
            process.terminate()
            process.wait(timeout=5)


failures = 0
for args, expected in [([], "design-fixture"), (["--version", "1.16.0"], "1.16.0")]:
    try:
        version = health(args).get("version")
        ok = version == expected
        print(("PASS" if ok else "FAIL"), args, "->", version)
        failures += 0 if ok else 1
    except AssertionError as error:
        print("FAIL", args, "->", error)
        failures += 1
sys.exit(1 if failures else 0)
