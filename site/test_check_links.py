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
