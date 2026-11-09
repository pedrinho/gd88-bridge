// Minimal HTTP/1.1 server for IPP (RFC 8010 §3: IPP requests are HTTP POSTs of application/ipp).
// Handles keep-alive, "Expect: 100-continue", Content-Length and chunked request bodies.
//
// Security: the server listens on 127.0.0.1 only, but web pages can still reach localhost through a
// browser (DNS rebinding). Requests are therefore only served when the Host header names this Mac
// (localhost, 127.0.0.1, [::1] or gd88-bridge.local). Lengths, header counts and the number of
// connections are bounded so a misbehaving client can't crash the bridge or exhaust it.
import Darwin
import Foundation

final class HTTPConnection {
    let fd: Int32
    private var buf = [UInt8]()
    private var pos = 0

    init(fd: Int32, timeout: Int = 120) {
        self.fd = fd
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func fill() -> Bool {
        var tmp = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(fd, &tmp, tmp.count, 0)
        guard n > 0 else { return false }
        if pos > 0 { buf.removeFirst(pos); pos = 0 }
        buf.append(contentsOf: tmp[0..<n])
        return true
    }

    func readLine(max: Int = 16 * 1024) -> String? {
        while true {
            if let i = buf[pos...].firstIndex(of: 0x0A) {
                var end = i
                if end > pos && buf[end - 1] == 0x0D { end -= 1 }
                let line = String(decoding: buf[pos..<end], as: UTF8.self)
                pos = i + 1
                return line
            }
            if buf.count - pos > max || !fill() { return nil }
        }
    }

    func read(upTo n: Int) -> [UInt8]? {
        guard n > 0 else { return [] }
        if pos >= buf.count && !fill() { return nil }
        let k = min(n, buf.count - pos)
        let r = Array(buf[pos..<pos + k])
        pos += k
        return r
    }

    func write(_ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

/// The request body, whichever way it is framed.
final class BodyReader {
    private let conn: HTTPConnection
    private let chunked: Bool
    private var remaining: Int
    private var done: Bool
    private(set) var failed = false

    /// `contentLength` must already be validated (non-negative); see HTTPServer.parseLength.
    init(conn: HTTPConnection, contentLength: Int?, chunked: Bool) {
        self.conn = conn
        self.chunked = chunked
        remaining = chunked ? 0 : max(0, contentLength ?? 0)
        done = !chunked && remaining == 0
    }

    var isFinished: Bool { done }

    /// Up to `max` bytes, or nil at the end of the body (check `failed` for errors).
    func read(max: Int) -> [UInt8]? {
        if done || failed { return nil }
        if chunked && remaining == 0 {
            guard let line = conn.readLine() else { failed = true; return nil }
            let sizeText = line.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.allSatisfy(\.isHexDigit), sizeText.count <= 8,
                  let size = Int(sizeText, radix: 16), size <= Limits.maxHTTPLength else { failed = true; return nil }
            if size == 0 {
                var trailers = 0
                while let trailer = conn.readLine(), !trailer.isEmpty {
                    trailers += 1
                    if trailers > Limits.maxHTTPHeaderLines { failed = true; return nil }
                }
                done = true
                return nil
            }
            remaining = size
        }
        guard let d = conn.read(upTo: min(max, remaining)), !d.isEmpty else { failed = true; return nil }
        remaining -= d.count
        if remaining == 0 {
            if chunked {
                if conn.readLine() == nil { failed = true }   // CRLF after each chunk
            } else {
                done = true
            }
        }
        return d
    }

    func readExactly(_ n: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(n)
        while out.count < n {
            guard let d = read(max: n - out.count) else { return nil }
            out += d
        }
        return out
    }

    /// Reads and discards up to `limit` bytes; true if the body ended within the limit.
    @discardableResult
    func drain(limit: Int = 64 * 1024) -> Bool {
        var total = 0
        while let d = read(max: 16 * 1024) {
            total += d.count
            if total > limit { return false }
        }
        return !failed
    }

    /// Gives up on the rest of the body; the connection must be closed afterwards.
    func abandon() { failed = true }
}

final class HTTPServer {
    let port: UInt16
    let ipp: IPPService
    private let countLock = NSLock()
    private var active = 0

    init(port: UInt16, ipp: IPPService) {
        self.port = port
        self.ipp = ipp
    }

    /// Only names of this Mac are accepted, which defeats DNS-rebinding attacks from web pages.
    static func isAllowedHost(_ value: String?) -> Bool {
        guard var h = value?.trimmingCharacters(in: .whitespaces).lowercased(), !h.isEmpty else { return false }
        if h.hasPrefix("[") {                                  // IPv6 literal, e.g. [::1]:8631
            guard let close = h.firstIndex(of: "]") else { return false }
            let rest = h[h.index(after: close)...]
            guard rest.isEmpty || (rest.first == ":" && rest.count > 1 && rest.dropFirst().allSatisfy(\.isNumber)) else { return false }
            return h[h.index(after: h.startIndex)..<close] == "::1"
        }
        if let colon = h.lastIndex(of: ":") {
            let port = h[h.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return false }
            h = String(h[..<colon])
        }
        if h.hasSuffix(".") { h.removeLast() }
        return ["localhost", "127.0.0.1", "gd88-bridge.local"].contains(h)
    }

    /// A Content-Length header value: digits only, at most 2^31 - 1. nil means invalid.
    static func parseLength(_ value: String) -> Int? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v.count <= 10, v.allSatisfy(\.isNumber), let n = Int(v), n <= Limits.maxHTTPLength else { return nil }
        return n
    }

    func start() {
        guard let s = listenLocal(port: port) else {
            log("ERROR cannot listen on 127.0.0.1:\(port) (errno \(errno)); is another copy running?")
            exit(1)
        }
        log("IPP printer at ipp://localhost:\(port)/ipp/print")
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(s, nil, nil)
                guard c >= 0 else { continue }
                countLock.lock()
                if active >= Limits.maxHTTPConnections {
                    countLock.unlock()
                    _ = HTTPConnection(fd: c, timeout: 1).write(Array("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                    close(c)
                    continue
                }
                active += 1
                countLock.unlock()
                Thread.detachNewThread {
                    self.serve(c)
                    self.countLock.lock(); self.active -= 1; self.countLock.unlock()
                }
            }
        }
    }

    func serve(_ fd: Int32) {
        let conn = HTTPConnection(fd: fd)
        defer { close(fd) }
        while true {
            guard let requestLine = conn.readLine() else { return }
            if requestLine.isEmpty { continue }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 3 else { _ = respond(conn, 400, "Bad Request", keepAlive: false); return }
            let method = String(parts[0]), path = String(parts[1]), version = String(parts[2])
            var headers: [String: String] = [:]
            var lines = 0
            while true {
                guard let line = conn.readLine() else { return }
                if line.isEmpty { break }
                lines += 1
                if lines > Limits.maxHTTPHeaderLines { _ = respond(conn, 431, "Request Header Fields Too Large", keepAlive: false); return }
                if let c = line.firstIndex(of: ":") {
                    headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
            }
            guard HTTPServer.isAllowedHost(headers["host"]) else {
                log("refused HTTP request for host \"\(clean(headers["host"] ?? "(none)", max: 80))\"")
                _ = respond(conn, 400, "Bad Request", type: "text/plain", body: Array("unknown host\n".utf8), keepAlive: false)
                return
            }
            var length: Int?
            if let raw = headers["content-length"] {
                guard let n = HTTPServer.parseLength(raw) else { _ = respond(conn, 400, "Bad Request", keepAlive: false); return }
                length = n
            }
            let connection = headers["connection"]?.lowercased() ?? ""
            let keepAlive = version == "HTTP/1.1" ? connection != "close" : connection == "keep-alive"
            let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
            if headers["expect"]?.lowercased() == "100-continue" {
                _ = conn.write(Array("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            let body = BodyReader(conn: conn, contentLength: length, chunked: chunked)
            let ok: Bool
            switch method {
            case "POST":
                if (headers["content-type"] ?? "").lowercased().hasPrefix("application/ipp") {
                    let response = ipp.handle(body: body)
                    if !body.failed && !body.drain() { body.abandon() }   // never read an unlimited leftover
                    ok = respond(conn, 200, "OK", type: "application/ipp", body: response, keepAlive: keepAlive && !body.failed)
                } else {
                    body.abandon()
                    ok = respond(conn, 400, "Bad Request", type: "text/plain", body: Array("expected application/ipp\n".utf8), keepAlive: false)
                }
            case "GET", "HEAD":
                if !body.drain() { body.abandon() }
                if path == "/" {
                    let page = Array(ipp.statusPage().utf8)
                    ok = respond(conn, 200, "OK", type: "text/html; charset=utf-8", body: page, keepAlive: keepAlive, headOnly: method == "HEAD")
                } else if let png = ipp.icon(path) {
                    ok = respond(conn, 200, "OK", type: "image/png", body: png, keepAlive: keepAlive, headOnly: method == "HEAD")
                } else {
                    ok = respond(conn, 404, "Not Found", type: "text/plain", body: Array("not found\n".utf8), keepAlive: keepAlive, headOnly: method == "HEAD")
                }
            case "OPTIONS":
                if !body.drain() { body.abandon() }
                ok = respond(conn, 200, "OK", keepAlive: keepAlive, extra: "Allow: GET, HEAD, OPTIONS, POST\r\n")
            default:
                body.abandon()
                ok = respond(conn, 501, "Not Implemented", keepAlive: false)
            }
            if !ok || !keepAlive || body.failed { return }
        }
    }

    private func respond(_ conn: HTTPConnection, _ code: Int, _ reason: String, type: String? = nil, body: [UInt8] = [],
                         keepAlive: Bool, headOnly: Bool = false, extra: String = "") -> Bool {
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "Keep-Alive" : "close")\r\nServer: gd88bridge\r\n"
        if let t = type { head += "Content-Type: \(t)\r\n" }
        head += extra + "\r\n"
        return conn.write(Array(head.utf8) + (headOnly ? [] : body))
    }
}
