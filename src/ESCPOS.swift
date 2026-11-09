// Grayscale raster -> GD-88 (PeriPage A40 firmware) printer bytes.
//
// Byte layout copied from the vendor driver's output (rastertoGD88, MediaType Continuous):
//   job start   10 FF F1 02  10 40  1F 80 01 10  10 FF 10 00 00   (last 5 bytes = darkness 0)
//   rows        1D 76 30 00 D2 00 18 00 + 24 rows x 210 bytes      (GS v 0, 1680 dots, 1 = black)
//   job end     1B 4A 60 (feed 96 dots = 12 mm)  10 FF F1 45
// Pages follow each other with nothing in between; each page is padded to a multiple of 24 rows.
import Foundation

enum ESCPOS {
    static let dots = 1680
    static let rowBytes = 210
    static let stripRows = 24
    static let jobStart: [UInt8] = [0x10, 0xFF, 0xF1, 0x02, 0x10, 0x40, 0x1F, 0x80, 0x01, 0x10, 0x10, 0xFF, 0x10, 0x00, 0x00]
    static let jobEnd: [UInt8] = [0x1B, 0x4A, 0x60, 0x10, 0xFF, 0xF1, 0x45]
}

final class ESCPOSEncoder {
    let dither: Bool           // false = plain threshold (IPP print-quality draft)
    let trimLastPage: Bool     // continuous roll: drop blank rows at the end of the job
    let keepBlankRows = 64     // ...but keep 8 mm (8 dots/mm)
    private let emit: (Data) -> Bool

    private var strip = [UInt8]()
    private var rowsInStrip = 0
    private var pendingBlank = 0
    private var row = [UInt8](repeating: 0, count: ESCPOS.rowBytes)
    private var errCur = [Float]()
    private var errNext = [Float]()
    private var y = 0
    private(set) var stripsSent = 0

    init(dither: Bool, trimLastPage: Bool, emit: @escaping (Data) -> Bool) {
        self.dither = dither
        self.trimLastPage = trimLastPage
        self.emit = emit
        strip.reserveCapacity(ESCPOS.rowBytes * ESCPOS.stripRows)
    }

    /// True right after a strip was handed to `emit` (a safe point to stop a job).
    var atStripBoundary: Bool { rowsInStrip == 0 }

    func beginPage(width: Int) {
        errCur = [Float](repeating: 0, count: width + 2)
        errNext = [Float](repeating: 0, count: width + 2)
        y = 0
    }

    /// `darkness`: one value per pixel, 0 = white ... 255 = black.
    func addRow(_ darkness: [UInt8]) -> Bool {
        let w = min(darkness.count, ESCPOS.dots)
        for i in 0..<ESCPOS.rowBytes { row[i] = 0 }
        if dither {
            let ltr = y % 2 == 0
            for i in 0..<w {
                let x = ltr ? i : w - 1 - i
                let v = Float(darkness[x]) + errCur[x + 1]
                let on = v >= 128
                if on { row[x >> 3] |= UInt8(0x80 >> (x & 7)) }
                let e = v - (on ? 255 : 0)
                if ltr {
                    errCur[x + 2] += e * 7 / 16
                    errNext[x] += e * 3 / 16; errNext[x + 1] += e * 5 / 16; errNext[x + 2] += e / 16
                } else {
                    errCur[x] += e * 7 / 16
                    errNext[x + 2] += e * 3 / 16; errNext[x + 1] += e * 5 / 16; errNext[x] += e / 16
                }
            }
            swap(&errCur, &errNext)
            for i in errNext.indices { errNext[i] = 0 }
        } else {
            for x in 0..<w where darkness[x] >= 128 { row[x >> 3] |= UInt8(0x80 >> (x & 7)) }
        }
        y += 1
        if trimLastPage && row.allSatisfy({ $0 == 0 }) {
            pendingBlank += 1            // decide later whether this blank row is needed
            return true
        }
        return flushBlank() && append(row)
    }

    func endPage(isLast: Bool) -> Bool {
        if isLast && trimLastPage {
            let keep = min(pendingBlank, keepBlankRows)
            pendingBlank = 0
            for _ in 0..<keep where !append(whiteRow) { return false }
        } else if !flushBlank() {
            return false
        }
        while rowsInStrip > 0 { if !append(whiteRow) { return false } }   // pad to 24 rows like the driver
        return true
    }

