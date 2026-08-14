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
