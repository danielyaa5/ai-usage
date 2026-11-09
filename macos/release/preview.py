#!/usr/bin/env python3
"""Render a portable listing proof from the exact English metadata and store artwork."""
import argparse
import base64
from decimal import Decimal
from html import escape
import json
from pathlib import Path
from string import Template

ROOT = Path(__file__).resolve().parent


def png(path):
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def preview_article(site, path):
    page = (site / path).read_text()
    article = page.split("<main>", 1)[1].split("</main>", 1)[0]
    return article.replace('href="../"', 'href="#support" data-article="support"')


def render(output, site=None):
    info = json.loads((ROOT / "listing.json").read_text())
    for field, limit in (("name", 30), ("subtitle", 30), ("promotionalText", 170), ("description", 4000)):
        if not 0 < len(info[field]) <= limit:
            raise ValueError(f"{field} exceeds its listing limit or is empty")
    if not 0 < len(info["keywords"].encode("utf-8")) <= 100:
        raise ValueError("Keywords must be 1–100 UTF-8 bytes")
    images = []
    for index, item in enumerate(info["screenshots"]):
        src = png(ROOT / "screenshots" / item["file"])
        images.append(f'<button class="shot" data-index="{index}" aria-label="Enlarge {escape(item["label"])}">'
                      f'<img width="1440" height="900" src="{src}" alt="{escape(item["alt"])}"></button>')
    paragraphs = []
    for part in info["description"].split("\n\n"):
        if "\n" in part:
            heading, body = part.split("\n", 1)
            paragraphs.append(f"<h3>{escape(heading)}</h3><p>{escape(body)}</p>")
        else:
            paragraphs.append(f"<p>{escape(part)}</p>")
    icon = ROOT.parent / "Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png"
    html = Template((ROOT / "preview.html").read_text()).substitute(
        name=escape(info["name"]), subtitle=escape(info["subtitle"]), promo=escape(info["promotionalText"]),
        platform=escape(info["platform"]), category=escape(info["category"]), language=escape(info["language"]),
        price=f"${Decimal(info['usPrice']):.2f}", icon=png(icon), shots="".join(images),
        description="".join(paragraphs), support=escape(info["supportURL"]), privacy=escape(info["privacyPolicyURL"]),
        articles="" if site is None else (
            '<template id="article-support">' + preview_article(site, "index.html") + '</template>'
            '<template id="article-privacy">' + preview_article(site, "privacy/index.html") + '</template>'))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(html)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--site-preview", type=Path, help="Embed the staged support and privacy pages for offline review")
    args = parser.parse_args()
    render(args.output, args.site_preview)
