#!/usr/bin/env python3
"""Apply the identical diagnostic overlay to an archived revision, never a live checkout."""
import argparse
from pathlib import Path


def instrument(root):
    build = Path(__file__).resolve().parent.parent / ".build"
    if not root.is_relative_to(build) or root == build or (root / ".git").exists():
        raise ValueError("Count overlays are restricted to owned .build source archives")
    source = Path(__file__).with_name("reveal_counts.swift").read_text()
    probe = root / "Attic/Performance/PerformanceProbe.swift"
    if "enum RevealCounts" in probe.read_text():
        raise ValueError("Archive already instrumented")
    probe.write_text(probe.read_text() + "\n" + source)
    path = root / "Attic/Window/AtticPanelController.swift"
    text = path.read_text()
    text = text.replace("        configurePanel()", "        configurePanel()\n        RevealCounts.install()", 1)
    text = text.replace("        cancelPageRelease()\n        // Build the pages", "        RevealCounts.begin(panel)\n        defer { RevealCounts.end(panel) }\n        cancelPageRelease()\n        // Build the pages", 1)
    # Only bracket the cold branch; leave key/focus/ordering untouched.
    anchor = "        performanceVisibilityChanges += 1\n\n        if makeKey {"
    assert anchor in text
    text = text.replace(anchor, "        performanceVisibilityChanges += 1\n\n        RevealCounts.beginOrder()\n        if makeKey {", 1)
    anchor = "        // The pointer monitor started before the panel was on screen"
    assert anchor in text
    text = text.replace(anchor, "        RevealCounts.endOrder()\n\n" + anchor, 1)
    assert "RevealCounts.begin(panel)" in text
    path.write_text(text)
    sites = {
        "Attic/Tasks/TasksPage.swift": ("    var body: some View {", "TasksPage.body"),
        "Attic/Views/Panel/AtticPanelView.swift": ("    var body: some View {", "AtticPanelView.body"),
        "Attic/DesignSystem/Components/AtticTokenField.swift": ("    func updateNSView(_ view: AtticTokenFieldView, context: Context) {", "AtticTokenField.updateNSView"),
        "Attic/DesignSystem/Tokens/AtticDesignContext.swift": ("    func updateNSView(_ view: AtticWindowAppearanceView, context: Context) {", "AtticWindowAppearanceSetter.updateNSView"),
    }
    for relative, (anchor, name) in sites.items():
        path = root / relative
        text = path.read_text()
        assert anchor in text
        text = text.replace(anchor, anchor + '\n        let _ = RevealCounts.record("' + name + '")', 1)
        path.write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    instrument(parser.parse_args().archive.resolve())
