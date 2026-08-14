#!/usr/bin/env python3
"""Static site builder: stitches templates/header.html + a page body +
templates/footer.html into site/dist/**, mirroring site/pages/**."""
import pathlib
import re
import shutil

SITE_DIR = pathlib.Path(__file__).parent
TEMPLATES_DIR = SITE_DIR / "templates"
PAGES_DIR = SITE_DIR / "pages"
ASSETS_DIR = SITE_DIR / "assets"
DIST_DIR = SITE_DIR / "dist"

_FRONT_MATTER_RE = re.compile(
    r"^<!--\s*TITLE:\s*(?P<title>.*?)\s*-->\n"
    r"<!--\s*DESCRIPTION:\s*(?P<description>.*?)\s*-->\n"
)


def compute_root_prefix(rel_path: pathlib.Path) -> str:
    depth = len(rel_path.parts) - 1
    return "../" * depth


def parse_front_matter(text: str) -> tuple[str, str, str]:
    match = _FRONT_MATTER_RE.match(text)
    if not match:
        raise ValueError(
            "page is missing <!-- TITLE: ... --> / <!-- DESCRIPTION: ... --> "
            "front-matter comment lines"
        )
    title = match.group("title")
    description = match.group("description")
    body = text[match.end():]
    return title, description, body


def render_page(
    header_tpl: str, footer_tpl: str, title: str, description: str, root: str, body: str
) -> str:
    header = (
        header_tpl.replace("{{TITLE}}", title)
        .replace("{{DESCRIPTION}}", description)
        .replace("{{ROOT}}", root)
    )
    footer = footer_tpl.replace("{{ROOT}}", root)
    return f"{header}\n{body}\n{footer}\n"


def build_site(
    pages_dir: pathlib.Path,
    templates_dir: pathlib.Path,
    assets_dir: pathlib.Path,
    dist_dir: pathlib.Path,
) -> None:
    header_tpl = (templates_dir / "header.html").read_text()
    footer_tpl = (templates_dir / "footer.html").read_text()

    if dist_dir.exists():
        shutil.rmtree(dist_dir)
    dist_dir.mkdir(parents=True)

    for page_path in sorted(pages_dir.rglob("*.html")):
        rel_path = page_path.relative_to(pages_dir)
        raw = page_path.read_text()
        title, description, body = parse_front_matter(raw)
        root = compute_root_prefix(rel_path)
        rendered = render_page(header_tpl, footer_tpl, title, description, root, body)

        out_path = dist_dir / rel_path
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rendered)

    if assets_dir.exists():
        shutil.copytree(assets_dir, dist_dir / "assets")


if __name__ == "__main__":
    build_site(PAGES_DIR, TEMPLATES_DIR, ASSETS_DIR, DIST_DIR)
    print(f"Built site into {DIST_DIR}")
