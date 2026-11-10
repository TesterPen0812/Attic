"""The interface sounds: the generator reproduces the checked-in files byte
for byte, every cue the app names has one, and each stays short, quiet,
soft at the ends and free of harsh highs."""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_sounds as sounds  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


class GeneratedSoundsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = {name: sounds.encode(sounds.render(name)) for name, _, _ in sounds.CUES}
        cls.measured = {name: sounds.measure(sounds.decode(data)) for name, data in cls.rendered.items()}

    def test_checked_in_files_are_exactly_what_the_generator_writes(self):
        for name, data in self.rendered.items():
            with self.subTest(cue=name):
                path = sounds.OUTPUT / (name + ".wav")
                self.assertTrue(path.exists(), path)
                self.assertEqual(path.read_bytes(), data, "run Scripts/generate_sounds.py")
        self.assertEqual(sorted(p.stem for p in sounds.OUTPUT.glob("*")), sorted(self.rendered))

    def test_rendering_is_deterministic(self):
        for name, _, _ in sounds.CUES:
            self.assertEqual(sounds.encode(sounds.render(name)), self.rendered[name], name)

    def test_every_cue_the_app_names_has_a_sound(self):
        source = (ROOT / "Attic/Services/AtticSounds.swift").read_text()
        body = source.split("enum Cue", 1)[1].split("\n    }\n", 1)[0]
        cues = re.findall(r"^\s+case (\w+)$", body, re.MULTILINE)
        self.assertEqual(cues, [name for name, _, _ in sounds.CUES])

    def test_short_quiet_and_soft(self):
        for name, m in self.measured.items():
            with self.subTest(cue=name):
                limit = 300 if name == "done" else 250
                self.assertLessEqual(m["ms"], limit)
                self.assertLessEqual(m["peak_db"], sounds.PEAK_CEILING)
                self.assertLess(m["above_4k_db"], -30, "no harsh highs")
                self.assertGreater(m["laptop_share"], 0.9, "heard on a laptop's speakers")
                self.assertLess(m["first"] + m["last"], 2e-4, "starts and ends on silence")
        short = [name for name, m in self.measured.items() if m["ms"] < 150]
        self.assertGreaterEqual(len(short), 5, "most under 150 ms")
        self.assertGreater(self.measured["done"]["ms"], self.measured["created"]["ms"])

    def test_loudness_is_consistent_and_undone_is_quieter_than_done(self):
        for name, _, offset in sounds.CUES:
            with self.subTest(cue=name):
                self.assertAlmostEqual(self.measured[name]["loudness"], sounds.TARGET_LOUDNESS + offset, delta=0.3)
        self.assertLess(self.measured["undone"]["loudness"], self.measured["done"]["loudness"] - 3)


if __name__ == "__main__":
    unittest.main()
