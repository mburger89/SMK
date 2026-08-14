# GitHub Pages Site (Marketing + Docs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a static GitHub Pages site for SMK — a dark, Liquid-Glass-styled marketing landing page plus a multi-page docs section reformatting existing README.md/CLAUDE.md content — deployed via GitHub Actions to the `gh-pages` branch.

**Architecture:** Site source lives in `site/` on `main` (templates, page-content fragments, CSS/assets, a small Python templater). `site/build.py` stitches `site/templates/header.html` + each page's body + `site/templates/footer.html` into standalone static HTML in `site/dist/` (gitignored build output), computing a relative `{{ROOT}}` path prefix per page based on its depth under `site/pages/`. A GitHub Actions workflow runs the same build and publishes `site/dist/` to the `gh-pages` branch on every push to `main` that touches `site/**`.

**Tech Stack:** Plain HTML/CSS, no JS framework, no client-side templating. Python 3 (stdlib only — `pathlib`, `re`, `shutil`, `unittest`) for the build script and its tests. GitHub Actions + `peaceiris/actions-gh-pages` for deployment.

**Spec:** `docs/superpowers/specs/2026-08-13-gh-pages-site-design.md`

## Global Constraints

- Python 3.11+ only, stdlib-only for `site/build.py` and its tests — no new project dependency (Python is already required by ESP-IDF).
- Output is plain static HTML/CSS — no JS framework, no client-side templating.
- `site/dist/` is a build artifact only — gitignored, never committed.
- Background gradient is **blue only**: `rgba(90,130,255,0.30)` and `rgba(60,90,200,0.18)` radial glows, top-left positioned, over a `#0b0c10` → `#14151c` → `#0b0c10` base. No orange anywhere in the ambient background.
- Accent color is `#ff8c42`, reserved for the CTA button, code-snippet highlights, and links/hover states only — never the background.
- Liquid-Glass panel treatment (nav bar, hero card, chips): `background: rgba(255,255,255,0.05-0.08)`, `backdrop-filter: blur(12-18px)`, `border: 1px solid rgba(255,255,255,0.12-0.16)`, layered `box-shadow` with an `inset 0 1px 0 rgba(255,255,255,0.15-0.2)` highlight edge.
- No interactive keymap visualizer/editor — the keymap page is a static reference table only (explicitly dropped from scope during brainstorming).
- No custom domain / `CNAME` file — the site serves at the default `mburger89.github.io/SMK` URL.
- The deploy workflow triggers only on `site/**` (and its own file) changes, publishes to the `gh-pages` branch, and runs independently of the existing `.github/workflows/host-tests.yml` and `build.yml` (never blocks or is blocked by firmware CI).
- All docs content is a reformat of what's already in `README.md`/`CLAUDE.md` — no new technical claims or writing.

---

### Task 1: Build tooling — `site/build.py` templating core

**Files:**
- Create: `site/build.py`
- Create: `site/test_build.py`
- Create: `site/templates/header.html` (placeholder — finalized in Task 2)
- Create: `site/templates/footer.html` (placeholder — finalized in Task 2)
- Create: `site/pages/index.html` (placeholder — finalized in Task 3)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing (foundational task).
- Produces:
  - `compute_root_prefix(rel_path: pathlib.Path) -> str` — returns `"../" * depth`, where `depth` is the number of directories between `site/pages/` and the page file.
  - `parse_front_matter(text: str) -> tuple[str, str, str]` — parses the first two lines of a page file, `<!-- TITLE: ... -->` and `<!-- DESCRIPTION: ... -->`, returning `(title, description, body)` with those two lines stripped from `body`. Raises `ValueError` if the front matter is missing.
  - `render_page(header_tpl: str, footer_tpl: str, title: str, description: str, root: str, body: str) -> str` — substitutes `{{TITLE}}`, `{{DESCRIPTION}}`, `{{ROOT}}` into `header_tpl`/`footer_tpl` and concatenates `header + body + footer`.
  - `build_site(pages_dir: pathlib.Path, templates_dir: pathlib.Path, assets_dir: pathlib.Path, dist_dir: pathlib.Path) -> None` — walks every `*.html` under `pages_dir`, renders it, writes to the matching path under `dist_dir`, then copies `assets_dir` to `dist_dir/assets`.
  - CLI: `python3 site/build.py` (run from repo root) builds `site/pages/` → `site/dist/` using `site/templates/` and `site/assets/`.
  - Page-file contract downstream tasks (2-6) must follow: every file under `site/pages/**/*.html` starts with exactly two front-matter comment lines (`<!-- TITLE: ... -->`, `<!-- DESCRIPTION: ... -->`) followed by the page body HTML fragment (no `<html>`/`<head>`/`<body>` tags — those come from the templates).

- [ ] **Step 1: Write the failing tests**

Create `site/test_build.py`:

