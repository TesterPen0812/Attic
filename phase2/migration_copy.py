"""Private copy/integrity helpers. Never emit row values or source filenames."""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import sqlite3
import sys


def inventory(root):
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError('Directory missing or symlink refused')
    result = {}
    for base, dirs, files in os.walk(root):
        for entry in dirs + files:
            if (Path(base) / entry).is_symlink():
                raise RuntimeError('Symlink entry refused')
        for entry in files:
            path = Path(base) / entry
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            result[str(path.relative_to(root))] = digest.hexdigest()
    return result


def rows_snapshot(store, original=None):
    # Only our writable copy is opened by SQLite (including its WAL).
    with sqlite3.connect(f'{store.as_uri()}?mode=ro', uri=True) as db:
        if original is None:
            tables = [r[0] for r in db.execute(
                "select name from sqlite_master where type='table' and name in "
                "('ZNOTEITEM','ZNOTEATTACHMENT','ZTASKITEM','ZCANVASBOARDITEM',"
                "'ZCANVASSTROKEITEM','ZCANVASIMAGEITEM','ZCANVASSEMANTICOBJECTITEM')")]
            original = {t: {'columns': [r[1] for r in db.execute(f'pragma table_info("{t}")')
                                        if r[1] not in ('Z_PK', 'Z_ENT', 'Z_OPT')]} for t in tables}
        result = {}
        for table, spec in original.items():
            columns = spec['columns']
            projection = ','.join(f'"{c}"' for c in columns)
            digests = []
            for row in db.execute(f'select {projection} from "{table}"'):
                # Typed values, sorted as a multiset: duplicates are preserved.
                values = [(type(v).__name__, v.hex() if isinstance(v, bytes) else v) for v in row]
                digests.append(hashlib.sha256(json.dumps(values, ensure_ascii=True).encode()).hexdigest())
            result[table] = {'columns': columns, 'digests': sorted(digests)}
        return result


def prepare(source, name, out, mode, repo):
    # Never even inventory a protected container, regardless of supplied mode.
    containers = Path.home() / 'Library' / 'Containers'
    def refuse_protected(path):
        for bundle in ('com.taha.Attic', 'com.emanueledipietro.Attic'):
            protected = containers / bundle
            if path == protected or protected in path.parents or path in protected.parents:
                raise RuntimeError('Protected container access refused; supply a staged copy')
    # Lexical gate precedes stat/resolve, including for a path with '..'.
    refuse_protected(Path(os.path.abspath(source)))
    resolved = source.resolve()
    refuse_protected(resolved)
    if source.is_symlink():
        raise RuntimeError('Symlink source refused')
    if mode == 'fixture':
        allowed = [repo / '.build', Path('/tmp').resolve(), Path(os.environ.get('TMPDIR', '/tmp')).resolve()]
        if not any(root == resolved or root in resolved.parents for root in allowed):
            raise RuntimeError('Fixture resolves outside allowed roots')
    if not source.is_dir() or not (source / name).is_file():
        raise RuntimeError('Explicit store directory/file missing')
    before = inventory(source)
    shutil.copytree(source, out / 'copy')
    if inventory(source) != before:
        raise RuntimeError('Source changed during copy')
    if inventory(out / 'copy') != before:
        raise RuntimeError('Copy does not match source')
    # Stored privately only until final verification; never printed or committed.
    (out / 'before.json').write_text(json.dumps(before, sort_keys=True))
    for base, dirs, files in os.walk(out / 'copy'):
        Path(base).chmod(0o700)
        for entry in files:
            (Path(base) / entry).chmod(0o600)
    snapshot = rows_snapshot(out / 'copy' / name)
    (out / 'rows-before.json').write_text(json.dumps(snapshot, sort_keys=True))


