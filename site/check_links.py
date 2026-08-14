#!/usr/bin/env python3
"""Verify every local href in the built site resolves to a real file in dist/."""
import pathlib
import re
import sys

SITE_DIR = pathlib.Path(__file__).parent
DIST_DIR = SITE_DIR / "dist"
HREF_RE = re.compile(r'href="([^"]+)"')


def find_broken_links(dist_dir: pathlib.Path) -> list[str]:
    broken = []
    for page in sorted(dist_dir.rglob("*.html")):
        html = page.read_text()
        for href in HREF_RE.findall(html):
            if href.startswith(("http://", "https://", "#")):
                continue
            target_path, _, _fragment = href.partition("#")
            resolved = (page.parent / target_path).resolve()
            if not resolved.exists():
                broken.append(f"{page.relative_to(dist_dir)} -> {href}")
    return broken


if __name__ == "__main__":
    broken = find_broken_links(DIST_DIR)
    if broken:
        print("Broken local links found:")
        for entry in broken:
            print(f"  {entry}")
        sys.exit(1)
    print("All local links resolve.")
