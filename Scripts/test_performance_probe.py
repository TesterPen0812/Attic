import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import performance_probe as probe


class PerformancePreviewBuildTests(unittest.TestCase):
    def test_preview_names_only_the_app_target(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            executable = build / "dd/Build/Products/Local/AtticPerf0123456789.app/Contents/MacOS/AtticPerf0123456789"
            executable.parent.mkdir(parents=True)
            executable.touch()
            with patch.object(probe, "BUILD", build), patch.object(probe, "command") as command, \
                    patch.object(probe.subprocess, "check_output", return_value=plistlib.dumps({})):
                app, actual, bundle = probe.build_preview("0123456789")
            invocation = command.call_args_list[1].args
            self.assertIn("ATTIC_MACOS_PRODUCT_NAME=AtticPerf0123456789", invocation)
            self.assertIn("ATTIC_MACOS_EXECUTABLE_NAME=AtticPerf0123456789", invocation)
            self.assertFalse(any(arg.startswith(("PRODUCT_NAME=", "EXECUTABLE_NAME=")) for arg in invocation),
                             "global names also rename cmark-gfm's independent products")
            self.assertEqual(actual, executable)
            self.assertEqual(app, executable.parents[2])
            self.assertEqual(bundle, "com.taha.Attic.perf.0123456789")


if __name__ == "__main__":
    unittest.main()
