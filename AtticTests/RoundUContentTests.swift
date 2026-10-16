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