```python
import pathlib
import tempfile
import unittest

from build import compute_root_prefix, parse_front_matter, render_page, build_site


class ComputeRootPrefixTests(unittest.TestCase):
    def test_top_level_page_has_no_prefix(self):
        self.assertEqual(compute_root_prefix(pathlib.Path("index.html")), "")

    def test_one_level_deep_page(self):
        self.assertEqual(compute_root_prefix(pathlib.Path("docs/index.html")), "../")

    def test_two_levels_deep_page(self):
        self.assertEqual(
            compute_root_prefix(pathlib.Path("docs/targets/esp32c6.html")), "../../"
        )


class ParseFrontMatterTests(unittest.TestCase):
    def test_extracts_title_and_description(self):
        text = (
            "<!-- TITLE: Get Started -->\n"
            "<!-- DESCRIPTION: Build and flash SMK. -->\n"
            "<h1>Get Started</h1>\n"
        )
        title, description, body = parse_front_matter(text)
        self.assertEqual(title, "Get Started")
        self.assertEqual(description, "Build and flash SMK.")
        self.assertEqual(body, "<h1>Get Started</h1>\n")

    def test_missing_front_matter_raises(self):
        with self.assertRaises(ValueError):
            parse_front_matter("<h1>No front matter</h1>")


class RenderPageTests(unittest.TestCase):
    def test_substitutes_placeholders_and_includes_body(self):
        header_tpl = (
            '<head><title>{{TITLE}}</title>'
            '<meta name="description" content="{{DESCRIPTION}}">'
            '<link href="{{ROOT}}assets/style.css"></head><body>'
            '<nav><a href="{{ROOT}}index.html">smk</a></nav>'
        )
        footer_tpl = '<footer><a href="{{ROOT}}docs/index.html">Docs</a></footer></body></html>'
        result = render_page(
            header_tpl, footer_tpl, "Get Started", "Build SMK.", "../", "<h1>Hi</h1>"
        )
        self.assertIn("<title>Get Started</title>", result)
        self.assertIn('content="Build SMK."', result)
        self.assertIn('href="../assets/style.css"', result)
        self.assertIn('href="../index.html"', result)
        self.assertIn("<h1>Hi</h1>", result)
        self.assertIn('href="../docs/index.html"', result)


class BuildSiteTests(unittest.TestCase):
    def test_builds_nested_pages_with_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            templates_dir = root / "templates"
            pages_dir = root / "pages"
            assets_dir = root / "assets"
            dist_dir = root / "dist"

            templates_dir.mkdir()
            (templates_dir / "header.html").write_text(
                '<head><title>{{TITLE}}</title>'
                '<link href="{{ROOT}}assets/style.css"></head><body>'
            )
            (templates_dir / "footer.html").write_text(
                "<footer>{{ROOT}}</footer></body></html>"
            )

            (pages_dir / "docs" / "targets").mkdir(parents=True)
            (pages_dir / "index.html").write_text(
                "<!-- TITLE: Home -->\n<!-- DESCRIPTION: Homepage -->\n<h1>Home</h1>\n"
            )
            (pages_dir / "docs" / "targets" / "esp32c6.html").write_text(
                "<!-- TITLE: ESP32-C6 -->\n<!-- DESCRIPTION: ESP32-C6 docs -->\n"
                "<h1>ESP32-C6</h1>\n"
            )

            assets_dir.mkdir()
            (assets_dir / "style.css").write_text("body { color: red; }")

            build_site(pages_dir, templates_dir, assets_dir, dist_dir)

            home_html = (dist_dir / "index.html").read_text()
            self.assertIn("<title>Home</title>", home_html)
            self.assertIn('href="assets/style.css"', home_html)

            target_html = (dist_dir / "docs" / "targets" / "esp32c6.html").read_text()
            self.assertIn("<title>ESP32-C6</title>", target_html)
            self.assertIn('href="../../assets/style.css"', target_html)

            self.assertEqual(
                (dist_dir / "assets" / "style.css").read_text(), "body { color: red; }"
            )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd site && python3 -m unittest test_build.py -v`
Expected: FAIL/ERROR — `ModuleNotFoundError: No module named 'build'` (or `ImportError`), since `site/build.py` doesn't exist yet.

- [ ] **Step 3: Implement `site/build.py`**

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd site && python3 -m unittest test_build.py -v`
Expected: all 6 tests PASS.

- [ ] **Step 5: Create placeholder templates and homepage so the CLI has something real to build**

Create `site/templates/header.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>{{TITLE}} — SMK</title>
<meta name="description" content="{{DESCRIPTION}}">
<link rel="stylesheet" href="{{ROOT}}assets/style.css">
</head>
<body>
<nav><a href="{{ROOT}}index.html">smk</a></nav>
```

Create `site/templates/footer.html`:

```html
<footer><a href="{{ROOT}}docs/index.html">Docs</a></footer>
</body>
</html>
```

Create `site/pages/index.html`:

```html
<!-- TITLE: Home -->
<!-- DESCRIPTION: SMK placeholder homepage. -->
<h1>SMK</h1>
<p>Site under construction.</p>
```

- [ ] **Step 6: Run the CLI end-to-end and confirm real output**

Run: `python3 site/build.py` (from repo root)
Expected: prints `Built site into .../site/dist`, and `site/dist/index.html` exists and contains `<title>Home — SMK</title>` and `<h1>SMK</h1>`.

- [ ] **Step 7: Gitignore the build output**

Add to `.gitignore` (after the existing `.superpowers/` line added during brainstorming):

```
# GitHub Pages site build output
site/dist/
```

- [ ] **Step 8: Commit**

```bash
git add site/build.py site/test_build.py site/templates/header.html site/templates/footer.html site/pages/index.html .gitignore
git commit -m "Add static site build tooling for GitHub Pages site"
```

---

### Task 2: Theme — `style.css`, favicon, final header/footer templates

**Files:**
- Modify: `site/templates/header.html`
- Modify: `site/templates/footer.html`
- Create: `site/assets/style.css`
- Create: `site/assets/favicon.svg`

**Interfaces:**
- Consumes: Task 1's `{{TITLE}}`/`{{DESCRIPTION}}`/`{{ROOT}}` placeholder contract and `python3 site/build.py` CLI.
- Produces: CSS classes later tasks' page content relies on: `.hero`, `.hero-card`, `.hero-eyebrow`, `.accent`, `.subhead`, `.btn-row`, `.btn-accent`, `.btn-glass`, `.page-section`, `.section-label`, `.features-grid`, `.feature-card`, `.chip-row`, `.chip`, `.status`, `.quickstart-note`, `.glass-card`, `.docs-content` (implicit via `.site-main` scoping — docs pages use plain `h1`/`h2`/`p.lede`/`ul`/`table` which the stylesheet styles globally under `.site-main`), `.docs-index-list`, `.back-link`. Nav markup structure: `<nav class="site-nav">` containing `<a class="brand">` and `<div class="nav-links">`. Footer markup: `<footer class="site-footer">` containing a `<div class="footer-links">`.

- [ ] **Step 1: Write `site/assets/style.css`**

```css
:root {
  --bg-base: #0b0c10;
  --bg-mid: #14151c;
  --glow-blue-1: rgba(90, 130, 255, 0.30);
  --glow-blue-2: rgba(60, 90, 200, 0.18);
  --glass-bg: rgba(255, 255, 255, 0.05);
  --glass-bg-strong: rgba(255, 255, 255, 0.08);
  --glass-border: rgba(255, 255, 255, 0.14);
  --glass-border-strong: rgba(255, 255, 255, 0.16);
  --text-primary: #f2f2f5;
  --text-secondary: #c9c9d2;
  --text-muted: #8b8b96;
  --accent: #ff8c42;
  --accent-ink: #1a1305;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --radius-lg: 20px;
  --radius-md: 14px;
  --radius-sm: 10px;
}

* { box-sizing: border-box; }

