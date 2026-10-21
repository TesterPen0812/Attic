from pathlib import Path
import re
import tempfile
import unittest

from prepare_integration_cost_reference import measurement_fixture, prepare, ROOT, SELECTED, METHOD


class IntegrationReferenceTests(unittest.TestCase):
    def test_selected_measurement_and_helpers_are_byte_identical(self):
        source = ('class Fixture {\n'
                  '    func testOld() { XCTAssertTrue(newAPI()) }\n'
                  '    func testCost() throws {\n        measure { app.save() }\n    }\n'
                  '    private func helper() { unchanged() }\n}\n')
        result = measurement_fixture(source, {'testCost'})
        self.assertEqual(result, source.replace('    func testOld() { XCTAssertTrue(newAPI()) }\n', ''))

    def test_missing_or_ambiguous_measurements_fail_closed(self):
        with self.assertRaises(ValueError):
            measurement_fixture('class Fixture {}', {'testCost'})
        with self.assertRaises(ValueError):
            measurement_fixture('    func testOld() {\n    func testCost() { }\n    }\n', {'testCost'})

    def test_real_overlay_contains_all_and_only_selected_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'AtticTests').mkdir()
            fixtures = {item.split('/')[0] for item in SELECTED}
            for fixture in fixtures:
                (root / 'AtticTests' / f'{fixture}.swift').write_text('historical fixture')
            prepare(root)
            for fixture in fixtures:
                original = (ROOT / 'AtticTests' / f'{fixture}.swift').read_text()
                adapted = (root / 'AtticTests' / f'{fixture}.swift').read_text()
                selected = {item.split('/')[1] for item in SELECTED if item.startswith(fixture + '/')}
                self.assertEqual({m.group(1) for m in METHOD.finditer(adapted) if m.group(1).startswith('test')}, selected)
                self.assertNotIn('private func pendingCheckpointQuit', adapted)
                for name in selected:
                    # Whole selected method remains a verbatim substring.
                    start = original.index('    func ' + name + '(')
                    tail = original[start:]
                    end = re.search(r'^    }\s*$', tail, re.MULTILINE).end()
                    self.assertIn(tail[:end], adapted)


if __name__ == '__main__':
    unittest.main()
