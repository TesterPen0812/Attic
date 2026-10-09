import AppKit

/// Puts a document through the real text system (a TextKit 2 text view and
/// a full layout pass) and reads it back for document fidelity tests.
@MainActor
enum NoteTextKitRoundTrip {
    static func document(afterRoundTrip document: NoteDocument) -> NoteDocument {
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 800)
        if let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        let result = engine.document()
        engine.detachView()
        return result
    }
}