html, body {
  margin: 0;
  padding: 0;
  background:
    radial-gradient(circle at 15% 15%, var(--glow-blue-1), transparent 50%),
    radial-gradient(circle at 55% 60%, var(--glow-blue-2), transparent 55%),
    linear-gradient(160deg, var(--bg-base), var(--bg-mid) 60%, var(--bg-base));
  background-attachment: fixed;
  color: var(--text-primary);
  font-family: var(--sans);
  line-height: 1.5;
}

a { color: inherit; text-decoration: none; }
a:hover { color: var(--accent); }

code, pre { font-family: var(--mono); }

pre {
  background: #000;
  border: 1px solid var(--glass-border);
  border-radius: var(--radius-sm);
  padding: 14px 16px;
  overflow-x: auto;
  font-size: 0.85rem;
  color: #9be38a;
}

.site-nav {
  position: sticky;
  top: 12px;
  z-index: 10;
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin: 12px auto;
  max-width: 1040px;
  padding: 12px 20px;
  background: var(--glass-bg-strong);
  backdrop-filter: blur(12px);
  -webkit-backdrop-filter: blur(12px);
  border: 1px solid var(--glass-border);
  border-radius: var(--radius-md);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35), inset 0 1px 0 rgba(255, 255, 255, 0.15);
}

.site-nav .brand { font-family: var(--mono); font-weight: 700; font-size: 1rem; }
.nav-links { display: flex; gap: 20px; font-size: 0.85rem; color: var(--text-secondary); }
.nav-links a:hover { color: var(--accent); }

.site-main { max-width: 1040px; margin: 0 auto; padding: 0 20px 60px; }

.glass-card {
  background: var(--glass-bg);
  backdrop-filter: blur(18px);
  -webkit-backdrop-filter: blur(18px);
  border: 1px solid var(--glass-border);
  border-radius: var(--radius-lg);
  box-shadow: 0 20px 50px rgba(0, 0, 0, 0.4), inset 0 1px 0 rgba(255, 255, 255, 0.2);
  padding: 28px 32px;
}

.hero { padding: 56px 0 40px; }
.hero-card { max-width: 520px; }
.hero-eyebrow { font-family: var(--mono); font-size: 0.75rem; color: var(--accent); margin-bottom: 12px; }
.hero h1 { font-size: 2.1rem; line-height: 1.2; margin: 0 0 14px; }
.hero h1 .accent { color: var(--accent); }
.hero p.subhead { color: var(--text-secondary); font-size: 0.95rem; margin: 0 0 24px; }

.btn-row { display: flex; gap: 12px; flex-wrap: wrap; }

.btn-accent, .btn-glass {
  display: inline-block;
  border-radius: var(--radius-sm);
  padding: 11px 20px;
  font-size: 0.85rem;
  font-weight: 700;
  border: 1px solid transparent;
}
.btn-accent { background: var(--accent); color: var(--accent-ink); box-shadow: 0 6px 16px rgba(255, 140, 66, 0.4); }
.btn-accent:hover { color: var(--accent-ink); opacity: 0.9; }
.btn-glass {
  background: var(--glass-bg-strong);
  backdrop-filter: blur(10px);
  -webkit-backdrop-filter: blur(10px);
  border-color: var(--glass-border-strong);
  color: var(--text-primary);
}
.btn-glass:hover { color: var(--text-primary); border-color: var(--accent); }

.section-label {
  font-size: 0.75rem;
  letter-spacing: 1px;
  color: var(--text-muted);
  margin-bottom: 16px;
  text-transform: uppercase;
}
.features-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 14px; }
.feature-card {
  background: rgba(255, 255, 255, 0.04);
  border: 1px solid var(--glass-border);
  border-radius: var(--radius-md);
  padding: 16px 18px;
  font-size: 0.9rem;
}

.chip-row { display: flex; gap: 10px; flex-wrap: wrap; }
.chip {
  font-family: var(--mono);
  font-size: 0.78rem;
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--glass-border);
  border-radius: 20px;
  padding: 7px 14px;
}
.chip .status { margin-left: 6px; }

.quickstart-note { color: var(--text-secondary); font-size: 0.9rem; margin-top: 10px; }

.page-section { padding: 40px 0; border-top: 1px solid rgba(255, 255, 255, 0.08); }
.page-section:first-of-type { border-top: none; }

.site-footer {
  max-width: 1040px;
  margin: 20px auto 0;
  padding: 20px 20px 40px;
  display: flex;
  justify-content: space-between;
  font-size: 0.8rem;
  color: var(--text-muted);
  border-top: 1px solid rgba(255, 255, 255, 0.08);
}
.footer-links { display: flex; gap: 16px; }

.site-main h1 { font-size: 1.8rem; margin-top: 40px; }
.site-main h2 { font-size: 1.3rem; margin-top: 32px; color: var(--text-primary); }
.site-main p.lede { color: var(--text-secondary); }
.site-main ul, .site-main ol { color: var(--text-secondary); line-height: 1.7; }
.site-main table { width: 100%; border-collapse: collapse; margin: 16px 0; font-size: 0.85rem; }
.site-main th, .site-main td { border: 1px solid var(--glass-border); padding: 8px 12px; text-align: left; }
.site-main th { background: rgba(255, 255, 255, 0.05); }

.docs-index-list { list-style: none; padding: 0; display: grid; gap: 10px; }
.docs-index-list a {
  display: block;
  background: var(--glass-bg);
  border: 1px solid var(--glass-border);
  border-radius: var(--radius-sm);
  padding: 14px 16px;
}
.docs-index-list a:hover { border-color: var(--accent); }

.back-link { display: inline-block; margin-top: 32px; color: var(--text-secondary); font-size: 0.85rem; }
.back-link:hover { color: var(--accent); }

@media (max-width: 640px) {
  .features-grid { grid-template-columns: 1fr; }
  .nav-links { gap: 12px; }
  .hero h1 { font-size: 1.6rem; }
}
```

- [ ] **Step 2: Write `site/assets/favicon.svg`**

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="14" fill="#0b0c10"/>
  <text x="32" y="42" font-family="ui-monospace, Menlo, monospace" font-size="28" font-weight="700" fill="#ff8c42" text-anchor="middle">S</text>
</svg>
```

