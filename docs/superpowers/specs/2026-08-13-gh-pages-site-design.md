# GitHub Pages Site (Marketing + Docs)

Date: 2026-08-13
Status: Approved, pending implementation plan

## Problem

SMK has no public-facing site — only the GitHub repo, README.md, and
CLAUDE.md. This spec adds a GitHub Pages site that serves two purposes in
one: a marketing landing page (the hook is "a keyboard firmware written in
Embedded Swift," aimed at both keyboard enthusiasts and Swift/embedded
developers), and a browsable multi-page docs section that reformats the
existing per-target build instructions and architecture notes from
README.md/CLAUDE.md into something easier to navigate than one long
Markdown file.

Out of scope: an interactive keymap visualizer/editor (considered and
explicitly dropped — static-only keymap reference page instead), a custom
domain (uses the default `mburger89.github.io/SMK` URL), and any new
technical writing — every docs page is a reformat of content that already
exists in README.md/CLAUDE.md, not new documentation.

## Visual design

Locked in via mockup review (browser-based brainstorming companion):

- Dark base (near-black `#0b0c10`/`#14151c` gradient background), not a
  light/white theme.
- Ambient background glow is **blue only** (`rgba(90,130,255,...)` /
  `rgba(60,90,200,...)` radial gradients, positioned top-left) — no orange
  in the background.
- Orange (`#ff8c42`, Swift-brand-adjacent) is reserved for accents only:
  the primary CTA button, code-snippet highlights, and links/hover states.
- Apple Liquid-Glass-style panels throughout: translucent
  `background: rgba(255,255,255,0.05-0.08)` with `backdrop-filter:
  blur(12-18px)`, a light `1px` border (`rgba(255,255,255,0.12-0.16)`),
  and a layered shadow (`box-shadow: 0 8-20px 24-50px rgba(0,0,0,0.35-0.4),
  inset 0 1px 0 rgba(255,255,255,0.15-0.2)`) for the specular-highlight
  edge. Applies to the nav bar, hero card, and small floating chips
  (e.g. the supported-targets pill list).
- Monospace (`ui-monospace, Menlo`) used for code snippets and small
  technical labels (e.g. `$ swiftc --target riscv32-embedded-none`) to
  keep the dev-tool feel; `-apple-system` sans-serif for body copy and
  headings.

Reference mockups from the brainstorming session are not carried into the
repo — this section is the source of truth for implementation.

## Landing page structure

Single scrolling page, top to bottom:

1. **Nav** (glass bar): `smk` wordmark, links to `Docs`, `Targets`
   (anchor into the landing page's supported-targets section), `GitHub`
   (external link to the repo).
2. **Hero**: monospace command-line-style eyebrow line, headline "A
   keyboard firmware written in **Embedded Swift**." (Embedded Swift in
   orange), one-line subhead ("Six hardware targets. One codebase. BLE +
   USB HID, no RTOS abstraction tax."), CTA pair — `Get Started` (orange,
   links to docs hub) and `View on GitHub` (glass button, external link).
3. **"Why SMK" feature grid**: 2×2 (or similar) glass cards — Embedded
   Swift on bare metal, layer engine/JSON keymaps, BLE + Wired dual mode,
   opt-in per-key RGB. Pulled from README.md's Features list.
4. **Supported targets**: pill/chip row, one per target from CLAUDE.md's
   Supported Targets table, each labeled with its working/build-only
   status (✅/🚧) matching that table.
5. **Quick start teaser**: one real command block (ESP32-C6's
   `idf.py set-target esp32c6 && idf.py build flash monitor`, the primary
   board) plus a line linking through to the full docs.
6. **Footer**: license (GPL-3.0), links to GitHub/Docs.

## Docs section

- **`docs/index.html`** — hub page linking to every page below.
- **Per-target pages** (`docs/targets/{esp32c6,rp2040,nrf52840,stm32f4,
  stm32wb}.html`) — one page per target family (RP2040 page covers
  RP2040/RP2350/Pico-W/smk_kbd_rp2040 together, matching how CLAUDE.md
  already groups them under one Prerequisites/Build subsection each).
  Each page reformats that target's Prerequisites + Build & Flash Commands
  sections from CLAUDE.md.
