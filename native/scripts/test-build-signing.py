#!/usr/bin/env python3
"""Check signing selection without building, signing, installing or touching launchctl."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build-app.sh")
ORIGINAL = "Apple Development: Michael Cann (4BAC88BW64)"
PERSONAL = "Apple Development: Example Person (PERSONAL01)"


class SigningSelectionTests(unittest.TestCase):
    def run_script(self, identities, *args):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            security = root / "security"
            security.write_text('#!/bin/bash\nprintf "%s\\n" "$TEST_SIGNING_LIST"\n')
            security.chmod(0o755)
            swift = root / "swift"
            swift.write_text('#!/bin/bash\necho BUILD_REACHED\nexit 73\n')
            swift.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       TEST_SIGNING_LIST="\n".join(f'  {i}) {"A" * 40} "{name}"' for i, name in enumerate(identities, 1)))
            return subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True)

    def test_default_still_requires_original_identity(self):
        self.assertEqual(self.run_script([PERSONAL]).returncode, 1)
        self.assertEqual(self.run_script([ORIGINAL]).returncode, 73)

    def test_personal_uses_single_identity(self):
        result = self.run_script([PERSONAL], "--personal")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertIn(PERSONAL, result.stdout)

    def test_personal_missing_certificate_stops_before_build(self):
        result = self.run_script([], "--personal")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("BUILD_REACHED", result.stdout)

    def test_multiple_identities_need_explicit_selection(self):
        result = self.run_script([ORIGINAL, PERSONAL], "--personal")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("BUILD_REACHED", result.stdout)
        self.assertEqual(self.run_script([ORIGINAL, PERSONAL], "--personal", PERSONAL).returncode, 73)

    def test_unknown_or_ad_hoc_identity_is_rejected(self):
        self.assertEqual(self.run_script([PERSONAL], "--personal", "Unknown").returncode, 1)
        self.assertEqual(self.run_script([PERSONAL], "--personal", "-").returncode, 1)


if __name__ == "__main__":
    unittest.main()