- [ ] **Step 3: Rewrite `site/templates/header.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{{TITLE}} — SMK</title>
<meta name="description" content="{{DESCRIPTION}}">
<link rel="icon" type="image/svg+xml" href="{{ROOT}}assets/favicon.svg">
<link rel="stylesheet" href="{{ROOT}}assets/style.css">
</head>
<body>
<nav class="site-nav">
  <a href="{{ROOT}}index.html" class="brand">smk</a>
  <div class="nav-links">
    <a href="{{ROOT}}docs/index.html">Docs</a>
    <a href="{{ROOT}}index.html#targets">Targets</a>
    <a href="https://github.com/mburger89/SMK">GitHub</a>
  </div>
</nav>
<main class="site-main">
```

- [ ] **Step 4: Rewrite `site/templates/footer.html`**

```html
</main>
<footer class="site-footer">
  <span>SMK — GPL-3.0</span>
  <div class="footer-links">
    <a href="https://github.com/mburger89/SMK">GitHub</a>
    <a href="{{ROOT}}docs/index.html">Docs</a>
  </div>
</footer>
</body>
</html>
```

- [ ] **Step 5: Rebuild and sanity-check**

Run: `python3 site/build.py && grep -c 'style.css' site/dist/index.html && grep -c 'site-nav' site/dist/index.html`
Expected: both greps return `1` (or more) — confirms the new templates render through the existing pipeline without error.

- [ ] **Step 6: Commit**

```bash
git add site/assets/style.css site/assets/favicon.svg site/templates/header.html site/templates/footer.html
git commit -m "Add site theme: dark glass UI, blue-only background glow, orange accents"
```

---

### Task 3: Landing page content

