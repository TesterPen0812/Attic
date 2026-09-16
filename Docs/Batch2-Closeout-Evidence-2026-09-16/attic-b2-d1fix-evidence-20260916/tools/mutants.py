#!/usr/bin/env python3
"""Mutant discrimination runner (scratch only; never touches the live checkout).

For each mutant: restore the private tree from mut-base, apply one mutation,
build incrementally into dd-mut, run the hosted availability tests, and record
which tests fail. The private tree is restored to mut-base at the end.
"""
import pathlib
import re
import shutil
import subprocess
import sys

S = pathlib.Path("/tmp/attic-b2-opus-scratch")
MUT = S / "mut"
BASE = S / "mut-base"
DD = S / "dd-mut"
FILES = [
    "Attic/App/CanvasEditCommandRoute.swift",
    "Attic/Canvas/CanvasSemanticInteraction.swift",
    "Attic/Canvas/CanvasSurfaceMac.swift",
    "Attic/Canvas/CanvasSession.swift",
    "AtticTests/CanvasDomainTests.swift",
    "Attic/Views/Panel/CanvasPanelContent.swift",
]
TESTS = (S / "xctest/new-tests.txt").read_text().split() + [
    "CanvasAccessibilityTests/testFocusedEmptyTextEditorDisablesToolbarAndMenuUndoRedo",
    "CanvasAccessibilityTests/testTypingInFocusedTextEditorEnablesToolbarUndoWithEmptyCanvasHistory",
    "CanvasAccessibilityTests/testAddMenuUndoRoutesToFocusedTextEditor",
    "CanvasAccessibilityTests/testAddMenuRedoRoutesToFocusedTextEditor",
    "CanvasAccessibilityTests/testToolbarUndoRedoFollowFocusedTextEditor",
]

INTERACTION = "Attic/Canvas/CanvasSemanticInteraction.swift"
ROUTE = "Attic/App/CanvasEditCommandRoute.swift"
SESSION = "Attic/Canvas/CanvasSession.swift"
PANEL = "Attic/Views/Panel/CanvasPanelContent.swift"

RESPONDERS = re.compile(
    r"    // The app's plain Edit ▸ Undo/Redo items otherwise resolve to the window,\n"
    r".*?            return super\.validateUserInterfaceItem\(item\)\n        \}\n    \}\n\n",
    re.S,
)

MUTANTS = {
    "M1-shared-window-undo-manager": [
        (INTERACTION, "    override var undoManager: UndoManager? { typingUndoManager }\n", ""),
    ],
    "M2-no-focus-refresh": [
        (INTERACTION, "        Self.lastFocused = self\n        onFocus?()\n", "        Self.lastFocused = self\n"),
    ],
    "M3-no-reconcile-refresh": [
        (INTERACTION, "            editor.undoManager?.removeAllActions()\n            // Neither step reports a text change, and chrome already read the\n"
                      "            // editor's history earlier in the update that brought this change.\n"
                      "            onEditingAvailabilityChange()\n",
         "            editor.undoManager?.removeAllActions()\n"),
    ],
    "M4-no-plain-edit-responders": [
        (INTERACTION, RESPONDERS, ""),
    ],
    "M6-no-undo-redo-history-report": [
        (INTERACTION, "    @objc private func typingHistoryDidChangeText(_ notification: Notification) { onDraft?(string) }\n",
         "    @objc private func typingHistoryDidChangeText(_ notification: Notification) {}\n"),
    ],
    "M5-key-window-only-resolver": [
        (ROUTE, "        return CanvasSemanticTextEditor.focusedInVisibleWindow ?? keyResponder\n",
         "        return keyResponder\n"),
    ],
    "MA-prior-composite-predicate": [
        (PANEL, "return CanvasEditCommandRoute.canUndo(session: session, section: .canvas)",
         "return session.canUndo || CanvasEditCommandRoute.canUndo(session: session, section: .canvas)"),
        (PANEL, "return CanvasEditCommandRoute.canRedo(session: session, section: .canvas)",
         "return session.canRedo || CanvasEditCommandRoute.canRedo(session: session, section: .canvas)"),
    ],
    "MB-prior-no-draft-refresh": [
        (SESSION, "        // no draft, yet it still changes what that editor can undo and redo.\n"
                  "        invalidateEditingAvailability()\n",
         "        // no draft, yet it still changes what that editor can undo and redo.\n"),
    ],
}


def restore():
    for f in FILES:
        shutil.copyfile(BASE / f, MUT / f)


def apply(mutations):
    for rel, old, new in mutations:
        path = MUT / rel
        text = path.read_text()
        if isinstance(old, re.Pattern):
            updated, count = old.subn(new, text, count=1)
        else:
            count = text.count(old)
            updated = text.replace(old, new, 1)
        if count != 1:
            raise SystemExit(f"mutation anchor not unique/found in {rel}: count={count}")
        path.write_text(updated)


def run(name, mutations):
    restore()
    apply(mutations)
    build_log = S / f"logs/build-{name}.log"
    with build_log.open("w") as log:
        build = subprocess.run(
            ["xcodebuild", "build-for-testing", "-project", "Attic.xcodeproj", "-scheme", "Attic",
             "-configuration", "Local", "-derivedDataPath", str(DD), "-only-testing:AtticTests",
             "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=NO"],
            cwd=MUT, stdout=log, stderr=subprocess.STDOUT,
        )
    if build.returncode != 0:
        return f"{name}: BUILD FAILED (exit {build.returncode}), see {build_log}"
    env = dict(**__import__("os").environ, ATTIC_TEST_PRODUCTS=str(DD / "Build/Products/Local"))
    subprocess.run([str(S / "xctest/run.zsh"), f"mutant-{name}", "600", *TESTS], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log = (S / f"xctest/mutant-{name}.log").read_text()
    results = re.findall(r"Test Case '-\[AtticTests\.CanvasAccessibilityTests (\w+)\]' (passed|failed)", log)
    executed = re.findall(r"Executed (\d+) tests?, with (\d+) failures?", log)
    failed = sorted({t for t, r in results if r == "failed"})
    summary = [f"{name}: executed/failures={executed[-1] if executed else '?'}; failing tests={len(failed)}"]
    for test in failed:
        lines = re.findall(rf"CanvasDomainTests\.swift:(\d+): error: -\[AtticTests\.CanvasAccessibilityTests {test}\]", log)
        summary.append(f"    FAIL {test} at lines {','.join(lines[:8])}")
    return "\n".join(summary)


def main():
    names = sys.argv[1:] or list(MUTANTS)
    out = S / "mutants-summary.txt"
    try:
        for name in names:
            line = run(name, MUTANTS[name])
            print(line, flush=True)
            with out.open("a") as handle:
                handle.write(line + "\n")
    finally:
        restore()
        for f in FILES:
            if (MUT / f).read_bytes() != (BASE / f).read_bytes():
                print(f"RESTORE MISMATCH {f}")
        print("restored mut tree to mut-base")


if __name__ == "__main__":
    main()
