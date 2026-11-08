#!/usr/bin/env python3
"""Inspect the contents and signatures of the actual exported Mac App Store package."""
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile


def command(*args):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.STDOUT)


def entitlements(path):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(path)], check=True)
    identity = command("codesign", "-d", "--verbose=2", path).decode()
    assert "Authority=Apple Distribution:" in identity or "Authority=3rd Party Mac Developer Application:" in identity
    data = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(path)], stderr=subprocess.DEVNULL)
    result = plistlib.loads(data)
    assert result.get("com.apple.security.app-sandbox") and not result.get("com.apple.security.get-task-allow")
    return result


with tempfile.TemporaryDirectory(prefix="aiusage-package-") as tmp:
    package = Path(sys.argv[1]).resolve()
    signature = command("pkgutil", "--check-signature", package)
    assert b"Mac Developer Installer:" in signature or b"Mac Installer Distribution:" in signature
    expanded = Path(tmp) / "Expanded.noindex"
    command("pkgutil", "--expand-full", package, expanded)
    app, = expanded.rglob("*.app")
    widget, = (app / "Contents/PlugIns").glob("*.appex")
    host = entitlements(app)
    extension = entitlements(widget)
    helper = entitlements(app / "Contents/MacOS/codex-app-server")
    assert helper.get("com.apple.security.inherit") and host["com.apple.security.files.user-selected.read-only"]
    groups = host["com.apple.security.application-groups"]
    assert groups and groups == extension["com.apple.security.application-groups"]
    for target in (app, widget):
        info = plistlib.loads((target / "Contents/Info.plist").read_bytes())
        assert info["AIUsageAppGroup"] in groups
        assert info["CFBundleDisplayName"] == "AI Usage" and info["AIUsageURLScheme"] == "aiusage"
        if target == app:
            assert info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["aiusage"]
        ats = info["NSAppTransportSecurity"]
        assert ats.get("NSAllowsLocalNetworking") and not ats.get("NSAllowsArbitraryLoads")
    files = {p.name for p in (app / "Contents/Resources").rglob("*")}
    assert {"PrivacyInfo.xcprivacy", "Codex-LICENSE.txt", "Codex-NOTICE.txt", "Ratatui-LICENSE.txt", "codex-models.json", "pricing.json"} <= files
    assert "GoogleQuotaSetup.txt" not in files
    assert not any("StoreTest" in p.name for p in app.rglob("*"))
    print("Verified the signed package, app, widget, sandboxed helper, local networking, shared group and resources.")
