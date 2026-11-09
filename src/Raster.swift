// Reader for PWG raster (PWG 5102.4, what CUPS sends to IPP Everywhere printers), Apple Raster
// ("URF", what AirPrint clients send) and CUPS raster (used by the offline tests).
// Decompression follows CUPS filter/raster.c, and is the same for PWG and URF:
//   per line: 1 line-repeat byte (line is used n+1 times), then control bytes until the line is full:
//     0...127   next pixel repeated n+1 times
//     129...255 257-n literal pixels follow
//     128       clear to end of line (0xFF for luminance color spaces, 0x00 otherwise)
// URF layout (checked against macOS's /usr/libexec/cups/filter/rastertourf output):
//   "UNIRAST\0", UInt32 page count (not reliable, pages are read until the end), then per page
//   a 32-byte header: [0] bits per pixel, [1] color space (0 sGray, 1 sRGB), [2] duplex, [3] quality,
//   [12-15] width, [16-19] height, [20-23] resolution (big-endian), followed by compressed lines.
import Foundation

struct RasterError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct RasterPage {
    var width = 0, height = 0
    var bitsPerColor = 0, bitsPerPixel = 0, bytesPerLine = 0
    var colorSpace = 0
    var resX = 0, resY = 0
    var pageWidthPt = 0, pageHeightPt = 0

    /// Luminance-type spaces store 0 = black (W, RGB, sGray, sRGB, ...); ink-type store max = black (K, ...).
    var isLuminance: Bool { [0, 1, 17, 18, 19, 20].contains(colorSpace) }
}

final class RasterReader {
    private let fh: FileHandle
    private var buf = [UInt8]()
    private var pos = 0
    private var eof = false
    let compressed: Bool
    let bigEndian: Bool
    let isURF: Bool
    private(set) var page = RasterPage()
    private var repeatLeft = 0
    private var lastLine = [UInt8]()
    private var pixelBytes = 1