- **`docs/architecture.html`** — condensed from CLAUDE.md's Architecture
  section: Swift↔C boundary (including the volatile-MMIO/register-polling
  gotcha, since it's a real bug future porters would otherwise re-hit),
  the shared-sources tables (`Sources/smk/`, `Sources/SMKCore/`), and Key
  Architectural Patterns (matrix scan direction, layer resolution, HID
  dispatch).
- **`docs/keymap.html`** — static reference: the `matrix`/`layers` JSON
  schema and the key-action syntax table (`key:<char>`, `mod:<name>`,
  `mo:<n>`, `tg:<n>`, `trans`, `toggle_conn`, `none`) from README.md.
  No interactive editor — this was explicitly considered and dropped to
  keep this pass to a static site.

## Repo layout & build

Site source lives in a new top-level `site/` directory on `main`:

```
site/
  templates/
    header.html       # nav bar partial
    footer.html        # footer partial
  pages/
    index.html
    docs/index.html
    docs/architecture.html
    docs/keymap.html
    docs/targets/esp32c6.html
    docs/targets/rp2040.html
    docs/targets/nrf52840.html
    docs/targets/stm32f4.html
    docs/targets/stm32wb.html
  assets/
    style.css
    favicon.ico (and any hero/OG image assets)
  build.py
```

`build.py` is a small Python script (Python is already a project
prerequisite via ESP-IDF, so this adds no new dependency) that stitches
`templates/header.html` + each `pages/**/*.html` body + `templates/
footer.html` into standalone static HTML files, copies `assets/` through
unchanged, and writes the result to `site/dist/` (gitignored — build
output, not source). This keeps nav/footer edits to one file instead of
duplicating them across 9 pages, while the *published* output is still
plain static HTML/CSS with no client-side templating or JS framework —
good for SEO and for working with JS disabled.

`site/dist/` is not committed on `main` (gitignored); it only exists as a
build artifact inside the CI job described below. A contributor previewing
locally runs `python3 site/build.py && open site/dist/index.html` — this
is the one deviation from "zero build step," accepted as a maintainability
trade-off given ~9 pages sharing one nav/footer.

## Deployment

New GitHub Actions workflow, `.github/workflows/deploy-pages.yml`:

- **Trigger**: push to `main` that touches `site/**` (plus
  `workflow_dispatch` for manual re-runs).
- **Steps**: checkout, run `python3 site/build.py`, publish the resulting
  `site/dist/` directory to the `gh-pages` branch.
- GitHub Pages is configured (repo Settings → Pages) to serve from the
  `gh-pages` branch, root folder.
- No `CNAME` file — the site is served at the default
  `mburger89.github.io/SMK` URL.

`.github/workflows/` already has `host-tests.yml` and `build.yml`; this
adds a third, independent workflow scoped only to `site/**` changes so it
never runs alongside (or blocks on) the firmware CI. Scope is
intentionally narrow (build + publish only, no lint/test step for a
static site).

## Testing / verification

No automated test suite — a static site has nothing meaningful to unit
test. Verification is:

1. `site/build.py` runs cleanly and produces valid HTML for every page
   (no unresolved template placeholders, no broken relative links between
   pages).
2. After the first successful deploy, every nav link and every
   docs-hub link is click-tested end-to-end in a real browser (Chrome, via
   browser automation) against the live `mburger89.github.io/SMK` URL —
   not just visual inspection of the built HTML.
3. Manual visual check against the approved mockup direction (dark base,
   blue-only background glow, orange accents, glass panels) on both the
   landing page and at least one docs page, since docs pages reuse the
   same header/footer/theme.

## Future work (explicitly deferred, not part of this pass)

- Interactive keymap visualizer/editor (dropped from this spec's scope by
  explicit decision during brainstorming).
- Custom domain / CNAME.
- Any docs content beyond what's already in README.md/CLAUDE.md (e.g. a
  troubleshooting/FAQ page, board photos, a getting-started video).
