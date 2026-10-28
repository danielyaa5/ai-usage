"""Machine-specific settings from local.json at the repository root, which git ignores.

See local.example.json. Every key is optional:
  name           what the page calls this Mac (default: its host name)
  allowed_hosts  extra Host names the dashboard answers to, such as a Tailscale MagicDNS name
  launch_agents  LaunchAgent label -> job name, for `install.py --wire-jobs`
"""
import json
import os
import socket
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / 'local.json'


def settings():
    try:
        return json.loads(PATH.read_text())
    except FileNotFoundError:
        return {}


def hostname():
    """This Mac's short name: 'my-mac' for both 'my-mac' and 'my-mac.local'."""
    name = socket.gethostname().strip().lower()
    return name[:-len('.local')] if name.endswith('.local') else name


def display_name():
    return os.environ.get('AI_USAGE_NAME') or settings().get('name') or hostname()
