import AppKit
import WebKit
import UniformTypeIdentifiers
import ImageIO

/// Clipboard documents are untrusted. Never hand HTML/archive resource URLs to
/// a platform importer. Embedded attachment bytes take a separate path, and WebKit has
/// an independent deny-all delegate in case the HTML allowlist misses something.
@MainActor
enum NotePasteReader {
    static let webArchiveType = NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")
    static let publicWebArchiveType = NSPasteboard.PasteboardType("com.apple.webarchive")
    static let richTypes: [NSPasteboard.PasteboardType] = [.rtfd, .rtf, .html, webArchiveType, publicWebArchiveType]

    struct Image {
        let token: String
        let data: Data
        let type: UTType
        let size: CGSize
        var filename: String? = nil
    }
    struct File {
        let token: String
        let data: Data
        let filename: String
        let type: UTType
    }
    struct Result {
        let text: NSAttributedString
        let images: [Image]
        let files: [File]
    }

    static func read(_ data: Data, type: NSPasteboard.PasteboardType) -> Result? {
        var images: [Image] = []
        var attachments: [File] = []
        let text: NSAttributedString?
        switch type {
        case .html:
            guard let html = decodeHTML(data) else { return nil }
            text = importHTML(sanitizeHTML(html, images: &images))
        case webArchiveType, publicWebArchiveType:
            // Decode the property list ourselves, never WebArchive/WebView:
            // archive URLs are identifiers, not permission to fetch anything.
            guard let archive = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  let main = archive["WebMainResource"] as? [String: Any],
                  let bytes = main["WebResourceData"] as? Data,
                  let html = decodeHTML(bytes, encoding: main["WebResourceTextEncodingName"] as? String) else { return nil }
            var resources: [String: Data] = [:]
            for resource in archive["WebSubresources"] as? [[String: Any]] ?? [] {
                if let url = resource["WebResourceURL"] as? String, let bytes = resource["WebResourceData"] as? Data {
                    resources[url] = bytes
                }
            }
            text = importHTML(sanitizeHTML(html, resources: resources, baseURL: (main["WebResourceURL"] as? String).flatMap(URL.init(string:)), images: &images))
        case .rtf:
            guard let safe = sanitizeRTF(data, images: &images) else { return nil }
            // Explicit RTF reader: no format sniffing and no HTML/WebKit path.
            text = NSAttributedString(rtf: safe, documentAttributes: nil)
        case .rtfd:
            guard let wrapper = FileWrapper(serializedRepresentation: data), wrapper.isDirectory,
                  let files = wrapper.fileWrappers, files["TXT.rtf"]?.isRegularFile == true,
                  let rtf = files["TXT.rtf"]?.regularFileContents else { return nil }
            var resources: [String: Data] = [:]
            for (name, file) in files where file.isRegularFile && !name.contains("/") {
                resources[name] = file.regularFileContents
            }
            // Do not invoke the RTFD reader: it can resolve NeXTGraphic paths.
            // Replace only attachments physically contained in this wrapper.
            guard let safe = sanitizeRTF(rtf, resources: resources, images: &images, files: &attachments) else { return nil }
            text = NSAttributedString(rtf: safe, documentAttributes: nil)
        default: return nil
        }
        guard let text else { return nil }
        let result = NSMutableAttributedString(attributedString: text)
        var nativeAttachments: [(NSRange, NSTextAttachment)] = []
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment {
                nativeAttachments.append((range, attachment))
            }
        }
        for (range, attachment) in nativeAttachments.reversed() {
            let wrapper = attachment.fileWrapper
            let token = (wrapper?.regularFileContents ?? attachment.contents).map {
                embedded($0, filename: wrapper?.preferredFilename ?? wrapper?.filename ?? "Pasted Attachment",
                         images: &images, files: &attachments)
            } ?? "[Attachment]"
            result.replaceCharacters(in: range, with: token)
        }
        return Result(text: result, images: images, files: attachments)
    }

    private static func decodeHTML(_ data: Data, encoding: String? = nil) -> String? {
        if let encoding {
            let value = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
            if value != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))) { return text }
        }
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// Kept internal so regression tests can bypass sanitization and exercise
    /// the second boundary against real HTTP and URLProtocol observers.
    static func importHTML(_ html: String) -> NSAttributedString? {
        let deny = DenyResources()
        return withExtendedLifetime(deny) {
            try? NSAttributedString(data: Data(html.utf8), options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .webResourceLoadDelegate: deny
            ], documentAttributes: nil)
        }
    }

    private final class DenyResources: NSObject, WebResourceLoadDelegate {
        nonisolated func webView(_ sender: WebView!, resource identifier: Any!, willSend request: URLRequest!,
                                 redirectResponse: URLResponse!, from dataSource: WebDataSource!) -> URLRequest? {
            nil
        }
    }

    private static func image(_ bytes: Data, filename: String? = nil, images: inout [Image]) -> String {
        guard bytes.count <= AttachmentLimits.maxBytesPerAttachment,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              // Raster data only; SVG/PDF can contain further references.
              [UTType.png, .jpeg, .tiff, .gif, .heic, .bmp, .webP].contains(type),
              let size = NoteImageDecoder.pixelSize(of: bytes) else { return "" }
        let token = "ATTICPASTEIMAGE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        images.append(Image(token: token, data: bytes, type: type, size: size, filename: filename))
        return token
    }

    private static func embedded(_ bytes: Data, filename: String, images: inout [Image], files: inout [File]) -> String {
        guard !bytes.isEmpty, bytes.count <= AttachmentLimits.maxBytesPerAttachment,
              filename.utf8.count <= AttachmentLimits.maxFilenameUTF8Bytes else { return "[Attachment]" }
        let raster = image(bytes, filename: filename, images: &images)
        if !raster.isEmpty { return raster }
        // Non-raster resources are inert file cards, never decoded or opened.
        let token = "ATTICPASTEFILE" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let type = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
        files.append(File(token: token, data: bytes, filename: filename, type: type))
        return token
    }

    private static func localImage(_ address: String, resources: [String: Data], images: inout [Image]) -> String {
        if let bytes = resources[address] { return image(bytes, images: &images) }
        if address.lowercased().hasPrefix("data:image/"), let comma = address.firstIndex(of: ","),
           address[..<comma].lowercased().hasSuffix(";base64"),
           let bytes = Data(base64Encoded: String(address[address.index(after: comma)...])) { return image(bytes, images: &images) }
        guard let url = URL(string: address), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= AttachmentLimits.maxBytesPerAttachment,
              let bytes = try? Data(contentsOf: url) else { return "" }
        return image(bytes, images: &images)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapedText(_ text: String) -> String {
        // Leave character references for the HTML reader (including its full
        // named-entity vocabulary); only literal markup needs quoting here.
        text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Reconstruct a small HTML vocabulary. No src/srcset, resource href,
    /// event handler, base URL, frame, object, import or CSS resource survives.
    static func sanitizeHTML(_ html: String, resources: [String: Data] = [:], baseURL: URL? = nil, images: inout [Image]) -> String {
        let tags: Set<String> = ["html", "head", "body", "p", "div", "span", "br", "b", "strong", "i", "em", "u", "s", "strike", "del", "code", "pre", "a", "ul", "ol", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "hr", "sub", "sup", "font"]
        let hidden: Set<String> = ["script", "style", "iframe", "object", "embed", "svg", "math", "template", "title"]
        // Quotes are part of the token, so '>' inside an attribute cannot
        // terminate it. Malformed/unknown tags never reach the importer.
        let regex = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|$)|<![^>]*>|<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9:-]*)(\s+(?:[^'\">]|\"[^\"]*\"|'[^']*')*)?\s*/?>"#)
        let source = html as NSString
        var result = "", cursor = 0, suppressed: String?
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            if suppressed == nil { result += escapedText(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) }
            cursor = NSMaxRange(match.range)
            guard match.range(at: 2).location != NSNotFound else { continue }
            let name = source.substring(with: match.range(at: 2)).lowercased()
            let closing = match.range(at: 1).length > 0
            if let hiddenName = suppressed {
                if closing && name == hiddenName { suppressed = nil }
                continue
            }
            if hidden.contains(name) {
                if !closing && name != "embed" {
                    if name == "style", let end = html.range(of: "</style", options: .caseInsensitive,
                        range: String.Index(utf16Offset: cursor, in: html)..<html.endIndex) {
                        let css = String(html[String.Index(utf16Offset: cursor, in: html)..<end.lowerBound])
                        result += "<style>" + safeStylesheet(css) + "</style>"
                    }
                    suppressed = name
                }
                continue
            }
            let attributes = match.range(at: 3).location == NSNotFound ? [:] : attributes(source.substring(with: match.range(at: 3)))
            if name == "img", !closing {
                let address = attributes["src"] ?? ""
                let resolved = baseURL.flatMap { URL(string: address, relativeTo: $0)?.absoluteURL.absoluteString }
                let local = resources[address] ?? resolved.flatMap { resources[$0] }
                result += local.map { image($0, images: &images) }
                    ?? localImage(address, resources: [:], images: &images)
                continue
            }
            guard tags.contains(name) else { continue }
            if closing { result += "</\(name)>"; continue }
            result += "<\(name)"
            for key in ["href", "style", "class", "id", "start", "value", "colspan", "rowspan", "color", "face"] {
                guard let value = attributes[key] else { continue }
                if key == "href" && name != "a" { continue }
                let safe: String
                if key == "style" { safe = safeCSS(value) }
                else if key == "href", let baseURL { safe = URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString ?? value }
                else { safe = value }
                result += " \(key)=\"\(escaped(safe))\""
            }
            result += ">"
        }
        if suppressed == nil { result += escapedText(source.substring(from: cursor)) }
        return "<meta charset=\"utf-8\">" + result
    }

    private static func attributes(_ source: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([a-zA-Z][a-zA-Z0-9:-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#)
        let string = source as NSString
        var values: [String: String] = [:]
        for match in regex.matches(in: source, range: NSRange(location: 0, length: string.length)) {
            let key = string.substring(with: match.range(at: 1)).lowercased()
            // First attribute wins, matching HTML; reconstruct only one copy.
            if values[key] == nil, let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                values[key] = NoteTableText.decodeEntities(string.substring(with: range))
            }
        }
        return values
    }

    private static func safeStylesheet(_ css: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"([^{}]+)\{([^{}]*)\}"#)
        let source = css as NSString
        return regex.matches(in: css, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let selector = source.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard selector.range(of: #"^[a-zA-Z0-9 .#,:>+~*\[\]=\"'-]+$"#, options: .regularExpression) != nil else { return nil }
            return selector + "{" + safeCSS(source.substring(with: match.range(at: 2))) + "}"
        }.joined()
    }

    private static func safeCSS(_ css: String) -> String {
        let properties: Set<String> = ["font-weight", "font-style", "font-family", "font-size", "text-decoration", "text-decoration-line", "color", "background-color", "text-align", "white-space", "list-style-type"]
        return css.split(separator: ";").compactMap { entry -> String? in
            let parts = entry.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard parts.count == 2, properties.contains(parts[0]) else { return nil }
            if ["color", "background-color"].contains(parts[0]),
               parts[1].range(of: #"^(?:rgba?|hsla?)\([0-9., %]+\)$"#, options: .regularExpression) != nil {
                return parts.joined(separator: ":")
            }
            guard parts[1].range(of: #"^[a-z0-9 #.,%'"-]+$"#, options: .regularExpression) != nil else { return nil }
            return parts.joined(separator: ":")
        }.joined(separator: ";")
    }

    /// Parse RTF groups before the native RTF reader sees them. Fields may
    /// keep HYPERLINK instructions (inert destinations), never INCLUDEPICTURE,
    /// INCLUDETEXT, objects, file tables, HTML alternatives or external graphics.
    static func sanitizeRTF(_ data: Data, resources: [String: Data] = [:], images: inout [Image]) -> Data? {
        var files: [File] = []
        guard let safe = sanitizeRTF(data, resources: resources, images: &images, files: &files) else { return nil }
        // Callers without a file channel still receive the promised label.
        var result = safe
        for file in files {
            while let range = result.range(of: Data(file.token.utf8)) {
                result.replaceSubrange(range, with: Data("[Attachment]".utf8))
            }
        }
        return result
    }

    private static func sanitizeRTF(_ data: Data, resources: [String: Data], images: inout [Image], files: inout [File]) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Array("{\\rtf".utf8)) else { return nil }
        var index = 0
        func group(_ depth: Int) -> [UInt8]? {
            guard depth < 256, index < bytes.count, bytes[index] == 123 else { return nil }
            let start = index
            index += 1
            var output: [UInt8] = [123]
            var destination = "", first = true, discard = false
            var picture: [UInt8] = [], hex = "", rasterPicture = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 125 {
                    index += 1
                    output.append(125)
                    if destination == "pict" {
                        guard rasterPicture else { return Array("[Attachment]".utf8) }
                        if picture.isEmpty {
                            let digits = Array(hex.utf8)
                            guard digits.count.isMultiple(of: 2) else { return Array("[Attachment]".utf8) }
                            for offset in stride(from: 0, to: digits.count, by: 2) {
                                guard let byte = UInt8(String(decoding: digits[offset...offset + 1], as: UTF8.self), radix: 16) else { return Array("[Attachment]".utf8) }
                                picture.append(byte)
                            }
                        }
                        let token = image(Data(picture), images: &images)
                        return Array((token.isEmpty ? "[Attachment]" : token).utf8)
                    }
                    if destination == "nextgraphic" {
                        // Apple's RTFD writer appends one legacy attachment
                        // fallback byte after the destination. Consume only
                        // that byte here; a person's literal ¬ stays intact.
                        if index < bytes.count, bytes[index] == 0xac { index += 1 }
                        else if index + 4 <= bytes.count,
                                String(decoding: bytes[index..<index + 4], as: UTF8.self).lowercased() == "\\'ac" { index += 4 }
                        let raw = String(decoding: bytes[start..<index], as: UTF8.self)
                        // A wrapper filename is a flat exact key, never a URL/path.
                        let pattern = #"^\{\\NeXTGraphic (?:[^\\{}]|\\[\\{}])+"#
                        if let range = raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                            var name = String(raw[range]).replacingOccurrences(of: #"^\{\\NeXTGraphic "#,
                                with: "", options: [.regularExpression, .caseInsensitive])
                            // One space separates the filename from the next
                            // control word; escaped braces/backslashes belong
                            // to the exact wrapper key, including its spaces.
                            if name.hasSuffix(" ") { name.removeLast() }
                            name = name.replacingOccurrences(of: #"\\([\\{}])"#, with: "$1", options: .regularExpression)
                            if let payload = resources[name] {
                                return Array(embedded(payload, filename: name, images: &images, files: &files).utf8)
                            }
                        }
                        return Array("[Attachment]".utf8)
                    }
                    if destination == "fldinst" {
                        let raw = String(decoding: output, as: UTF8.self)
                        let instruction = raw.replacingOccurrences(of: #"^\{(?:\\\*\s*)?\\fldinst\s*"#,
                            with: "", options: [.regularExpression, .caseInsensitive])
                            .replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard instruction.range(of: #"^HYPERLINK\s+"[^"]*"\s*$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil else { return [] }
                    }
                    return discard ? [] : output
                }
                if byte == 123 {
                    guard let child = group(depth + 1) else { return nil }
                    output += child
                    continue
                }
                if byte == 92 {
                    let controlStart = index
                    index += 1
                    guard index < bytes.count else { return nil }
                    if (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) {
                        let wordStart = index
                        while index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) { index += 1 }
                        let word = String(decoding: bytes[wordStart..<index], as: UTF8.self).lowercased()
                        if first {
                            destination = word; first = false
                            discard = ["object", "objdata", "filetbl", "htmltag", "htmlrtf", "datafield", "shp", "shpinst"].contains(word)
                        }
                        if destination == "pict", word == "pngblip" || word == "jpegblip" { rasterPicture = true }
                        if ["nextgraphic", "object", "objdata", "filetbl", "htmltag", "datafield"].contains(word), destination != word { return nil }
                        let numberStart = index
                        if index < bytes.count, bytes[index] == 45 { index += 1 }
                        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                        let number = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
                        if index < bytes.count, bytes[index] == 32 { index += 1 }
                        if word == "bin" {
                            guard let number, number >= 0, number <= bytes.count - index else { return nil }
                            if destination == "pict" { picture += bytes[index..<index + number] }
                            index += number
                        }
                    } else {
                        let symbol = bytes[index]; index += 1
                        if symbol == 39 {
                            guard index + 2 <= bytes.count else { return nil }
                            index += 2
                        }
                        if symbol != 42 { first = false }
                    }
                    output += bytes[controlStart..<index]
                    continue
                }
                if destination == "pict", (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) {
                    hex.append(Character(UnicodeScalar(byte)))
                }
                if byte != 32 && byte != 10 && byte != 13 { first = false }
                output.append(byte); index += 1
            }
            return nil
        }
        guard let safe = group(0), bytes[index...].allSatisfy({ [9, 10, 13, 32].contains($0) }) else { return nil }
        return Data(safe)
    }
}