    init(url: URL) throws {
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw RasterError("cannot open \(url.path)") }
        let sync = [UInt8](h.readData(ofLength: 4))
        switch String(decoding: sync, as: UTF8.self) {
        case "RaS2": compressed = true; bigEndian = true; isURF = false      // PWG raster / CUPS raster v2
        case "2SaR": compressed = true; bigEndian = false; isURF = false
        case "RaS3", "RaSt": compressed = false; bigEndian = true; isURF = false
        case "3SaR", "tSaR": compressed = false; bigEndian = false; isURF = false
        case "UNIR":                                           // Apple Raster: "UNIRAST\0" + page count
            let rest = [UInt8](h.readData(ofLength: 8))
            guard rest.count == 8, rest[0..<4] == [0x41, 0x53, 0x54, 0x00] else {
                try? h.close()
                throw RasterError("bad Apple Raster header")
            }
            compressed = true; bigEndian = true; isURF = true
        default:
            try? h.close()
            throw RasterError("not a PWG/URF/CUPS raster stream (sync \(hexBytes(sync)))")
        }
        fh = h
    }

    deinit { try? fh.close() }

    // MARK: byte input

    private func fill() {
        if eof { return }
        let chunk = fh.readData(ofLength: 256 * 1024)
        if chunk.isEmpty { eof = true; return }
        if pos > 0 { buf.removeFirst(pos); pos = 0 }
        buf.append(contentsOf: chunk)
    }
    private func byte() throws -> UInt8 {
        if pos >= buf.count { fill() }
        guard pos < buf.count else { throw RasterError("unexpected end of raster data") }
        let b = buf[pos]; pos += 1
        return b
    }
    private func bytes(_ n: Int) throws -> [UInt8] {
        while buf.count - pos < n && !eof { fill() }
        guard buf.count - pos >= n else { throw RasterError("unexpected end of raster data") }
        let r = Array(buf[pos..<pos + n]); pos += n
        return r
    }
    /// True when no further bytes (i.e. no further page) follow.
    var atEnd: Bool {
        if pos < buf.count { return false }
        fill()
        return pos >= buf.count
    }

    // MARK: pages and lines

    /// Reads the next page header; nil at a clean end of stream.
    func nextPage() throws -> RasterPage? {
        if atEnd { return nil }
        var p = RasterPage()
        if isURF {
            let h = try bytes(32)
            func u(_ off: Int) -> Int { Int(h[off]) << 24 | Int(h[off + 1]) << 16 | Int(h[off + 2]) << 8 | Int(h[off + 3]) }
            p.bitsPerPixel = Int(h[0])
            guard p.bitsPerPixel == 8 || p.bitsPerPixel == 24 else {
                throw RasterError("unsupported Apple Raster depth \(p.bitsPerPixel) (need 8 or 24 bits per pixel)")
            }
            p.bitsPerColor = 8
            switch h[1] {
            case 0, 4: p.colorSpace = 18          // sGray
            case 1, 5: p.colorSpace = 19          // sRGB
            default: throw RasterError("unsupported Apple Raster color space \(h[1])")
            }
            p.width = u(12); p.height = u(16)
            p.resX = u(20); p.resY = u(20)
            p.bytesPerLine = p.width * p.bitsPerPixel / 8
            p.pageWidthPt = p.resX > 0 ? p.width * 72 / p.resX : 0
            p.pageHeightPt = p.resY > 0 ? p.height * 72 / p.resY : 0
        } else {
            let h = try bytes(1796)
            func u(_ off: Int) -> Int {
                let b = h[off..<off + 4].map { UInt32($0) }
                let v = bigEndian ? (b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]) : (b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0])
                return Int(v)
            }
            p.resX = u(276); p.resY = u(280)
            p.pageWidthPt = u(352); p.pageHeightPt = u(356)
            p.width = u(372); p.height = u(376)
            p.bitsPerColor = u(384); p.bitsPerPixel = u(388); p.bytesPerLine = u(392)
            p.colorSpace = u(400)
        }
        guard p.width > 0, p.height > 0, p.width < 20000, p.height < 200000 else { throw RasterError("bad page size \(p.width)x\(p.height)") }
        guard [1, 8, 24].contains(p.bitsPerPixel) else {
            throw RasterError("unsupported \(p.bitsPerPixel) bits per pixel (need 1, 8 or 24)")
        }
        guard p.bytesPerLine == (p.width * p.bitsPerPixel + 7) / 8 else { throw RasterError("bad bytes per line \(p.bytesPerLine)") }
        page = p
        pixelBytes = max(1, (p.bitsPerPixel + 7) / 8)
        repeatLeft = 0
        lastLine = [UInt8](repeating: 0, count: p.bytesPerLine)
        return p
    }

    /// Reads one decompressed line of the current page into `out` (bytesPerLine bytes).
    func readLine(into out: inout [UInt8]) throws {
        let bpl = page.bytesPerLine
        if !compressed {
            let raw = try bytes(bpl)
            out.withUnsafeMutableBufferPointer { o in for i in 0..<bpl { o[i] = raw[i] } }
            return
        }
        if repeatLeft == 0 {
            repeatLeft = Int(try byte()) + 1
            let fill: UInt8 = page.isLuminance ? 0xFF : 0x00
            var x = 0
            while x < bpl {
                let c = try byte()
                if c == 128 {
                    while x < bpl { lastLine[x] = fill; x += 1 }
                } else if c < 128 {
                    let count = (Int(c) + 1) * pixelBytes
                    let px = try bytes(pixelBytes)
                    var k = 0
                    while k < count && x < bpl { lastLine[x] = px[k % pixelBytes]; x += 1; k += 1 }
                } else {
                    let count = (257 - Int(c)) * pixelBytes
                    let lit = try bytes(count)
                    for k in 0..<count where x < bpl { lastLine[x] = lit[k]; x += 1 }
                }
            }
        }
        out.withUnsafeMutableBufferPointer { o in for i in 0..<bpl { o[i] = lastLine[i] } }
        repeatLeft -= 1
    }
}
