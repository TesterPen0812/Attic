import AppKit
import Network
import XCTest
@testable import Attic

@MainActor
final class RoundUContentTests: XCTestCase {
    private func scaling(_ label: String, small: Int, large: Int, operation: (Int) throws -> Void) rethrows {
        func elapsed(_ count: Int) throws -> Double {
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = Date.timeIntervalSinceReferenceDate
                try operation(count)
                samples.append(Date.timeIntervalSinceReferenceDate - start)
            }
            return samples.min()!
        }
        let a = try elapsed(small), b = try elapsed(large)
        print("Round U \(label): \(small)=\(a)s, \(large)=\(b)s, ratio=\(b / a)")
        XCTAssertLessThan(b, a * 8, "four times the input must grow less than quadratically")
    }

    func testU02UnfinishedLinksScaleAndStayLiteral() {
        scaling("U-02", small: 500, large: 2000) { count in
            let source = String(repeating: "[a](", count: count)
            let cell = NoteTableText.inlineCell(source)
            XCTAssertEqual(cell.text, source)
            XCTAssertTrue(cell.marks.isEmpty)
        }
        let balanced = NoteTableText.inlineCell("[a](https://example.com/a(b))")
        XCTAssertEqual(balanced.text, "a")
        XCTAssertEqual(balanced.marks.first?.url, "https://example.com/a(b)")
    }

    func testU11AlternatingMarksScaleWithExactMarkdown() {
        scaling("U-11", small: 800, large: 3200) { count in
            var block = NoteBlock.text(String(repeating: "ab", count: count))
            block.marks = (0..<count).map { NoteMark(.bold, offset: $0 * 2, length: 1) }
            let doc = NoteDocument(blocks: [.text("T"), block])
            XCTAssertEqual(NoteMarkdownExport.markdown(doc), "# T\n\n" + String(repeating: "**a**b", count: count))
        }
    }

    func testU12TitleOnlyRTFScalesWithExactText() throws {
        try scaling("U-12", small: 300, large: 1200) { count in
            let export = TasksTextExport(items: (0..<count).map { .init(title: "Task \($0)") })
            let bytes = try XCTUnwrap(export.rtf)
            let text = try NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            XCTAssertEqual(text.string, export.titles)
            XCTAssertEqual(bytes, export.rtf, "encoding must stay byte-identical")
        }
    }

    func testU11SelectionCopyKeepsExactMarkdown() throws {
        var block = NoteBlock.text("abab")
        block.marks = [NoteMark(.bold, offset: 0, length: 1), NoteMark(.bold, offset: 2, length: 1)]
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), block]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        view.setSelectedRange(NSRange(location: 2, length: 4))
        let board = NSPasteboard(name: .init("RoundU-\(UUID())"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: board, types: [TasksTextExport.markdownType, .string]))
        XCTAssertEqual(board.string(forType: TasksTextExport.markdownType), "**a**b**a**b")
        XCTAssertEqual(board.string(forType: .string), "abab")
    }

    func testU12CopyKeepsRTFBytesAndMixedSeparators() throws {
        for items: [TasksTextExport.Item] in [[.init(title: "A"), .init(title: "B")],
                                            [.init(title: "A", due: "Today"), .init(title: "B")]] {
            let export = TasksTextExport(items: items)
            let board = NSPasteboard(name: .init("RoundU-\(UUID())"))
            defer { board.releaseGlobally() }
            export.write(to: board)
            XCTAssertEqual(board.data(forType: .rtf), export.rtf)
            let read = try NSAttributedString(data: XCTUnwrap(export.rtf), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            XCTAssertEqual(read.string, export.plain)
        }
    }

    func testU03NestedTableMarksSaveAsEditableContent() throws {
        let cell = NoteTableText.inlineCell("<u>a<u>b</u>c</u>")
        XCTAssertEqual(cell.text, "abc")
        var table = NoteTable(texts: [["abc"]])
        table.rows[0].cells[0] = cell
        let bytes = try NoteContentCodec.encode(NoteDocument(blocks: [.text("T"), .table(table)]))
        XCTAssertTrue(NoteContentCodec.decode(bytes).isEditable)
        XCTAssertEqual(cell.marks, [NoteMark(.underline, offset: 0, length: 3)])
    }

    func testU03EncoderRefusesUncanonicalOverlappingMarks() {
        for kind in NoteMark.Kind.allCases {
            var table = NoteTable(texts: [["abc"]])
            let url = kind == .link ? "https://example.com" : nil
            table.rows[0].cells[0].marks = [NoteMark(kind, offset: 0, length: 3, url: url),
                                          NoteMark(kind, offset: 1, length: 1, url: url)]
            XCTAssertThrowsError(try NoteContentCodec.encode(NoteDocument(blocks: [.text("T"), .table(table)])))
        }
    }

    func testU01OversizedRawTablesAreRejectedBeforeConstruction() {
        let wide = Array(repeating: "x", count: NoteTable.maxColumns + 1).joined(separator: "\t")
        let ragged = "a\tb\na\tb\na\tb\n" + wide
        XCTAssertNil(NoteTablePaste.table(fromText: ragged))
        let tall = String(repeating: "a\tb\n", count: NoteTable.maxRows + 1)
        XCTAssertNil(NoteTablePaste.table(fromText: tall))
        let markdown = "| " + Array(repeating: "x", count: 31).joined(separator: " | ") + " |\n|" + String(repeating: " --- |", count: 31)
        XCTAssertNil(NoteTableText.parseMarkdown(markdown))
        XCTAssertNil(NoteTablePaste.table(fromHTML: "<table><tr>" + String(repeating: "<td>x</td>", count: 31) + "</tr></table>"))
    }

    func testU13AttachmentNamesRemainLiteralOnMarkdownReimport() throws {
        for name in ["report**draft**.txt", "report]\n\n# Extra.txt"] {
            let file = NoteBlock.file(filename: name, contentTypeIdentifier: "public.data", byteCount: 1, importFailure: "missing")
            let document = NoteDocument(blocks: [.text("T"), file, .image(attachmentID: UUID())])
            let loaded = try XCTUnwrap(NoteContentCodec.decode(NoteContentCodec.encode(document)).document)
            let markdown = NoteMarkdownExport.markdown(loaded, filename: { _ in name })
            let restored = try NoteMarkdownImport.document(markdown)
            XCTAssertEqual(restored.blocks.count, 3)
            let visible = name == "report**draft**.txt" ? name : "report]\\u{a}\\u{a}# Extra.txt"
            XCTAssertEqual(restored.blocks.dropFirst().map(\.text), ["[file: \(visible)]", "[image: \(visible)]"])
            XCTAssertTrue(restored.blocks.dropFirst().allSatisfy { $0.marks.isEmpty && $0.style == nil })
        }
    }

    func testU09ImportedLinksKeepTheirDestinationButOnlyWebLinksAreInteractive() throws {
        for address in ["file:///System/Applications/Calculator.app", "mailto:review@example.com", "attic://note/123", "javascript:alert(1)", "https://example.com", "http://example.com"] {
            var block = NoteBlock.text("Project reference")
            block.marks = [NoteMark(.link, offset: 0, length: block.text.utf16.count, url: address)]
            let doc = NoteDocument(blocks: [.text("T"), block])
            let attributed = NoteTextCodec.attributedString(from: doc, style: NoteTextStyle())
            let interactive = attributed.attribute(.link, at: 2, effectiveRange: nil)
            XCTAssertEqual(interactive != nil, address.hasPrefix("http"), address)
            XCTAssertEqual(attributed.attribute(.noteMark(.link), at: 2, effectiveRange: nil) as? String, address)
            XCTAssertEqual(try NoteContentCodec.encode(NoteTextCodec.document(from: attributed)), try NoteContentCodec.encode(doc))
        }
    }

    func testU09LinkPolicyDispatchesOnlyWebDestinations() {
        var opened: [URL] = []
        for address in ["file:///tmp/private", "mailto:a@example.com", "attic://note/123", "https://", "relative/path"] {
            XCTAssertFalse(NoteLinkPolicy.open(address) { opened.append($0); return true })
        }
        for address in ["http://example.com", "https://example.com/path", "HTTPS://example.com"] {
            XCTAssertTrue(NoteLinkPolicy.open(address) { opened.append($0); return true })
        }
        XCTAssertEqual(opened.count, 3)
        let engine = NoteEditorEngine(noteID: UUID(), document: .blank)
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        XCTAssertTrue(engine.textView(view, clickedOnLink: "file:///tmp/private", at: 0), "refusal must suppress AppKit's fallback")
    }

    func testU18PrivateFragmentSaveAndSelectionCopyStayBounded() throws {
        let bytes = Data(#"{"format":1,"blocks":[{"kind":"text","text":"x","style":"heading","level":9223372036854775807}]}"#.utf8)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("")]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        XCTAssertTrue(engine.paste(fragmentData: bytes, at: NSRange(location: 2, length: 0)))
        let document = engine.document()
        let prepared = try PreparedNoteDocument(document)
        XCTAssertEqual(prepared.body, "###### x")
        XCTAssertEqual(prepared.plainText, "T\n###### x")
        let board = NSPasteboard(name: .init("RoundU-\(UUID())"))
        defer { board.releaseGlobally() }
        view.setSelectedRange(NSRange(location: 2, length: 1))
        XCTAssertTrue(view.writeSelection(to: board, types: [.string, TasksTextExport.markdownType]))
        XCTAssertEqual(board.string(forType: .string), "###### x")
        XCTAssertEqual(board.string(forType: TasksTextExport.markdownType), "###### x")
    }

    func testU03NestedLinksHaveOneDestinationPerSpanAndReopenInFreshContext() throws {
        let cell = NoteTableText.inlineCell("[a[b](https://inner.example)c](https://outer.example)")
        XCTAssertEqual(cell.text, "abc")
        XCTAssertEqual(cell.marks.map(\.url), ["https://outer.example", "https://inner.example", "https://outer.example"])
        var table = NoteTable(texts: [["abc"]]); table.rows[0].cells[0] = cell
        let document = NoteDocument(blocks: [.text("T"), .table(table)])
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let created = try store.createDocumentNote(id: UUID(), document: document).get()
        let fresh = trackAttachmentReconciliation(of: NoteStore(container: store.container, attachmentFileStore: makeTestAttachmentFileStore()))
        let loaded = try XCTUnwrap(fresh.loadDocument(noteID: created.noteID))
        XCTAssertTrue(loaded.content.isEditable)
        XCTAssertEqual(loaded.content.document?.blocks, document.blocks)
    }

    func testU01ReportedRaggedFixtureFallsBackToIntactPlainText() {
        let source = String(repeating: "a\tb\n", count: 20_000)
            + Array(repeating: "x", count: 30_000).joined(separator: "\t")
        XCTAssertNil(NoteTablePaste.table(fromText: source))
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("")]))
        let (_, _) = engine.makeView()
        defer { engine.detachView() }
        XCTAssertTrue(engine.pastePlainText(source, at: NSRange(location: 2, length: 0)))
        XCTAssertEqual(NoteTextExport.plainBody(engine.document()), source)
        XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
    }

    func testU01OversizedHTMLClipboardKeepsCellSeparatorsAndFallbackNotice() {
        let cells = (0..<31).map { "x\($0)" }
        let html = "<table><tr>" + cells.map { "<td>\($0)</td>" }.joined() + "</tr></table>"
        for hasPlainText in [false, true] {
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("")]))
            let (_, view) = engine.makeView()
            defer { engine.detachView() }
            view.setSelectedRange(NSRange(location: 2, length: 0))
            var notices: [NoteNotice] = []
            engine.onNotice = { notices.append($0) }
            let board = NSPasteboard(name: .init("RoundU-\(UUID())"))
            defer { board.releaseGlobally() }
            board.setString(html, forType: .html)
            if hasPlainText { board.setString("original\ttable", forType: .string) }
            XCTAssertTrue(view.readSelection(from: board, type: .html))
            XCTAssertEqual(NoteTextExport.plainBody(engine.document()), hasPlainText ? "original\ttable" : cells.joined(separator: "\t"))
            XCTAssertFalse(engine.document().blocks.contains { $0.kind == .table })
            XCTAssertEqual(notices.last?.kind, .textPasted)
        }
    }

    func testU04HTMLPasteMakesNoResourceRequests() async throws {
        let server = try RoundUHTTPServer()
        try await server.start()
        defer { server.stop() }
        // Prove the counter sees a real request before testing the importer.
        _ = try await URLSession.shared.data(from: server.url.appendingPathComponent("control"))
        XCTAssertEqual(server.requests, 1)
        server.reset()
        let url = server.url.absoluteString
        let html = """
        <html><head><link rel="stylesheet" href="\(url)/style.css">
        <style>@import url('\(url)/import.css'); p {background:url('\(url)/background.png')}</style>
        </head><body><p><b>Readable</b> <i>text</i> <a href="https://example.com">link</a></p>
        <img width="40" height="40" src="\(url)/image.png"><iframe src="\(url)/frame"></iframe>
        <object data="\(url)/object"></object></body></html>
        """
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("")]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        XCTAssertTrue(engine.pasteRichText(Data(html.utf8), type: .html, at: NSRange(location: 2, length: 0)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.requests, 0, "HTML paste must never load subsidiary resources")
        let document = engine.document()
        XCTAssertTrue(view.string.contains("Readable text link"))
        XCTAssertTrue(document.blocks.flatMap(\.marks).contains { $0.kind == .bold })
        XCTAssertTrue(document.blocks.flatMap(\.marks).contains { $0.kind == .italic })
        XCTAssertTrue(document.blocks.flatMap(\.marks).contains { URL(string: $0.url ?? "")?.host == "example.com" })
    }
}

private final class RoundUHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.withLock { count } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func reset() { lock.withLock { count = 0 } }
    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                self?.lock.withLock { self?.count += 1 }
                let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel() }
}