def finalize(source, name, out, exit_code):
    before = json.loads((out / 'before.json').read_text())
    original = json.loads((out / 'rows-before.json').read_text())
    unchanged = inventory(source) == before
    preserved = rows_snapshot(out / 'copy' / name, original) == original
    verification = {'source_unchanged': unchanged, 'legacy_rows_unchanged': preserved,
                    'test_exit': exit_code}
    report_path = out / 'migration-report.json'
    report = json.loads(report_path.read_text()) if report_path.exists() else {'status': 'blocked', 'reason': 'runner-incomplete'}
    rows = report.get('rows', [])
    state_count = lambda state: sum(r['state'] == state for r in rows)
    refused = [r for r in rows if r['state'] == 'refused-legacy-editable']
    report['counts'] = {
        'notes_total': len(rows), 'note_physical_rows': report.get('noteRows'),
        'migrated_cleanly': state_count('verified-migration-candidate'),
        'refused': len(refused),
        'reason_classes': {reason: sum(r['reason'] == reason for r in refused)
                           for reason in sorted({r['reason'] for r in refused})},
        'legacy': state_count('verified-migration-candidate') + len(refused),
        'already_new': state_count('supported-editable') + state_count('unsupported-read-only'),
        'unsupported_new': state_count('unsupported-read-only'),
        'skipped_deleted': state_count('skipped-deleted-family'),
        'attachment_rows': report.get('attachmentRows'),
        'attachments_found': report.get('attachmentsFound'),
        'attachments_missing': report.get('attachmentsMissing'),
        'tasks_opened': report.get('taskRows'), 'canvases_opened': report.get('canvasBoards'),
        'canvas_strokes': report.get('canvasStrokes'), 'canvas_images': report.get('canvasImages'),
        'canvas_objects': report.get('canvasObjects'),
    }
    # On failure, unknown counts stay null rather than becoming an apparent pass.
    if report.get('status') != 'opened':
        report['counts'] = None
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True))
    cleanup(out)
    verification['working_copy_deleted'] = not (out / 'copy').exists()
    (out / 'integrity-report.json').write_text(json.dumps(verification, indent=2))
    print(json.dumps(verification))
    if not unchanged or not preserved or not verification['working_copy_deleted']:
        raise RuntimeError('Integrity verification failed')
    if report.get('status') != 'opened':
        raise RuntimeError('Application schema open/audit did not complete')


def cleanup(out):
    if (out / 'copy').exists():
        shutil.rmtree(out / 'copy')
    for name in ('before.json', 'rows-before.json'):
        (out / name).unlink(missing_ok=True)


def filter_log(stream, output):
    # Native persistence diagnostics can include row values on failure. Never
    # retain them, even transiently: allow only known runner states/counts.
    allowed = re.compile(
        r"(?:\*\* TEST (?:SUCCEEDED|FAILED) \*\*|"
        r"Test Case '-\[AtticTests\.NotesMigrationAcceptanceTests "
        r"testOwnerApprovedCopiedStoreDryRun\]' (?:started\.|(?:passed|failed) \([0-9.]+ seconds\)\.)|"
        r"\s*Executed \d+ tests?, with (?:\d+ tests? skipped and )?\d+ failures?"
        r" \(\d+ unexpected\) in [0-9.]+ \([0-9.]+\) seconds)"
    )
    for line in stream:
        if allowed.fullmatch(line.rstrip('\n')):
            output.write(line)
            output.flush()


if __name__ == '__main__':
    action = sys.argv[1]
    try:
        if action == 'prepare':
            prepare(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]), sys.argv[5], Path(sys.argv[6]))
        elif action == 'finalize':
            finalize(Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4]), int(sys.argv[5]))
        elif action == 'cleanup':
            cleanup(Path(sys.argv[2]))
        elif action == 'filter-log':
            filter_log(sys.stdin, sys.stdout)
        else:
            raise RuntimeError('Unknown action')
    except Exception:
        # Exceptions from sqlite/filesystem can contain paths or values.
        print('Migration copy preparation/integrity failed', file=sys.stderr)
        sys.exit(1)
