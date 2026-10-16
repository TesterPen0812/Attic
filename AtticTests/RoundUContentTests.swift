import AppKit
import Network
import XCTest
@testable import Attic

@MainActor
final class RoundUContentTests: XCTestCase {
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
