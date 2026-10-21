"""Guard normal-operation diagnostics against private error details."""
from pathlib import Path
import re
import plistlib
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ContentPrivacyTests(unittest.TestCase):
    def test_u14_normal_operation_nslog_drops_private_error_details(self):
        for relative in ('Attic/Services/NoteStore.swift',
                         'Attic/Notes/Store/NoteStore+Documents.swift',
                         'Attic/App/AppCoordinator.swift'):
            source = (ROOT / relative).read_text()
            for call in re.findall(r'NSLog\([\s\S]*?\)', source):
                # Preview and dormant CloudKit diagnostics have separate scope.
                if any(label in call for label in ('CloudKit', 'demo data')):
                    continue
                with self.subTest(file=relative, call=call):
                    self.assertNotRegex(call, r'failure\.message|error\.localizedDescription')

    def test_u15_all_macos_print_profiles_grant_printing(self):
        for path in sorted((ROOT / 'Attic').glob('*.entitlements')):
            with self.subTest(profile=path.name):
                with path.open('rb') as stream:
                    self.assertIs(plistlib.load(stream).get('com.apple.security.print'), True)
        generator = (ROOT / 'Scripts/generate_project.rb').read_text()
        self.assertIn("settings['CODE_SIGN_ENTITLEMENTS'] = 'Attic/AtticNotesLocal.entitlements'", generator)


if __name__ == '__main__':
    unittest.main()
