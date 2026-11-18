import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from check_test_waits import count_waits, main


class SwiftWaitTests(unittest.TestCase):
    def test_fixed_sleep_calls(self):
        source = """
        Thread.sleep(forTimeInterval: 0.1)
        usleep(100)
        sleep(1)
        Darwin.sleep(1)
        try await Task.sleep(nanoseconds: 100)
        try? await Task /* comment */ .sleep(for: .milliseconds(100))
        func sleep(_ delay: Duration) {}
        clock.sleep(for: .seconds(1))
        Thread.sleepUntilReady()
        """
        self.assertEqual(count_waits(source), {"sleep": 6})

    def test_fixed_run_loop_calls(self):
        source = """
        RunLoop.current.run(until: deadline)
        Foundation.RunLoop.main.run(until: deadline)
        RunLoop.current.run(mode: .default, before: deadline)
        loop.run(mode: mode(from: getMode(a, b)), before: deadline)
        CFRunLoopRunInMode(mode, 0.1, true)
        RunLoop.main.run()
        worker.run(mode: mode, after: deadline)
        """
        self.assertEqual(count_waits(source), {"runloop": 5})

    def test_xctest_skip_calls(self):
        source = """
        throw XCTSkip("reason")
        try XCTSkipIf(condition)
        try XCTSkipUnless(condition)
        throw XCTest.XCTSkip.init("reason")
        XCTSkipCount(1)
        """
        self.assertEqual(count_waits(source), {"skip": 4})

    def test_timeout_literals_at_or_above_thirty(self):
        source = """
        wait(for: [done], timeout: 29)
        wait(for: [done], timeout: 29.999)
        wait(for: [done], timeout: 60)
        waitForExistence(timeout: 30)
        waitForExistence(timeout: 30.0)
        waitForExistence(timeout: 4_5, other: true)
        waitForExistence(timeout: 3e1)
        waitForExistence(timeout: 0x1e)
        eventually(timeout: .seconds(30)) {}
        eventually(timeout: .seconds(29)) {}
        eventually(timeout: .milliseconds(30)) {}
        eventually(timeout: .seconds(30 + offset)) {}
        eventually(timeout: .seconds(30) + offset) {}
        waitForExistence(timeout: 30 + offset)
        waitForExistence(timeout: -30)
        waitForExistence(timeout: fortyFive)
        """
        self.assertEqual(count_waits(source), {"long_timeout": 7})

    def test_comments_and_string_literals_do_not_hide_following_code(self):
        source = r'''
        // sleep(1); throw XCTSkip("line")
        /* RunLoop.current.run(until: deadline)
           /* Thread.sleep(forTimeInterval: 1) */
           try XCTSkipIf(flag) */ usleep(1)
        let escaped = "say \"Thread.sleep(forTimeInterval: 1)\""
        let interpolated = "\(format("hi", nested(1))) XCTSkipIf(flag)"
        let raw = ##" "usleep(1)" \##(format(#"sleep(1)"#)) "##
        let multiline = """
            Task.sleep(for: .seconds(1))
            wait(timeout: .seconds(30))
            """
        let rawMultiline = #"""
            """ and XCTSkipUnless(false)
            """#
        wait(timeout: /* explanatory comment */ 30)
        '''
        self.assertEqual(count_waits(source), {"sleep": 1, "long_timeout": 1})


class WaitGuardTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.test_file = "AtticTests/Support/Helpers.swift"
        self.sleep = "Thread.sleep(forTimeInterval: 0.1)\n"
        self.allowance = "Scripts/test_wait_allowance.json"

    def write_file(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def allow(self, files=None, retry_flags=()):
        return self.write_file(self.allowance, json.dumps({
            "version": 1, "files": files or {}, "retry_flags": list(retry_flags),
        }))

    def run_guard(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main(args, root=self.root)
        return status, output.getvalue()

    def test_over_count_fails(self):
        self.write_file(self.test_file, self.sleep * 2)
        self.allow({self.test_file: {"sleep": 1}})
        status, output = self.run_guard()
        self.assertEqual(status, 1)
        self.assertIn(f"{self.test_file}: sleep count 2, allowance 1", output)
        self.assertIn("wait on a condition or an XCTestExpectation", output)

    def test_under_count_fails(self):
        self.write_file(self.test_file, "// removed the sleep")
        self.allow({self.test_file: {"sleep": 1}})
        status, output = self.run_guard()
        self.assertEqual(status, 1)
        self.assertIn(f"{self.test_file}: sleep count 0, allowance 1", output)
        self.assertIn(f"you removed 1; lower the allowance in {self.allowance}", output)

    def test_new_test_support_file_fails_and_product_source_is_excluded(self):
        new_test = "CanvasLab/Tests/Support/NewSupport.swift"
        self.write_file(new_test, self.sleep)
        self.write_file("CanvasLab/Sources/Product.swift", self.sleep)
        self.allow()
        status, output = self.run_guard()
        self.assertEqual(status, 1)
        self.assertIn(f"{new_test}: sleep count 1, allowance 0", output)
        self.assertNotIn("Product.swift", output)
        self.assertIn("1 Swift test files", output)

    def test_missing_file_fails(self):
        self.allow({self.test_file: {"sleep": 1}})
        status, output = self.run_guard()
        self.assertEqual(status, 1)
        self.assertIn(f"{self.test_file}: sleep count 0, allowance 1", output)
        self.assertIn("remove its entry", output)

    def test_retry_settings_are_detected_in_each_supported_location(self):
        shell = 'xcodebuild test -retry-tests-on-failure \\\n+    -test-iterations 3\n'
        cases = {
            "Scripts/runner.zsh": (shell, ["-retry-tests-on-failure", "-test-iterations"]),
            "script/runner.sh": (shell, ["-retry-tests-on-failure", "-test-iterations"]),
            ".github/workflows/nested/test.yml": (
                "run: xcodebuild test -retry-tests-on-failure", ["-retry-tests-on-failure"],
            ),
            "Attic.xcodeproj/xcshareddata/xcschemes/Attic.xcscheme": (
                '<TestAction testRepetitionMode="retryUntilPass">',
                ['testRepetitionMode="retryUntilPass"'],
            ),
            "Plans/Try.xctestplan": (
                '{"testRepetitionMode" : "retryOnFailure"}',
                ['"testRepetitionMode" : "retryOnFailure"'],
            ),
            "Plans/Legacy.xctestplan": ('{"retryOnFailure": true}', ['"retryOnFailure"']),
        }
        retry_flags = []
        for path, (source, flags) in cases.items():
            self.write_file(path, source)
            retry_flags.extend(f"{path}:{flag}" for flag in flags)
        self.write_file("Scripts/repeat.sh", "xcodebuild test -test-iterations 3")
        self.allow()
        status, output = self.run_guard()
        self.assertEqual(status, 1)
        for flag in retry_flags:
            self.assertIn(f"{flag}: retry_flags count 1, allowance 0", output)
        self.assertNotIn("repeat.sh", output)

        self.allow(retry_flags=retry_flags)
        self.assertEqual(self.run_guard()[0], 0)

    def test_one_retry_allowance_does_not_cover_duplicate_occurrences(self):
        path = "Scripts/runner.sh"
        flag = "-retry-tests-on-failure"
        self.write_file(path, f"xcodebuild test {flag}\nxcodebuild test {flag}\n")
        self.allow(retry_flags=[f"{path}:{flag}"])
        status, output = self.run_guard()
        self.assertEqual(status, 1)
        self.assertIn(f"{path}:{flag}: retry_flags count 2, allowance 1", output)

    def test_write_allowance_refuses_to_raise_and_preserves_the_baseline(self):
        self.write_file(self.test_file, self.sleep * 2)
        allowance = self.allow({self.test_file: {"sleep": 1}})
        before = allowance.read_bytes()
        status, output = self.run_guard("--write-allowance")
        self.assertEqual(status, 1)
        self.assertIn("--allow-raise", output)
        self.assertIn("one-line reason in the pull request", output)
        self.assertEqual(allowance.read_bytes(), before)
        self.assertEqual(self.run_guard("--write-allowance", "--allow-raise")[0], 0)
        self.assertEqual(self.run_guard()[0], 0)

    def test_write_allowance_bootstraps_and_records_removals(self):
        path = self.write_file(self.test_file, self.sleep)
        self.assertEqual(self.run_guard("--write-allowance")[0], 0)
        allowance = self.root / self.allowance
        self.assertEqual(json.loads(allowance.read_text())["files"], {
            self.test_file: {"sleep": 1},
        })
        path.write_text("// removed the sleep", encoding="utf-8")
        self.assertEqual(self.run_guard("--write-allowance")[0], 0)
        self.assertEqual(json.loads(allowance.read_text())["files"], {})
        self.assertEqual(self.run_guard()[0], 0)


if __name__ == "__main__":
    unittest.main()
