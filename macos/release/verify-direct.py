#!/usr/bin/env python3
"""Check a notarized Developer ID copy of the app, or the download zip that carries it.

    python3 macos/release/verify-direct.py "path/to/AI Usage.app"
    python3 macos/release/verify-direct.py --zip path/to/AI-Usage-1.0-16.zip
"""
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
              "/Support/lsregister")


def run(*args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True)


def signature(path):
    """Developer ID, secure timestamp, hardened runtime and the sandbox; returns the entitlements."""
    run("codesign", "--verify", "--deep", "--strict", path)
    details = run("codesign", "-d", "--verbose=4", path).stderr
    assert "Authority=Developer ID Application:" in details, f"{path.name} is not signed with Developer ID"
    assert "\nTimestamp=" in details, f"{path.name} has no secure timestamp"
    flags = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", details)
    assert flags and "runtime" in flags.group(1).split(","), f"{path.name} lacks the hardened runtime"
    team = re.search(r"^TeamIdentifier=(\S+)$", details, re.M).group(1)
    data = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(path)],
                                   stderr=subprocess.DEVNULL)
    result = plistlib.loads(data)
    assert result.get("com.apple.security.app-sandbox"), f"{path.name} is not sandboxed"
    assert not result.get("com.apple.security.get-task-allow"), f"{path.name} allows debugging"
    return team, result


def check(app):
    widget, = (app / "Contents/PlugIns").glob("*.appex")
    team, host = signature(app)
    widget_team, extension = signature(widget)
    helper_team, helper = signature(app / "Contents/MacOS/codex-app-server")
    assert team == widget_team == helper_team
    # The helper runs inside the app's sandbox and has nothing of its own.
    assert set(helper) == {"com.apple.security.app-sandbox", "com.apple.security.inherit"}, helper
    assert host["com.apple.security.files.user-selected.read-only"] and host["com.apple.security.network.client"]
    groups = host["com.apple.security.application-groups"]
    assert groups and groups == extension["com.apple.security.application-groups"]
    assert all(group.startswith(team + ".") for group in groups), "App Group is not team-prefixed"
    for target in (app, widget):
        info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
        assert info["AIUsageAppGroup"] in groups
        assert info["CFBundleDisplayName"] == "AI Usage" and info["AIUsageURLScheme"] == "aiusage"
        ats = info["NSAppTransportSecurity"]
        assert ats.get("NSAllowsLocalNetworking") and not ats.get("NSAllowsArbitraryLoads")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["aiusage"]
    files = {p.name for p in (app / "Contents/Resources").rglob("*")}
    assert {"PrivacyInfo.xcprivacy", "privacy.md", "AppIcon.icns", "Assets.car", "Codex-LICENSE.txt",
            "Codex-NOTICE.txt", "Ratatui-LICENSE.txt", "codex-models.json", "pricing.json"} <= files
    assert "GoogleQuotaSetup.txt" not in files
    assert not (app / "Contents/Helpers").exists(), "test-only helpers in a release build"
    assert not any("StoreTest" in p.name for p in app.rglob("*"))
    run("xcrun", "stapler", "validate", app)
    gatekeeper = subprocess.run(["spctl", "-a", "-vv", "-t", "exec", str(app)], capture_output=True, text=True)
    assert gatekeeper.returncode == 0 and "source=Notarized Developer ID" in gatekeeper.stderr, gatekeeper.stderr
    return f"{info['CFBundleIdentifier']} {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})"


if sys.argv[1:2] == ["--zip"]:
    with tempfile.TemporaryDirectory(prefix="aiusage-direct-") as tmp:
        run("ditto", "-x", "-k", sys.argv[2], tmp)
        contents = sorted(p.name for p in Path(tmp).iterdir())
        assert contents == ["AI Usage.app"], contents
        unzipped = Path(tmp) / "AI Usage.app"
        try:
            print(f"Verified the zip: {check(unzipped)}, Developer ID, notarized and stapled.")
        finally:
            # The Gatekeeper check registers the copy with LaunchServices; don't leave a stale entry.
            subprocess.run([LSREGISTER, "-u", str(unzipped)], capture_output=True)
else:
    print(f"Verified the app: {check(Path(sys.argv[1]).resolve())}, Developer ID, notarized and stapled.")