    private let whiteRow = [UInt8](repeating: 0, count: ESCPOS.rowBytes)

    private func flushBlank() -> Bool {
        while pendingBlank > 0 {
            pendingBlank -= 1
            if !append(whiteRow) { return false }
        }
        return true
    }

    private func append(_ r: [UInt8]) -> Bool {
        strip.append(contentsOf: r)
        rowsInStrip += 1
        if rowsInStrip < ESCPOS.stripRows { return true }
        var block = Data([0x1D, 0x76, 0x30, 0x00, UInt8(ESCPOS.rowBytes & 0xFF), UInt8(ESCPOS.rowBytes >> 8),
                          UInt8(ESCPOS.stripRows), 0x00])
        block.append(contentsOf: strip)
        strip.removeAll(keepingCapacity: true)
        rowsInStrip = 0
        stripsSent += 1
        return emit(block)
    }
}

/// Converts a raster file to printer bytes, streaming them through `emit` (start bytes, strips, end bytes).
/// `shouldStop` is checked at strip boundaries; when it returns true the job ends cleanly with the end bytes.
/// Pages longer than `maxRows` (about 1 m) are cut off, so a malformed or hostile job can't run out the roll.
func convertRaster(url: URL, copies: Int, quality: Int, trim: Bool,
                   shouldStop: () -> Bool, emit: @escaping (Data) -> Bool,
                   pageDone: (Int) -> Void = { _ in },
                   maxRows: Int = Limits.maxPageRows) throws -> (pages: Int, stopped: Bool, failed: Bool) {
    let encoder = ESCPOSEncoder(dither: quality != 3, trimLastPage: trim, emit: emit)
    guard emit(Data(ESCPOS.jobStart)) else { return (0, false, true) }
    var pages = 0
    var stopped = false
    copyLoop: for copy in 0..<max(1, copies) {
        let reader = try RasterReader(url: url)
        while let page = try reader.nextPage() {
            if page.resX != 203 || page.resY != 203 {
                log("note: page resolution \(page.resX)x\(page.resY) dpi, printer is 203 dpi")
            }
            encoder.beginPage(width: page.width)
            var line = [UInt8](repeating: 0, count: page.bytesPerLine)
            var dark = [UInt8](repeating: 0, count: page.width)
            if page.height > maxRows { log("page \(pages + 1) is \(page.height) rows long; printing the first \(maxRows) (about 1 m)") }
            for row in 0..<page.height {
                try reader.readLine(into: &line)        // always read every line to stay in step with the stream
                guard row < maxRows else { continue }
                toDarkness(line, page, &dark)
                guard encoder.addRow(dark) else { return (pages, false, true) }
                if encoder.atStripBoundary && shouldStop() { stopped = true; break copyLoop }
            }
            let isLast = copy == max(1, copies) - 1 && reader.atEnd
            guard encoder.endPage(isLast: isLast) else { return (pages, false, true) }
            pages += 1
            pageDone(pages)
        }
    }
    guard emit(Data(ESCPOS.jobEnd)) else { return (pages, stopped, true) }
    return (pages, stopped, false)
}

/// Normalises one raster line to darkness values (0 white ... 255 black).
private func toDarkness(_ line: [UInt8], _ p: RasterPage, _ out: inout [UInt8]) {
    if p.bitsPerPixel == 8 {
        if p.isLuminance { for x in 0..<p.width { out[x] = 255 &- line[x] } }
        else { for x in 0..<p.width { out[x] = line[x] } }
    } else if p.bitsPerPixel == 24 {    // RGB: Rec. 601 luminance
        for x in 0..<p.width {
            let r = Int(line[3 * x]), g = Int(line[3 * x + 1]), b = Int(line[3 * x + 2])
            out[x] = UInt8(255 - (299 * r + 587 * g + 114 * b) / 1000)
        }
    } else {    // 1 bit per pixel
        for x in 0..<p.width {
            let bit = (line[x >> 3] >> (7 - UInt8(x & 7))) & 1
            let black = p.isLuminance ? bit == 0 : bit == 1
            out[x] = black ? 255 : 0
        }
    }
}
