"""Exercise the signed status-line command without sending an account reading."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess


def check(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    command = [app / "Contents/MacOS" / info["CFBundleExecutable"], "--report-claude-limits"]
    status = b'{\n  "sample": "unchanged input for an existing status line"\n}\n'
    plain = subprocess.run(command, input=status, capture_output=True, check=True, timeout=5)
    assert not plain.stdout
    piped = [*command, "--pass-through"]
    forwarded = subprocess.run(piped, input=status, capture_output=True, check=True, timeout=5)
    assert forwarded.stdout == status
    reader, writer = os.pipe()
    os.close(reader)
    with os.fdopen(writer, "wb") as closed_pipe:
        subprocess.run(piped, input=status, stdout=closed_pipe, check=True, timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    check(parser.parse_args().app.resolve())
