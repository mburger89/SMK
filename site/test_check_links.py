import pathlib
import shutil
import subprocess
import sys
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


class MainMissingDistDirTests(unittest.TestCase):
    def test_exits_nonzero_and_errors_when_dist_dir_missing(self):
        # Run check_links.py as a script (not import find_broken_links directly)
        # from a fresh temp copy of the site/ dir with no dist/ subdirectory,
        # so this doesn't touch the real site/dist/ and isolates the __main__
        # guard's behavior from find_broken_links() itself.
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = pathlib.Path(tmp)
            script = shutil.copy(
                pathlib.Path(__file__).parent / "check_links.py",
                tmp_path / "check_links.py",
            )

            result = subprocess.run(
                [sys.executable, str(script)],
                cwd=tmp_path,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not exist", result.stdout)
            self.assertNotIn("All local links resolve.", result.stdout)


if __name__ == "__main__":
    unittest.main()
