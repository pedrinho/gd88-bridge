// Minimal test helpers. The unit tests are built with swiftc from src/*.swift (without main.swift)
// plus tests/*.swift, so they need nothing beyond Apple's Command Line Tools. Run: tools/test.sh
import Darwin
import Foundation

var testChecks = 0
var testFailures = 0
private var testCaseFailed = false

func fail(_ message: String, file: StaticString, line: UInt) {
    testFailures += 1
    testCaseFailed = true
    print("        FAIL \(file):\(line): \(message)")
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "condition is false",
            file: StaticString = #fileID, line: UInt = #line) {
    testChecks += 1
    do { if try !condition() { fail(message(), file: file, line: line) } } catch { fail("threw \(error)", file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T,
                               file: StaticString = #fileID, line: UInt = #line) {
    testChecks += 1
    do {
        let a = try actual(), e = try expected()
        if a != e { fail("expected \(e), got \(a)", file: file, line: line) }
    } catch { fail("threw \(error)", file: file, line: line) }
}

func expectThrows(_ message: String = "expected an error", file: StaticString = #fileID, line: UInt = #line,
                  _ body: () throws -> Void) {
    testChecks += 1
    do { try body(); fail(message, file: file, line: line) } catch {}
}

typealias TestCase = (String, () throws -> Void)

func suite(_ name: String, _ cases: [TestCase]) {
    print(name)
    for (caseName, body) in cases {
        testCaseFailed = false
        do { try body() } catch { fail("threw \(error)", file: #fileID, line: #line) }
        print("  \(testCaseFailed ? "FAIL" : "ok  ")  \(caseName)")
    }
}

// MARK: files and sockets

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("gd88-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func writeTemp(_ bytes: [UInt8], _ name: String = "doc") -> URL {
    let u = tempDir().appendingPathComponent(name)
    FileManager.default.createFile(atPath: u.path, contents: Data(bytes))
    return u
}

/// A socket pair acting like a client: `bytes` are written (then the write side closed) from a
/// background thread, and the other end comes back as an HTTPConnection.
func feed(_ bytes: [UInt8]) -> HTTPConnection {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let writeEnd = fds[1]
    Thread.detachNewThread {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(writeEnd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            off += n
        }
        close(writeEnd)
    }
    return HTTPConnection(fd: fds[0], timeout: 5)
}

func bodyReader(_ bytes: [UInt8]) -> BodyReader {
    BodyReader(conn: feed(bytes), contentLength: bytes.count, chunked: false)
}

// MARK: IPP

func parseIPP(_ bytes: [UInt8]) throws -> IPPMessage {
    var i = 0
    return try IPPReader(read: { n in
        guard i + n <= bytes.count else { return nil }
        defer { i += n }
        return Array(bytes[i..<i + n])
    }).message()
}

func encodeIPP(major: UInt8 = 2, minor: UInt8 = 0, code: UInt16, requestId: UInt32 = 1,
               groups: [(UInt8, [IPPAttribute])]) -> [UInt8] {
    var w = IPPWriter()
    w.header(major: major, minor: minor, code: code, requestId: requestId)
    for (tag, attrs) in groups {
        w.group(tag)
        for a in attrs { w.attribute(a) }
    }
    w.end()
    return w.bytes
}

let testPrinterURI = "ipp://localhost:8631/ipp/print"

func operationAttributes(_ extra: [IPPAttribute] = []) -> [IPPAttribute] {
    [charsetA("attributes-charset", ["utf-8"]), langA("attributes-natural-language", ["en"]),
     uriA("printer-uri", testPrinterURI)] + extra
}

// MARK: raster documents

/// A 1796-byte CUPS/PWG page header with the fields gd88bridge reads.
func rasterHeader(width: Int, height: Int, bitsPerPixel: Int = 8, colorSpace: Int = 18, bigEndian: Bool = true,
                  res: Int = 203) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 1796)
    func put(_ off: Int, _ v: Int) {
        let u = UInt32(v)
        let b = [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
        for k in 0..<4 { h[off + k] = bigEndian ? b[k] : b[3 - k] }
    }
    put(276, res); put(280, res); put(352, width * 72 / res); put(356, height * 72 / res)
    put(372, width); put(376, height); put(384, 8); put(388, bitsPerPixel)
    put(392, (width * bitsPerPixel + 7) / 8); put(400, colorSpace)
    return h
}

/// A PWG raster document ("RaS2", 8-bit sGray); `pixel(page, x, y)` gives each value.
func pwgDocument(width: Int, height: Int, pages: Int = 1,
                 pixel: (Int, Int, Int) -> UInt8 = { _, _, _ in 255 }) -> [UInt8] {
    var out = Array("RaS2".utf8)
    for p in 0..<pages {
        out += rasterHeader(width: width, height: height)
        for y in 0..<height {
            out.append(0)                                   // line used once
            var x = 0
            while x < width {
                let n = min(128, width - x)
                if n == 1 {
                    out += [0, pixel(p, x, y)]              // a run of one
                } else {
                    out.append(UInt8(257 - n))              // n literal pixels
                    for k in 0..<n { out.append(pixel(p, x + k, y)) }
                }
                x += n
            }
        }
    }
    return out
}

/// Rows (210 bytes each) of every GS v 0 strip in printer data.
func printedRows(_ d: [UInt8]) -> [[UInt8]] {
    var rows: [[UInt8]] = []
    var i = 0
    while i + 8 <= d.count {
        guard d[i] == 0x1D && d[i + 1] == 0x76 && d[i + 2] == 0x30 else { i += 1; continue }
        let w = Int(d[i + 4]) | Int(d[i + 5]) << 8
        let h = Int(d[i + 6]) | Int(d[i + 7]) << 8
        guard i + 8 + w * h <= d.count else { break }
        for r in 0..<h { rows.append(Array(d[(i + 8 + r * w)..<(i + 8 + (r + 1) * w)])) }
        i += 8 + w * h
    }
    return rows
}

/// Runs convertRaster on bytes and returns the printer data.
func encode(_ document: [UInt8], copies: Int = 1, quality: Int = 3, trim: Bool = false, maxRows: Int = Limits.maxPageRows,
            stopAfterStrips: Int? = nil) throws -> (data: [UInt8], pages: Int, stopped: Bool) {
    var out = [UInt8]()
    var strips = 0
    let r = try convertRaster(url: writeTemp(document), copies: copies, quality: quality, trim: trim,
                              shouldStop: { stopAfterStrips.map { strips >= $0 } ?? false },
                              emit: { d in
                                  if d.starts(with: [0x1D, 0x76, 0x30]) { strips += 1 }
                                  out += d
                                  return true
                              }, maxRows: maxRows)
    return (out, r.pages, r.stopped)
}
