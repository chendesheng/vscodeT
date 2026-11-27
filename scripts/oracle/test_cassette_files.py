import json
from pathlib import Path
import tempfile
import unittest

from cassette_files import CassetteFileError, load_cases, validate_names


class CassetteFilesTest(unittest.TestCase):
    def test_case_collision_rejected(self):
        with self.assertRaisesRegex(CassetteFileError, "case-insensitive filename collision"):
            validate_names(["append_A.json", "append_a.json"])

    def test_tracked_alias_detected_even_when_only_one_file_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "append_a.json").write_text(json.dumps({"case": "append_a"}))
            with self.assertRaisesRegex(CassetteFileError, "case-insensitive filename collision"):
                load_cases(directory, tracked_names=["append_A.json", "append_a.json"])

    def test_uppercase_case_id_preserved_and_selectable(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            upper = directory / "append_upper_a.json"
            lower = directory / "append_a.json"
            upper.write_text(json.dumps({"case": "append_A"}))
            lower.write_text(json.dumps({"case": "append_a"}))
            self.assertEqual([lower, upper], load_cases(directory))
            self.assertEqual([upper], load_cases(directory, "append_A"))
            self.assertEqual([upper], load_cases(directory, "append_upper_a"))
            self.assertEqual([lower], load_cases(directory, "append_a"))

    def test_uppercase_filename_rejected_even_without_collision(self):
        with self.assertRaisesRegex(CassetteFileError, "non-portable cassette filename"):
            validate_names(["open_O.json"])

    def test_duplicate_case_id_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name in ("first.json", "second.json"):
                (directory / name).write_text(json.dumps({"case": "same"}))
            with self.assertRaisesRegex(CassetteFileError, "duplicate cassette case ID"):
                load_cases(directory)


if __name__ == "__main__":
    unittest.main()
