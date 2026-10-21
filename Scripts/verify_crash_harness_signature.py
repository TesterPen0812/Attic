#!/usr/bin/env python3
"""Verify the artifact used by the first C4 gate; does not launch anything."""
import plistlib
import subprocess
import sys
from pathlib import Path

host = Path(sys.argv[1])
helper = host / "Contents/MacOS/AtticOperationCrashHelper"
for artifact in (host, helper):
    subprocess.run(["codesign", "--verify", "--strict", str(artifact)], check=True)
    metadata = subprocess.run(["codesign", "-dv", str(artifact)], capture_output=True, check=True).stderr.decode()
    if "runtime" not in metadata:
        raise SystemExit(f"Hardened runtime missing: {artifact}")
    entitlements = plistlib.loads(subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(artifact)],
        capture_output=True, check=True,
    ).stdout)
    if entitlements.get("com.apple.security.app-sandbox") is not True:
        raise SystemExit(f"Sandbox missing: {artifact}")
    if artifact == helper and entitlements != {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.inherit": True,
    }:
        raise SystemExit(f"Helper must carry only sandbox/inherit: {entitlements}")
    print(f"Verified sandbox + hardened runtime: {artifact.name}")
