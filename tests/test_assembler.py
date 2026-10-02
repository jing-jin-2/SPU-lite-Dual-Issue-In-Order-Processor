"""Assembler regression checks; no simulator or third-party packages required."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("spu_assembler", str(ROOT / "tools/asm.py"))
ASM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASM)


class AssemblerTests(unittest.TestCase):
    def test_original_program_encodings(self):
        # Frozen outputs from the original course project, not regenerated here.
        for name in ("demo", "matmul"):
            with self.subTest(program=name):
                words = ASM.assemble((ROOT / "tests/programs" / ("test_" + name + ".s")).read_text())
                expected = [int(line, 16) for line in
                            (ROOT / "tests/fixtures" / ("test_" + name + ".hex")).read_text().splitlines()]
                self.assertLessEqual(len(words), 512)
                self.assertEqual(words + [0] * (512 - len(words)), expected)

    def test_new_lane_program_fits_instruction_memory(self):
        words = ASM.assemble((ROOT / "tests/programs/test_lanes.s").read_text())
        self.assertGreater(len(words), 0)
        self.assertLessEqual(len(words), 512)

    def test_invalid_source_is_rejected(self):
        for source in ("il r128, 0", "il r1, 65536", "unknown r1",
                       "again: nop\nagain: nop", "br missing_label"):
            with self.subTest(source=source):
                with self.assertRaises(SyntaxError):
                    ASM.assemble(source)

    def test_labels_comments_and_relative_branches(self):
        self.assertEqual(ASM.assemble("start: nop # comment\nlnop\nbr start"),
                         ASM.assemble("nop\nlnop\nbr -8"))

    def test_cli_padding_and_overflow(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.s"
            output = Path(directory) / "output.hex"
            source.write_text("nop\nlnop\n")
            command = [sys.executable, str(ROOT / "tools/asm.py"), str(source), "-o", str(output)]
            result = subprocess.run(command + ["--depth", "4"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(output.read_text().splitlines()), 4)
            self.assertEqual(output.read_text().splitlines()[-2:], ["00000000", "00000000"])
            output.unlink()
            result = subprocess.run(command + ["--depth", "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