**Files:**
- Modify: `site/pages/index.html` (replaces Task 1's placeholder)

**Interfaces:**
- Consumes: CSS classes from Task 2 (`.hero`, `.hero-card`, `.glass-card`, `.btn-accent`, `.btn-glass`, `.page-section`, `.section-label`, `.features-grid`, `.feature-card`, `.chip-row`, `.chip`, `.status`, `.quickstart-note`); front-matter contract from Task 1.
- Produces: the `#targets` anchor the nav's "Targets" link (Task 2) points to; the `docs/index.html` link the "Get Started" CTA and quick-start note point to (must exist by the time Task 4 lands — fine, this task only creates the link, not a dependency at build time since `build.py` doesn't validate links, only Task 7's link-checker does).

- [ ] **Step 1: Replace `site/pages/index.html`**

```html
<!-- TITLE: Home -->
<!-- DESCRIPTION: SMK is keyboard firmware written in Embedded Swift, targeting six hardware platforms with BLE and USB HID. -->
<section class="hero">
  <div class="hero-card glass-card">
    <div class="hero-eyebrow">$ swiftc --target riscv32-embedded-none</div>
    <h1>A keyboard firmware written in <span class="accent">Embedded Swift</span>.</h1>
    <p class="subhead">Six hardware targets. One codebase. BLE + USB HID, no RTOS abstraction tax.</p>
    <div class="btn-row">
      <a href="docs/index.html" class="btn-accent">Get Started</a>
      <a href="https://github.com/mburger89/SMK" class="btn-glass">View on GitHub</a>
    </div>
  </div>
</section>

<section class="page-section">
  <div class="section-label">Why SMK</div>
  <div class="features-grid">
    <div class="feature-card">🧬 Real Embedded Swift on bare metal — safety and modern syntax, no VM or GC.</div>
    <div class="feature-card">🧩 Layer engine with JSON keymaps — momentary layers, toggles, transparent keys.</div>
    <div class="feature-card">🔗 BLE + Wired HID, switchable at runtime with a single dual-mode firmware.</div>
    <div class="feature-card">💡 Per-key RGB backlight, opt-in — off by default, on when you wire it up.</div>
  </div>
</section>

<section class="page-section" id="targets">
  <div class="section-label">Supported Targets</div>
  <div class="chip-row">
    <div class="chip">ESP32-C6 <span class="status">✅ BLE + Wired</span></div>
    <div class="chip">RP2040 (Pico) <span class="status">✅ USB HID</span></div>
    <div class="chip">RP2040 (Pico W) <span class="status">✅ USB + BLE scaffolded</span></div>
    <div class="chip">RP2350 (Pico 2 / 2 W) <span class="status">🚧 build-only</span></div>
    <div class="chip">smk_kbd_rp2040 <span class="status">✅ USB + RGB</span></div>
    <div class="chip">nRF52840 <span class="status">🚧 build-only</span></div>
    <div class="chip">STM32F4 <span class="status">🚧 build-only</span></div>
    <div class="chip">STM32WB <span class="status">🚧 build-only</span></div>
  </div>
</section>

<section class="page-section">
  <div class="section-label">Quick Start</div>
  <pre><code>idf.py set-target esp32c6 &amp;&amp; idf.py build &amp;&amp; idf.py flash monitor</code></pre>
  <p class="quickstart-note">That's the ESP32-C6 path — SMK's primary, hardware-verified board. <a href="docs/index.html">See the full docs</a> for every target's prerequisites and build commands.</p>
</section>
```

- [ ] **Step 2: Rebuild and check for key content**

Run: `python3 site/build.py && grep -q "Embedded Swift" site/dist/index.html && grep -q "Get Started" site/dist/index.html && grep -q 'id="targets"' site/dist/index.html && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add site/pages/index.html
git commit -m "Add marketing landing page content"
```

---

### Task 4: Docs hub, architecture, and keymap reference pages

**Files:**
- Create: `site/pages/docs/index.html`
- Create: `site/pages/docs/architecture.html`
- Create: `site/pages/docs/keymap.html`

**Interfaces:**
- Consumes: front-matter contract and CSS from Tasks 1-2 (`.docs-index-list`, `.back-link`, plus global `.site-main h1/h2/p.lede/ul/table` styling).
- Produces: the five `targets/*.html` links `docs/index.html` points to (created in Task 5 — same non-blocking-link relationship as Task 3/4).

- [ ] **Step 1: Create `site/pages/docs/index.html`**

```html
<!-- TITLE: Docs -->
<!-- DESCRIPTION: SMK documentation — per-target build guides, architecture, and keymap reference. -->
<h1>Documentation</h1>
<p class="lede">Everything here is reformatted from this repo's <code>README.md</code> and <code>CLAUDE.md</code> — pick a target to get building, or read the architecture/keymap reference pages for how the firmware fits together.</p>

<div class="section-label">Build Guides by Target</div>
<ul class="docs-index-list">
  <li><a href="targets/esp32c6.html">ESP32-C6 — the primary, hardware-verified board (BLE + Wired HID)</a></li>
  <li><a href="targets/rp2040.html">RP2040 / RP2350 (Pico, Pico W, Pico 2, Pico 2 W, smk_kbd_rp2040) — USB HID, BLE on W variants</a></li>
  <li><a href="targets/nrf52840.html">nRF52840 — USB HID + BLE HID, build-only</a></li>
  <li><a href="targets/stm32f4.html">STM32F4 (WeAct Black Pill) — USB HID, build-only</a></li>
  <li><a href="targets/stm32wb.html">STM32WB (NUCLEO-WB55RG) — USB HID + BLE HID, build-only</a></li>
</ul>

<div class="section-label">Reference</div>
<ul class="docs-index-list">
  <li><a href="architecture.html">Architecture — the Swift↔C boundary, shared source layout, and key patterns</a></li>
  <li><a href="keymap.html">Keymap Reference — the <code>keymap.json</code> schema and key-action syntax</a></li>
</ul>

<a class="back-link" href="../index.html">← Back to Home</a>
```

- [ ] **Step 2: Create `site/pages/docs/architecture.html`**

```html
<!-- TITLE: Architecture -->
<!-- DESCRIPTION: How SMK's Swift and C code fit together — the Swift/C boundary, shared source layout, and the matrix scan/layer/HID dispatch patterns. -->
<h1>Architecture</h1>
<p class="lede">SMK is written mostly in Embedded Swift, with a thin C layer for vendor SDK glue (ESP-IDF, pico-sdk, BTstack, TinyUSB) where the calling convention or struct-heavy config APIs make Swift impractical.</p>

<h2>The Swift ↔ C Boundary</h2>
<ul>
  <li><code>Sources/smk/Bridging.h</code> — C headers imported into Swift; declares every C function callable from Swift.</li>
  <li>Swift calls into C via <code>@_extern(c, "fn_name")</code> (BLE init, GPIO init, FreeRTOS delay, logging).</li>
  <li>Swift exposes its entry point to C via <code>@_cdecl("app_main_swift")</code>, called from <code>Sources/components/kb_main.c</code>'s <code>app_main()</code>.</li>
</ul>

<h2>A real bug this project hit: volatile MMIO in Swift</h2>
<p>Register-polling loops written in Swift <strong>must</strong> call an opaque C function inside the loop body (e.g. <code>smk_cpu_nop()</code>), because <code>UnsafeMutablePointer.pointee</code> is <em>not</em> a volatile access in Swift — LLVM treats an empty-bodied <code>while (reg.pointee &amp; bit) == 0 {}</code> as loop-invariant and deletes it outright under the forward-progress rule, silently turning a hardware wait into no wait at all. This was found by disassembling the STM32 ports' clock-init code; any future port doing direct MMIO polling from Swift will hit it again.</p>

<h2>Shared Swift Sources</h2>
<p><code>Sources/smk/</code> and <code>Sources/SMKCore/</code> compile into every target. <code>Sources/SMKCore/</code> in particular has zero hardware/<code>@_extern</code> calls, so it's also exposed as a real, host-testable Swift Package library (<code>SMK_HOST_TESTS_ONLY=1 swift test</code> — no embedded toolchain required):</p>
<table>
  <tr><th>File</th><th>Responsibility</th></tr>
  <tr><td><code>Modifier.swift</code></td><td>Modifier-key bit-flag enum</td></tr>
  <tr><td><code>Debounce.swift</code></td><td><code>DebouncedMatrix</code> — counter-based debounce</td></tr>
  <tr><td><code>ConnectionMode.swift</code></td><td>wired/Bluetooth toggle</td></tr>
  <tr><td><code>HIDReport.swift</code></td><td>HID report byte-building</td></tr>
  <tr><td><code>Config.swift</code></td><td>matrix-config JSON parsing</td></tr>
  <tr><td><code>LayerEngine.swift</code></td><td>keymap JSON loading, layer state, action resolution</td></tr>
  <tr><td><code>LEDChainMapping.swift</code></td><td>serpentine row/col → RGB chain-position mapping</td></tr>
  <tr><td><code>KeyEventProcessing.swift</code></td><td>press/release edge detection, layer add/remove, HID report assembly — called once per scan cycle</td></tr>
  <tr><td><code>KeymapFrame.swift</code></td><td>shared keymap-store frame format (CRC32 + header pack/unpack)</td></tr>
  <tr><td><code>KeymapProtocol.swift</code></td><td>shared BEGIN/CHUNK/COMMIT/ERASE keymap upload protocol dispatch</td></tr>
</table>

<h2>Key Architectural Patterns</h2>
<p><strong>Matrix scan direction</strong> depends on <code>matrix.colsAreDriven</code> in the board's JSON config, since different boards wire diodes/strobe direction oppositely — columns strobed and rows sensed on ESP32-C6's smk_kbd board (COL2ROW), rows strobed and columns sensed on RP2040 boards.</p>
<p><strong>Layer resolution</strong> (<code>LayerEngine.getAction</code>) iterates layers from highest index to 0, skipping inactive layers and transparent keys, returning the first non-transparent action. Layer 0 is always active.</p>
<p><strong>HID dispatch</strong>: each scan tick builds a <code>HIDReport</code> from all currently pressed key/modifier actions, then sends it via <code>send_keyboard_report</code> (BLE) or <code>send_wired_report</code> (CH9350 UART) depending on the active <code>ConnectionMode</code>.</p>

<a class="back-link" href="index.html">← Back to Docs</a>
```

- [ ] **Step 3: Create `site/pages/docs/keymap.html`**

```html
<!-- TITLE: Keymap Reference -->
<!-- DESCRIPTION: The keymap.json schema and key-action syntax used to configure SMK's matrix and layers. -->
<h1>Keymap Reference</h1>
<p class="lede">The active keymap is the <code>configJson</code> string literal in <code>Sources/smk/Main.swift</code>. The <code>keymap.json</code> at the repo root is a reference copy only — edits there don't affect the firmware until copied into <code>Main.swift</code>.</p>

<h2>Schema</h2>
<ul>
  <li><code>matrix</code> — defines <code>rows</code> and <code>cols</code> GPIO pin lists, plus <code>colsAreDriven</code> (0/1): whether columns are the strobed/output side (1) or rows are (0, default). Depends on your diode orientation — see the <a href="architecture.html">Architecture</a> page's matrix scan section.</li>
  <li><code>layers</code> — an array of layers, each a 2D array of action strings (see below).</li>
</ul>

<h2>Key Action Syntax</h2>
<table>
  <tr><th>Syntax</th><th>Meaning</th></tr>
  <tr><td><code>key:&lt;char&gt;</code></td><td>Standard keycode, e.g. <code>key:a</code>, <code>key:enter</code></td></tr>
  <tr><td><code>mod:&lt;name&gt;</code></td><td>Modifier, e.g. <code>mod:leftShift</code></td></tr>
  <tr><td><code>mo:&lt;n&gt;</code></td><td>Momentary layer <code>n</code> — active while held</td></tr>
  <tr><td><code>tg:&lt;n&gt;</code></td><td>Toggle layer <code>n</code></td></tr>
  <tr><td><code>trans</code></td><td>Transparent — falls through to the layer below</td></tr>
  <tr><td><code>toggle_conn</code></td><td>Switch between BLE and wired modes</td></tr>
  <tr><td><code>none</code></td><td>No action</td></tr>
</table>

<a class="back-link" href="index.html">← Back to Docs</a>
```

- [ ] **Step 4: Rebuild and spot-check**

Run: `python3 site/build.py && grep -q "volatile MMIO" site/dist/docs/architecture.html && grep -q "toggle_conn" site/dist/docs/keymap.html && grep -q "targets/esp32c6.html" site/dist/docs/index.html && echo OK`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add site/pages/docs/index.html site/pages/docs/architecture.html site/pages/docs/keymap.html
git commit -m "Add docs hub, architecture, and keymap reference pages"
```

---

### Task 5: Per-target build-guide pages

**Files:**
- Create: `site/pages/docs/targets/esp32c6.html`
- Create: `site/pages/docs/targets/rp2040.html`
- Create: `site/pages/docs/targets/nrf52840.html`
- Create: `site/pages/docs/targets/stm32f4.html`
- Create: `site/pages/docs/targets/stm32wb.html`

**Interfaces:**
- Consumes: front-matter contract and global docs CSS from Tasks 1-2; each page's `../index.html` back-link targets `docs/index.html` from Task 4.
- Produces: nothing consumed by later tasks except Task 7's link-checker output.

- [ ] **Step 1: Create `site/pages/docs/targets/esp32c6.html`**

```html
<!-- TITLE: ESP32-C6 -->
<!-- DESCRIPTION: Build and flash SMK for the ESP32-C6 — BLE and Wired HID, the primary hardware-verified target. -->
<h1>ESP32-C6</h1>
<p class="lede">RISC-V, built with ESP-IDF. BLE (NimBLE) + Wired (CH9350 UART) HID. This is SMK's primary, hardware-verified target — the <strong>smk_kbd</strong> board's build.</p>

<h2>Prerequisites</h2>
<ul>
  <li><strong>ESP-IDF v6.0.1</strong>, installed via the standard installer (<code>~/.espressif/v6.0.1/esp-idf</code>) and sourced via <code>. ~/.espressif/v6.0.1/esp-idf/export.sh</code> — a top-level <code>~/export-esp-idf.sh</code> alias also works if you've set one up.</li>
  <li><strong>Swift 6.3.1 Embedded RISC-V toolchain</strong>, installed in <code>~/Library/Developer/Toolchains/</code>.</li>
</ul>

<h2>Build &amp; Flash</h2>
<pre><code># Source ESP-IDF environment first
. ~/.espressif/v6.0.1/esp-idf/export.sh   # or your own export-esp-idf.sh alias

idf.py set-target esp32c6   # one-time target selection
idf.py build                 # compile Swift + C and link
idf.py flash monitor         # flash to device and open serial monitor
</code></pre>
<p>The build compiles Swift via a custom command in <code>main/CMakeLists.txt</code>, which auto-discovers the swiftc toolchain from <code>~/Library/Developer/Toolchains/</code> or the <code>SWIFTC_PATH</code> environment variable.</p>

<a class="back-link" href="../index.html">← Back to Docs</a>
```

- [ ] **Step 2: Create `site/pages/docs/targets/rp2040.html`**

```html
<!-- TITLE: RP2040 / RP2350 -->
<!-- DESCRIPTION: Build and flash SMK for Pico, Pico W, Pico 2, Pico 2 W, and smk_kbd_rp2040 — USB HID, BLE on W variants. -->
<h1>RP2040 / RP2350</h1>
<p class="lede">Covers the Raspberry Pi <strong>Pico</strong> (USB HID), <strong>Pico W</strong> (USB HID + BLE), their RP2350-based successors <strong>Pico 2</strong> / <strong>Pico 2 W</strong> (build-only, not yet hardware-verified), and the chip-down <strong>smk_kbd_rp2040</strong> board (RP2040 + CYW43439 — USB HID + per-key RGB working, BLE not yet hardware-confirmed). One shared codebase, only the hardware platform layer differs per board.</p>

<h2>Prerequisites</h2>
<ul>
  <li><strong>pico-sdk</strong> at <code>~/pico-sdk</code> with submodules initialized (<code>git -C ~/pico-sdk submodule update --init</code>).</li>
  <li><strong>ARM toolchain with newlib</strong>: <code>brew tap osx-cross/arm &amp;&amp; brew install osx-cross/arm/arm-gcc-bin@14</code>.</li>
  <li><strong>cmake ≥ 3.29, ninja, picotool</strong>: <code>brew install cmake ninja picotool</code>.</li>
  <li><strong>Swift ≥ 6.3 Embedded ARM toolchain</strong>, installed in <code>~/Library/Developer/Toolchains/</code>.</li>
  <li><strong>RP2350 only</strong> (<code>pico2</code>/<code>pico2_w</code>): additionally requires a Swift development-snapshot toolchain (confirmed working: <code>swift-DEVELOPMENT-SNAPSHOT-2026-05-27-a</code> or later) that ships a real Embedded-Swift stdlib for <code>armv8m.main-none-none-eabi</code>. Released <code>swift-6.3.x</code> toolchains report support for that triple but fail an actual compile — they don't ship the stdlib.</li>
</ul>

<h2>Build &amp; Flash</h2>
<pre><code>export PICO_SDK_PATH=~/pico-sdk

./build_rp2040.sh pico      # plain Pico — USB HID only
./build_rp2040.sh pico_w    # Pico W — USB HID + BLE
./build_rp2040.sh pico2     # Pico 2 — USB HID only
./build_rp2040.sh pico2_w   # Pico 2 W — USB HID + BLE
</code></pre>
<p>Produces <code>build_rp2040_&lt;board&gt;/smk_rp2040.uf2</code>. Flash by holding <strong>BOOTSEL</strong>, connecting USB, then:</p>
<pre><code>picotool load -f build_rp2040_pico/smk_rp2040.uf2</code></pre>

<a class="back-link" href="../index.html">← Back to Docs</a>
```

- [ ] **Step 3: Create `site/pages/docs/targets/nrf52840.html`**

```html
<!-- TITLE: nRF52840 -->
<!-- DESCRIPTION: Build SMK for the Nordic nRF52840 — USB HID + BLE HID, build-only, not yet hardware-verified. -->
<h1>nRF52840</h1>
<p class="lede">Arm Cortex-M4F. USB HID (TinyUSB) + BLE HID (Nordic's SoftDevice Controller over BTstack). Build-only for now — not yet verified on real hardware, and the GPIO pin map is an explicit placeholder that must be replaced with schematic-verified pins before ever flashing a real board.</p>

<h2>Prerequisites</h2>
<ul>
  <li><strong>nRF5 SDK</strong> (CMSIS device header + Cortex-M4 startup/linker script) at <code>~/nRF5_SDK</code> — download v17.1.0+ from Nordic and unzip. Only <code>modules/nrfx/mdk/</code> is used.</li>
  <li><strong>sdk-nrfxlib</strong> (prebuilt SoftDevice Controller + MPSL libraries) at <code>~/sdk-nrfxlib</code>: <code>git clone https://github.com/nrfconnect/sdk-nrfxlib ~/sdk-nrfxlib</code>.</li>
  <li><strong>TinyUSB</strong> at <code>~/tinyusb</code>: <code>git clone https://github.com/hathach/tinyusb ~/tinyusb</code>.</li>
  <li><strong>BTstack</strong> at <code>~/btstack</code>: <code>git clone https://github.com/bluekitchen/btstack ~/btstack</code>.</li>
  <li><strong>ARM toolchain with newlib</strong> — same <code>arm-gcc-bin@14</code> already required for RP2040.</li>
  <li><strong>Swift Embedded ARM toolchain</strong> — same one already required for RP2040/ESP32-C6.</li>
</ul>

<h2>Build</h2>
<pre><code>export NRF5_SDK_PATH=~/nRF5_SDK
export NRFXLIB_PATH=~/sdk-nrfxlib
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack

./build_nrf52840.sh
</code></pre>
<p><strong>Known gaps</strong>: runtime keymap store is a no-op stub (nothing persists across reboots), LE bonding does not survive a reboot, and the millisecond timers are uncalibrated software counters until a real hardware timer is wired up.</p>

<a class="back-link" href="../index.html">← Back to Docs</a>
```

- [ ] **Step 4: Create `site/pages/docs/targets/stm32f4.html`**

```html
<!-- TITLE: STM32F4 -->
<!-- DESCRIPTION: Build SMK for the STM32F4 WeAct Black Pill — USB HID, build-only, not yet hardware-verified. -->
<h1>STM32F4</h1>
<p class="lede">WeAct Black Pill (STM32F411CEU6), Arm Cortex-M4F. USB HID via TinyUSB's <code>dwc2</code> driver — no BLE this pass (see the STM32WB page). Build-only for now, not yet verified on real hardware; the bring-up matrix is a placeholder, not a real keyboard layout.</p>

<h2>Prerequisites</h2>
<ul>
  <li><strong>cmsis-device-f4</strong> (CMSIS device headers + Cortex-M4 startup assembly — no GCC linker script shipped, this project hand-writes its own) at <code>~/cmsis-device-f4</code>: <code>git clone https://github.com/STMicroelectronics/cmsis-device-f4 ~/cmsis-device-f4</code>.</li>
  <li><strong>CMSIS_6</strong> (ARM's own Cortex-M4 core headers) at <code>~/CMSIS_6</code>: <code>git clone https://github.com/ARM-software/CMSIS_6 ~/CMSIS_6</code>.</li>
  <li><strong>TinyUSB</strong> at <code>~/tinyusb</code> (shared with RP2040/nRF52840 — no new clone if you already have one).</li>
  <li><strong>ARM toolchain with newlib</strong> and <strong>Swift Embedded ARM toolchain</strong> — same ones already required for RP2040/nRF52840.</li>
</ul>

<h2>Build</h2>
<pre><code>export CMSIS_F4_PATH=~/cmsis-device-f4
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb

./build_stm32f4.sh
</code></pre>

<a class="back-link" href="../index.html">← Back to Docs</a>
```

- [ ] **Step 5: Create `site/pages/docs/targets/stm32wb.html`**

```html
<!-- TITLE: STM32WB -->
<!-- DESCRIPTION: Build SMK for the STM32WB NUCLEO-WB55RG — USB HID + BLE HID, build-only, unresolved license conflict on distribution. -->
<h1>STM32WB</h1>
<p class="lede">NUCLEO-WB55RG — an Arm Cortex-M4 application core plus an on-chip Cortex-M0+ radio coprocessor running ST's own firmware. USB HID (TinyUSB's <code>fsdev</code> driver) + BLE HID (ST's HCI-Layer wireless coprocessor over a vendored IPCC transport layer, bridged into BTstack). Build-only, not yet verified on real hardware.</p>

<p><strong>⚠ Unresolved license conflict — do not distribute a build of this port.</strong> This repo is GPL-3.0, but the vendored IPCC transport-layer files (<code>tl_mbox.c</code>, <code>shci.c</code>, <code>shci_tl.c</code>, sourced from STM32CubeWB) are licensed under ST's SLA0044, which forbids GPL redistribution. This was flagged during the port and deliberately deferred rather than resolved.</p>

<h2>Prerequisites</h2>
<ul>
  <li><strong>cmsis-device-wb</strong> at <code>~/cmsis-device-wb</code>: <code>git clone https://github.com/STMicroelectronics/cmsis-device-wb ~/cmsis-device-wb</code>.</li>
  <li><strong>CMSIS_6</strong> (shared with STM32F4 — no new clone if you already have one).</li>
  <li><strong>TinyUSB</strong> and <strong>BTstack</strong> (shared with the other ports — no new clone if you already have them).</li>
  <li><strong>STM32CubeWB, pinned at v1.24.0</strong> (the IPCC transport-layer source plus the prebuilt CPU2 "HCI Layer" firmware binary — later tags moved this to a submodule that no longer covers dual-core WB55): <code>git clone --branch v1.24.0 https://github.com/STMicroelectronics/STM32CubeWB ~/STM32CubeWB</code>.</li>
  <li><strong>ARM toolchain with newlib</strong> and <strong>Swift Embedded ARM toolchain</strong> — same ones already required for the other ARM ports.</li>
</ul>

<h2>Build</h2>
<pre><code>export CMSIS_WB_PATH=~/cmsis-device-wb
export CMSIS_CORE_PATH=~/CMSIS_6
export TINYUSB_PATH=~/tinyusb
export BTSTACK_PATH=~/btstack
export STM32CUBEWB_PATH=~/STM32CubeWB

./build_stm32wb.sh
</code></pre>
<p><strong>Before flashing real hardware</strong>: the GPIO pin map is a bring-up placeholder (5×5 test matrix), factory HSE capacitor trim isn't applied, and CPU2 needs a separate manual flash of ST's "HCI Layer" wireless-coprocessor firmware (e.g. <code>stm32wb5x_BLE_HCILayer_extended_fw.bin</code>) via ST's own tooling — this repo's build only produces the CPU1 application image.</p>

<a class="back-link" href="../index.html">← Back to Docs</a>
```

- [ ] **Step 6: Rebuild and spot-check**

Run: `python3 site/build.py && for f in esp32c6 rp2040 nrf52840 stm32f4 stm32wb; do grep -q "<h1>" "site/dist/docs/targets/$f.html" || echo "MISSING $f"; done; echo done`
Expected: `done` with no `MISSING` lines.

- [ ] **Step 7: Commit**

```bash
git add site/pages/docs/targets
git commit -m "Add per-target build guide pages"
```

---

### Task 6: GitHub Actions deploy workflow

**Files:**
- Create: `.github/workflows/deploy-pages.yml`

**Interfaces:**
- Consumes: `python3 site/build.py` CLI from Task 1, whose output (`site/dist/`) this workflow publishes.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Create `.github/workflows/deploy-pages.yml`**

```yaml
name: Deploy Site

on:
  push:
    branches: [main]
    paths:
      - 'site/**'
      - '.github/workflows/deploy-pages.yml'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build site
        run: python3 site/build.py

      - name: Deploy to gh-pages
        uses: peaceiris/actions-gh-pages@v4
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: site/dist
          publish_branch: gh-pages
```

- [ ] **Step 2: Sanity-check the workflow file**

Run: `grep -q '^on:' .github/workflows/deploy-pages.yml && grep -q '^jobs:' .github/workflows/deploy-pages.yml && grep -q "site/\*\*" .github/workflows/deploy-pages.yml && grep -q "python3 site/build.py" .github/workflows/deploy-pages.yml && echo OK`
Expected: `OK`. (Full validation happens when this workflow actually runs in GitHub Actions after a real push — see the "Manual follow-up" note at the end of this plan.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-pages.yml
git commit -m "Add GitHub Actions workflow to deploy the site to gh-pages"
```

---

### Task 7: Link-checker + full-site verification + README pointer

**Files:**
- Create: `site/check_links.py`
- Create: `site/test_check_links.py`
- Modify: `README.md`

**Interfaces:**
- Consumes: `python3 site/build.py`'s output layout (`site/dist/**.html`) from Task 1, and the actual content/links produced by Tasks 3-6.
- Produces:
  - `find_broken_links(dist_dir: pathlib.Path) -> list[str]` — scans every `site/dist/**/*.html` for `href="..."` values, skips absolute (`http(s)://`) and same-page (`#...`) links, resolves everything else relative to the linking page's directory, and returns a list of `"<page> -> <href>"` strings for any target that doesn't exist under `dist_dir`.
  - CLI: `python3 site/check_links.py` exits non-zero and prints each broken link if any are found, otherwise prints `All local links resolve.` and exits 0.

- [ ] **Step 1: Write the failing test**

Create `site/test_check_links.py`:

```python
import pathlib
import tempfile
import unittest

from check_links import find_broken_links


class FindBrokenLinksTests(unittest.TestCase):
    def test_flags_missing_target_but_not_existing_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            dist_dir = pathlib.Path(tmp)
            (dist_dir / "docs").mkdir()
            (dist_dir / "docs" / "index.html").write_text("<h1>Docs</h1>")
            (dist_dir / "index.html").write_text(
                '<a href="docs/index.html">Docs</a>'
                '<a href="missing.html">Missing</a>'
                '<a href="https://github.com/mburger89/SMK">External</a>'
                '<a href="#targets">Anchor</a>'
            )

            broken = find_broken_links(dist_dir)

            self.assertEqual(len(broken), 1)
            self.assertIn("missing.html", broken[0])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd site && python3 -m unittest test_check_links.py -v`
Expected: FAIL/ERROR — `ModuleNotFoundError: No module named 'check_links'`.

- [ ] **Step 3: Implement `site/check_links.py`**

```python
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd site && python3 -m unittest test_check_links.py -v`
Expected: PASS

- [ ] **Step 5: Run the full build + link check against the real site**

Run: `python3 site/build.py && python3 site/check_links.py`
Expected: `All local links resolve.` with exit code 0. If any broken links are printed, fix the offending `href` in the page listed and re-run this step before continuing — every internal link from Tasks 3-6 (hero CTA, docs hub, back-links, target pages, `#targets` anchor) must resolve.

- [ ] **Step 6: Add a docs pointer to `README.md`**

In `README.md`, immediately after the title line (`# SMK (Swift Matrix Keyboard)`), add:

```markdown

📖 **[Read the docs and see the full feature list](https://mburger89.github.io/SMK/)**
```

- [ ] **Step 7: Commit**

```bash
git add site/check_links.py site/test_check_links.py README.md
git commit -m "Add site link-checker and point README at the new docs site"
```

---

## Manual follow-up (not part of this plan's tasks — requires explicit go-ahead)

This plan's tasks build and commit everything locally on `main`. Two remaining steps make the site actually public and are **not** automated by this plan, since they push to the remote and enable a publicly-visible GitHub Pages site — confirm with the repo owner before doing them:

1. `git push origin main` — this is what triggers the new `deploy-pages.yml` workflow for the first time.
2. In the GitHub repo's **Settings → Pages**, set the source to the `gh-pages` branch (root), after the first workflow run has created that branch. Then verify the live site at `https://mburger89.github.io/SMK/` — click through every nav link and docs page in a real browser, and confirm the visual direction (dark base, blue-only background glow, Liquid-Glass panels, orange accents) renders as intended, per the spec's Testing section.
