import AppKit
import XCTest
@testable import Attic

@MainActor
final class RoundFHPasteTests: XCTestCase {
    private let kept = "Keep bold italic link"

    private func exercise(_ resource: (String) throws -> Data, type: NSPasteboard.PasteboardType = .html,
                          bypassSanitizer: Bool = false, images: Int = 0,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        let server = try RoundUHTTPServer()
        try await server.start()
        defer { server.stop() }
        _ = try await URLSession.shared.data(from: server.url.appendingPathComponent("control"))
        XCTAssertEqual(server.requests, 1, file: file, line: line)
        server.reset()
        let bytes = try resource(server.url.absoluteString)
        if bypassSanitizer {
            // System-reader control, deliberately outside the product path.
            // Diagnose the OS dependency against loopback only; never use
            // this initializer for clipboard HTML in the application.
            let raw = try NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
            XCTAssertTrue(raw.string.contains(kept))
            try await Task.sleep(for: .milliseconds(250))
            print("FH_SYSTEM_HTML_BASELINE os=\(ProcessInfo.processInfo.operatingSystemVersionString) requests=\(server.requests)")
            server.reset()
        }
        URLProtocol.registerClass(FHPasteProtocol.self)
        defer { URLProtocol.unregisterClass(FHPasteProtocol.self) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FHPasteProtocol.self]
        let session = URLSession(configuration: config)
        _ = try await session.data(from: server.url.appendingPathComponent("protocol-control"))
        session.invalidateAndCancel()
        XCTAssertEqual(FHPasteProtocol.counter.value, 1, file: file, line: line)
        FHPasteProtocol.counter.reset()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("")]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        if bypassSanitizer {
            let read = try XCTUnwrap(NotePasteReader.importHTML(String(decoding: bytes, as: UTF8.self)))
            XCTAssertTrue(read.string.contains(kept), file: file, line: line)
            XCTAssertNotNil(read.attribute(.font, at: (read.string as NSString).range(of: "bold").location, effectiveRange: nil))
        } else {
            let board = NSPasteboard(name: .init("RoundFH-\(UUID())"))
            defer { board.releaseGlobally() }
            board.setData(bytes, forType: type)
            view.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertTrue(view.readSelection(from: board, type: type), file: file, line: line)
            let document = engine.document()
            XCTAssertTrue(NoteTextExport.plainBody(document).contains(kept), file: file, line: line)
            let marks = document.blocks.flatMap(\.marks)
            XCTAssertTrue(marks.contains { $0.kind == .bold }, file: file, line: line)
            XCTAssertTrue(marks.contains { $0.kind == .italic }, file: file, line: line)
            XCTAssertTrue(marks.contains { $0.kind == .link && $0.url == server.url.absoluteString + "/link" }, file: file, line: line)
            XCTAssertEqual(document.blocks.filter { $0.kind == .image }.count, images, file: file, line: line)
            XCTAssertFalse(view.string.contains("ATTICPASTEIMAGE"), file: file, line: line)
            XCTAssertTrue(document.blocks.contains { $0.text == "Second paragraph" }, file: file, line: line)
            if type == .html || type == NotePasteReader.webArchiveType || type == NotePasteReader.publicWebArchiveType {
                XCTAssertTrue(document.blocks.contains { $0.style == "bullet" && $0.text.contains("List item") }, file: file, line: line)
            }
            if images > 0 {
                XCTAssertEqual(engine.stagedAttachments(for: document).count, images, file: file, line: line)
                let encoded = try NoteContentCodec.encode(document)
                XCTAssertTrue(NoteContentCodec.decode(encoded).isEditable, file: file, line: line)
                engine.undoCommand()
                XCTAssertFalse(engine.document().blocks.contains { $0.kind == .image }, file: file, line: line)
                engine.redoCommand()
                XCTAssertEqual(engine.document().blocks.filter { $0.kind == .image }.count, images, file: file, line: line)
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(server.requests, 0, "Paste must not reach a real server", file: file, line: line)
        XCTAssertEqual(FHPasteProtocol.counter.value, 0, "Paste must not attempt a URL load", file: file, line: line)
    }

    private func html(_ base: String, _ resources: String) -> Data {
        Data("<html><head>\(resources)</head><body><p>Keep <b>bold</b> <i>italic</i> <a href='\(base)/link'>link</a></p><p>Second paragraph</p><ul><li>List item</li></ul></body></html>".utf8)
    }

    func testFHImagesNeverLoad() async throws {
        try await exercise { self.html($0, "<img src='\($0)/pixel.png'><img src='//127.0.0.1:\(URL(string: $0)!.port!)/relative.png'>") }
    }
    func testFHStylesheetsNeverLoad() async throws {
        try await exercise { self.html($0, "<link rel='stylesheet' href='\($0)/style.css'><link rel='preload' as='image' href='\($0)/preload.png'>") }
    }
    func testFHImportsNeverLoad() async throws {
        try await exercise { self.html($0, "<style>@import url('\($0)/import.css'); @import '\($0)/quoted.css';</style>") }
    }
    func testFHFontsNeverLoad() async throws {
        try await exercise { self.html($0, "<style>@font-face {font-family: Tracker;src:url('\($0)/font.woff2')} p {font-family:Tracker}</style>") }
    }
    func testFHSrcsetNeverLoads() async throws {
        try await exercise { self.html($0, "<img srcset='\($0)/small.png 1x, \($0)/large.png 2x'>") }
    }
    func testFHPictureNeverLoads() async throws {
        try await exercise { self.html($0, "<picture><source srcset='\($0)/picture.webp'><img src='\($0)/fallback.png'></picture>") }
    }
    func testFHStyleAttributeURLsNeverLoad() async throws {
        try await exercise { self.html($0, "<div style=\"background:url('\($0)/background.png');list-style-image:url('\($0)/bullet.png')\"> </div>") }
    }
    func testFHFramesAndObjectsNeverLoad() async throws {
        try await exercise { self.html($0, "<base href='\($0)/'><iframe src='\($0)/frame'></iframe><object data='\($0)/object'></object><svg><image href='\($0)/svg.png'/></svg>") }
    }
    func testFHObfuscatedResourcesNeverLoad() async throws {
        try await exercise { self.html($0, "<IMG SRC='\($0)/a?x=&quot;&gt;'><span style=\"background:u\\72l('\($0)/escape.png')\"></span><meta http-equiv='refresh' content='0;url=\($0)/refresh'>") }
    }
    func testFHImporterRejectsResourcesEvenWithoutSanitization() async throws {
        try await exercise({ self.html($0, "<link rel='stylesheet' href='\($0)/style.css'><style>@import url('\($0)/import.css');p {background:url('\($0)/bg.png')}</style><img src='\($0)/image.png'><iframe src='\($0)/frame'></iframe>") }, bypassSanitizer: true)
    }
    func testFHWebArchiveNeverLoadsMissingSubresources() async throws {
        try await exercise({ base in
            try PropertyListSerialization.data(fromPropertyList: [
                "WebMainResource": ["WebResourceData": self.html(base, "<link rel='stylesheet' href='\(base)/style.css'><img src='\(base)/missing.png'>"), "WebResourceURL": base + "/page", "WebResourceMIMEType": "text/html"],
                "WebSubresources": [["WebResourceURL": base + "/unused.css", "WebResourceData": Data("@import url('\(base)/nested.css')".utf8), "WebResourceMIMEType": "text/css"]],
                "WebSubframeArchives": [["WebMainResource": ["WebResourceURL": base + "/frame"]]]
            ], format: .binary, options: 0)
        }, type: NotePasteReader.webArchiveType)
    }

    private func rtf(_ base: String) -> String {
        #"{\rtf1\ansi Keep \b bold\b0  \i italic\i0  {\field{\*\fldinst HYPERLINK ""# + base + #"/link"}{\fldrslt link}}\par Second paragraph}"#
    }
    func testFHRTFRemoteFieldsNeverLoad() async throws {
        try await exercise({ base in
            let fields = #"{\field{\*\fldinst INCLUDEPICTURE ""# + base + #"/pixel.png"}{\fldrslt }}{\field{\*\fldinst INCLUDETEXT ""# + base + #"/text"}{\fldrslt }}{\NeXTGraphic "# + base + #"/next.png \width10 \height10}{\object\objlink{\*\objdata 0102}}"#
            return Data((self.rtf(base).dropLast() + fields + "}").utf8)
        }, type: .rtf)
    }
    func testFHRTFDKeepsEmbeddedImageWithoutResolvingRemotePaths() async throws {
        let png = try png()
        try await exercise({ base in
            let source = self.rtf(base).dropLast() + #"{\NeXTGraphic local.png \width10 \height10}{\NeXTGraphic "# + base + #"/remote.png \width10 \height10}}"#
            let wrapper = FileWrapper(directoryWithFileWrappers: ["TXT.rtf": FileWrapper(regularFileWithContents: Data(source.utf8)), "local.png": FileWrapper(regularFileWithContents: png), "remote.png": FileWrapper(symbolicLinkWithDestinationURL: URL(string: base + "/symlink.png")!)])
            return try XCTUnwrap(wrapper.serializedRepresentation)
        }, type: .rtfd, images: 1)
    }
    func testFHDataImagesAndFormattingSurvive() async throws {
        let data = try png().base64EncodedString()
        try await exercise({ base in self.html(base, "<img src='data:image/png;base64,\(data)'>") }, images: 1)
    }
    func testFHLocalFileImagesSurvive() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fh-\(UUID()).png")
        try png().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await exercise({ base in self.html(base, "<img src='\(file.absoluteString)'>") }, images: 1)
    }
    func testFHSafeInlineAndStylesheetFormattingSurvives() async throws {
        try await exercise { base in
            let original = String(decoding: self.html(base, "<style>.bold {font-weight:bold;background-image:url('\(base)/bg.png')} .italic {font-style:italic}</style>"), as: UTF8.self)
            return Data(original.replacingOccurrences(of: "<b>bold</b>", with: "<span class='bold'>bold</span>")
                .replacingOccurrences(of: "<i>italic</i>", with: "<span style='font-style:italic;background:url(\(base)/inline.png)'>italic</span>").utf8)
        }
    }
    func testFHWebArchiveKeepsEmbeddedImageBytes() async throws {
        let png = try png()
        try await exercise({ base in
            try PropertyListSerialization.data(fromPropertyList: [
                "WebMainResource": ["WebResourceData": self.html(base, "<img src='local.png'><img src='\(base)/missing.png'>"), "WebResourceURL": base + "/page", "WebResourceMIMEType": "text/html"],
                "WebSubresources": [["WebResourceURL": base + "/local.png", "WebResourceData": png, "WebResourceMIMEType": "image/png"]]
            ], format: .binary, options: 0)
        }, type: NotePasteReader.publicWebArchiveType, images: 1)
    }
    func testFHRTFKeepsEmbeddedRasterBytes() async throws {
        let hex = try png().map { String(format: "%02x", $0) }.joined()
        try await exercise({ base in
            Data((self.rtf(base).dropLast() + "{\\pict\\pngblip " + hex + "}}").utf8)
        }, type: .rtf, images: 1)
    }
    func testFHHTMLTextEntitiesAndUnicodeSurvive() async throws {
        try await exercise { base in
            let source = String(decoding: self.html(base, "<img src='\(base)/tracking.png'>"), as: UTF8.self)
                .replacingOccurrences(of: "Second paragraph", with: "Second paragraph</p><p>&copy; &eacute; &amp; &lt;img&gt; &#x1F642; 日本語")
            return Data(source.utf8)
        }
        let source = Data("<p>&copy; &eacute; &amp; &lt;img&gt; &#x1F642; 日本語</p>".utf8)
        let read = try XCTUnwrap(NotePasteReader.read(source, type: .html))
        XCTAssertTrue(read.text.string.contains("© é & <img> 🙂 日本語"))
    }
    func testFHPlainURLNeverLoads() async throws {
        // The rich helper also checks ordinary formatting; a bare URL has its
        // own observer and preserves its exact destination as an inert link.
        URLProtocol.registerClass(FHPasteProtocol.self)
        defer { URLProtocol.unregisterClass(FHPasteProtocol.self) }
        FHPasteProtocol.counter.reset()
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("")]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        let board = NSPasteboard(name: .init("FH-\(UUID())"))
        defer { board.releaseGlobally() }
        let url = "https://tracking.invalid/pasted"
        board.setString(url, forType: .URL)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(view.readSelection(from: board, type: .URL))
        XCTAssertEqual(NoteTextExport.plainBody(engine.document()), url)
        XCTAssertEqual(engine.document().blocks.flatMap(\.marks).first { $0.kind == .link }?.url, url)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(FHPasteProtocol.counter.value, 0)
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

private final class FHPasteProtocol: URLProtocol, @unchecked Sendable {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func reset() { lock.withLock { count = 0 } }
        func increment() { lock.withLock { count += 1 } }
    }
    static let counter = Counter()
    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.increment()
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
