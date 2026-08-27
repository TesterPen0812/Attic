import Foundation

struct AgentHTTPRequest: Sendable {
    static let maximumHeaderBytes = 16_384
    static let maximumBodyBytes = 1_048_576

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum ParseResult: Sendable {
        /// `searchedBytes` is the buffer prefix already scanned for the head
        /// terminator; pass it to the next `parse` call so each byte of an
        /// accumulating buffer is scanned once instead of on every chunk.
        case incomplete(searchedBytes: Int)
        case invalid
        case request(AgentHTTPRequest)
    }

    /// Parses one HTTP/1.1 request from an accumulating buffer. Returns
    /// `.incomplete` until the head and the full Content-Length body arrived.
    static func parse(_ buffer: Data, searchedBytes: Int = 0) -> ParseResult {
        let searchOffset = min(max(searchedBytes, 0), buffer.count)
        let searchStart = buffer.index(buffer.startIndex, offsetBy: searchOffset)
        guard let headRange = buffer.range(
            of: Data("\r\n\r\n".utf8),
            in: searchStart..<buffer.endIndex
        ) else {
            guard buffer.count <= maximumHeaderBytes else { return .invalid }
            // Back off 3 bytes so a terminator split across chunks still matches.
            return .incomplete(searchedBytes: max(buffer.count - 3, 0))
        }
        guard buffer.distance(from: buffer.startIndex, to: headRange.lowerBound)
                <= maximumHeaderBytes else {
            return .invalid
        }
        guard let head = String(data: buffer[buffer.startIndex..<headRange.lowerBound], encoding: .utf8) else {
            return .invalid
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid
        }
        let method = requestLine[0]
        let path = requestLine[1].components(separatedBy: "?")[0]

        var headers: [String: String] = [:]
        let unambiguousHeaders: Set<String> = [
            "authorization", "content-length", "content-type", "host",
            "mcp-protocol-version", "origin", "transfer-encoding"
        ]
        for line in lines where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.utf8.allSatisfy(Self.isHTTPTokenByte),
                  !value.contains("\0") else { return .invalid }
            // Security and framing headers must never be ambiguous, even when
            // repeated with the same value.
            if unambiguousHeaders.contains(name), headers[name] != nil { return .invalid }
            headers[name] = value
        }

        guard headers["transfer-encoding"] == nil else { return .invalid }

        var contentLength = 0
        if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength),
                  length >= 0,
                  length <= maximumBodyBytes else { return .invalid }
            contentLength = length
        }

        let bodyStart = headRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else {
            // Head is complete; resume the next scan right at its terminator.
            return .incomplete(
                searchedBytes: buffer.distance(from: buffer.startIndex, to: headRange.lowerBound)
            )
        }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: contentLength)])
        return .request(AgentHTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    private static func isHTTPTokenByte(_ byte: UInt8) -> Bool {
        let isAlphaNumeric = (48...57).contains(byte)
            || (65...90).contains(byte)
            || (97...122).contains(byte)
        return isAlphaNumeric || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126]
            .contains(byte)
    }
}
