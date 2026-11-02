# Mac → iPhone → Mac: synthetic note exchange

The Mac producer constructs a native `NoteDocument` and a synthetic `NoteAttachment` and emits their actual bytes. The iPhone test reads two bundled resources (no fallback generator), saves to an in-memory local store, reopens in another context and exports its no-op result and stored file. It separately checks an edit against the entire expected byte stream. A third test opens the returned note with the Mac codec. An isolated green run against the checked-in equivalents is useful, but is not a completed exchange.

| Individual test resource under `AtticMobileTests/Fixtures/Synthetic/` | Bytes | Pre-staged SHA-256 |
| --- | ---: | --- |
| `exchange-note.json` | 1201 | `24f53a2533c181f9d6b7959b175baee16a1af32f57c35c4574e019cc22a47276` |
| `exchange-file.txt` | 35 | `cf6f50a5a60235e304a608aa91f882a282972c42c73b50105477aae17d0848f1` |

The document contains deterministic IDs, UTF-16 marks after an emoji, an inline date, a table with nested extras, a file, a checklist, a large unsigned integer and an image placement with no corresponding asset. A missing file or image is not a deletion. Only `exchange-file.txt` has an asset payload.

## Air handoff (lead)

1. Integrate the branch. The **generator owner** adds the two individual resources to Copy Bundle Resources for **both** `AtticTests` and `AtticMobileTests` (flat bundle basenames), then regenerates/verifies the project. `PhoneNoteDocument.swift` belongs to `AtticMobile`; the two test sources belong to their corresponding test targets. Do not add the resources to either shipping app. The Air helper accepts these individual `.json` and `.txt` files from `Fixtures/Synthetic`.
2. Run `-only-testing:AtticTests/PhoneExchangeFixtureTests/testProduceMacExchange` through the Mac Air helper, with a unique `-resultBundlePath`. Keep the successful `.xcresult`. Retrieve that synthetic result bundle or its exported attachments for staging. From the integrated source root, use the command below with the Mac result to compare hashes and stage the **actual exported bytes**. Stop on any mismatch.
3. Run `-only-testing:AtticMobileTests/PhoneNoteDocumentTests` via `Scripts/air-ios.sh` on that same integrated tree. Retain its `tests.xcresult`. Repeat the command below with the phone result and a separate export directory. It compares both phone outputs to the staged Mac bytes before copying the **actual phone return** into the resource slots.
4. Run `-only-testing:AtticTests/PhoneExchangeFixtureTests/testMacReopensExchangeResources` through the Mac Air helper after the return is staged. The test compares both returned byte streams with a fresh Mac encoding/file and opens the returned document. Record the commit, all three passing test results and both SHA-256 comparisons. Absent evidence, the exchange is pending.

Run this once per leg in a shell with the integrated source tree and the corresponding result bundle. Set `RESULT` to the `.xcresult`; set `EXPORT` to a **new** evidence directory for that leg (e.g. a job-specific directory under `.build/`). `xcresulttool` may export UUID filenames, so select the pair by its manifest rather than renaming the first two files.

```sh
set -eu
: "${RESULT:?set RESULT to the successful result bundle}"
: "${EXPORT:?set EXPORT to a fresh attachment export directory}"
test ! -e "$EXPORT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$EXPORT"
python3 - "$EXPORT" <<'PY'
from pathlib import Path
import hashlib, json, re, sys

export = Path(sys.argv[1]).resolve()
fixtures = Path('AtticMobileTests/Fixtures/Synthetic')
manifest = json.loads((export / 'manifest.json').read_bytes())
observed = {}
for name, pinned in {
    'exchange-note.json': '24f53a2533c181f9d6b7959b175baee16a1af32f57c35c4574e019cc22a47276',
    'exchange-file.txt': 'cf6f50a5a60235e304a608aa91f882a282972c42c73b50105477aae17d0848f1',
}.items():
    # Xcode may insert the attachment index and UUID *before* the filename extension.
    file = Path(name)
    suffix = r'(?:_[0-9]+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})?'
    pattern = re.escape(file.stem) + suffix + re.escape(file.suffix)
    matches = [a['exportedFileName'] for test in manifest for a in test['attachments']
               if not a.get('isAssociatedWithFailure') and re.fullmatch(pattern, a['suggestedHumanReadableName'])]
    if len(matches) != 1 or Path(matches[0]).name != matches[0]:
        raise SystemExit(f'{name}: expected one named attachment; inspect manifest.json')
    payload = (export / matches[0]).read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    staged = (fixtures / name).read_bytes()
    print(f'{name}: exported={digest} staged={hashlib.sha256(staged).hexdigest()}')
    if digest != pinned or payload != staged:
        raise SystemExit(f'{name}: byte mismatch; retain evidence and stop before staging')
    observed[name] = payload
for name, payload in observed.items():
    (fixtures / name).write_bytes(payload)
PY
```

## Editor boundary

Open from `PhoneNoteDocument.Snapshot(row)` and retain that snapshot while editing. In the save transaction, compare every live physical replica against the baseline and call `saving(_:against:)` with freshly read state. `.unchanged` means **do not assign** content, fingerprint, or revision (including legacy nil values). `.changed` contains only prepared bytes; the library owns atomically applying them, updating projections and advancing revisions. A deleted/missing/divergent replica must not receive a write. No persistence, attachment maintenance or history updates are performed by this layer.

Block indices refer to the opening snapshot. Text changes are limited to text/checklist blocks without marks or inline objects. Checkbox changes affect only `checked`. Tables, file/image placements and rich text stay visible through the shared preview. Opaque content, task-owned notes, newer formats, unrecognised requirements and ambiguous wire paths refuse edits. Invalid or conflicting requests do not return replacement bytes.
