import Foundation

func runRasterTests() {
    func pages(_ bytes: [UInt8]) throws -> [(RasterPage, [[UInt8]])] {
        let r = try RasterReader(url: writeTemp(bytes))
        var out: [(RasterPage, [[UInt8]])] = []
        while let p = try r.nextPage() {
            var line = [UInt8](repeating: 0, count: p.bytesPerLine)
            var lines: [[UInt8]] = []
            for _ in 0..<p.height { try r.readLine(into: &line); lines.append(line) }
            out.append((p, lines))
        }
        return out
    }
    suite("Raster decoding (PWG, Apple Raster, CUPS)", [
        ("PWG: line repeat, repeat runs, literal runs and fill-with-white", {
            var doc = Array("RaS2".utf8) + rasterHeader(width: 8, height: 3)
            doc += [0x01, 0x07, 0x10]                       // 2 lines of eight 0x10 pixels
            doc += [0x00, 0xFE, 1, 2, 3, 0x80]              // 3 literal pixels, then white to the end
            let p = try pages(doc)
            expectEqual(p.count, 1)
            expectEqual(p[0].1, [[UInt8](repeating: 0x10, count: 8), [UInt8](repeating: 0x10, count: 8),
                                 [1, 2, 3, 255, 255, 255, 255, 255]])
        }),
        ("PWG: several pages and their sizes", {
            let p = try pages(pwgDocument(width: 300, height: 7, pages: 3) { pg, x, _ in UInt8((pg * 50 + x) % 256) })
            expectEqual(p.count, 3)
            expectEqual(p[2].0.width, 300)
            expectEqual(p[2].1[6][10], UInt8((100 + 10) % 256))
        }),
        ("Apple Raster (URF): header and lines", {
            var doc = Array("UNIRAST".utf8) + [0, 0, 0, 0, 1]
            var h = [UInt8](repeating: 0, count: 32)
            h[0] = 8; h[1] = 0                               // 8 bits, sGray
            h[15] = 4; h[19] = 2; h[22] = 0; h[23] = 203     // width 4, height 2, 203 dpi
            doc += h + [0x01, 0x03, 0x55]                    // 2 lines of four 0x55 pixels
            let p = try pages(doc)
            expectEqual(p[0].0.resX, 203)
            expectEqual(p[0].0.colorSpace, 18)
            expectEqual(p[0].1, [[0x55, 0x55, 0x55, 0x55], [0x55, 0x55, 0x55, 0x55]])
        }),
        ("Apple Raster with 1-bit pixels is refused", {
            var h = [UInt8](repeating: 0, count: 32)
            h[0] = 1; h[15] = 8; h[19] = 1; h[23] = 203
            expectThrows { _ = try pages(Array("UNIRAST".utf8) + [0, 0, 0, 0, 1] + h + [0, 0, 0]) }
        }),
        ("CUPS raster, big- and little-endian, uncompressed", {
            let be = Array("RaS3".utf8) + rasterHeader(width: 3, height: 1, bigEndian: true) + [9, 8, 7]
            let le = Array("3SaR".utf8) + rasterHeader(width: 3, height: 1, bigEndian: false) + [9, 8, 7]
            expectEqual(try pages(be)[0].1, [[9, 8, 7]])
            expectEqual(try pages(le)[0].1, [[9, 8, 7]])
        }),
        ("unknown data is refused", { expectThrows { _ = try RasterReader(url: writeTemp(Array("%PDF-1.4".utf8))) } }),
        ("a zero-sized page is refused", {
            expectThrows { _ = try pages(Array("RaS2".utf8) + rasterHeader(width: 0, height: 5)) }
        }),
        ("inconsistent bytes-per-line is refused", {
            var h = rasterHeader(width: 10, height: 1)
            h[395] = 99
            expectThrows { _ = try pages(Array("RaS2".utf8) + h + [0, 0x09, 0]) }
        }),
        ("truncated data is reported, not read past the end", {
            expectThrows { _ = try pages(Array("RaS2".utf8) + rasterHeader(width: 100, height: 2) + [0x00, 0xFE, 1]) }
        }),
    ])
}

func runESCPOSTests() {
    func encodeRows(_ rows: [[UInt8]], dither: Bool = false, trim: Bool = false, isLast: Bool = true) -> [UInt8] {
        var out = [UInt8]()
        let e = ESCPOSEncoder(dither: dither, trimLastPage: trim, emit: { out += $0; return true })
        e.beginPage(width: rows.first?.count ?? 0)
        for r in rows { _ = e.addRow(r) }
        _ = e.endPage(isLast: isLast)
        return out
    }
    let white = [UInt8](repeating: 0, count: 1680)          // darkness 0
    let black = [UInt8](repeating: 255, count: 1680)
    suite("ESC/POS encoder (GD-88 printer data)", [
        ("start and end bytes match the vendor driver", {
            expectEqual(ESCPOS.jobStart, [0x10, 0xFF, 0xF1, 0x02, 0x10, 0x40, 0x1F, 0x80, 0x01, 0x10, 0x10, 0xFF, 0x10, 0x00, 0x00])
            expectEqual(ESCPOS.jobEnd, [0x1B, 0x4A, 0x60, 0x10, 0xFF, 0xF1, 0x45])
        }),
        ("strip header, 24 rows, 210 bytes per row, padded with white", {
            let out = encodeRows([black])
            expectEqual(Array(out.prefix(8)), [0x1D, 0x76, 0x30, 0x00, 0xD2, 0x00, 0x18, 0x00])
            expectEqual(out.count, 8 + 210 * 24)
            let rows = printedRows(out)
            expectEqual(rows.count, 24)
            expect(rows[0].allSatisfy { $0 == 0xFF })
            expect(rows[1...].allSatisfy { $0.allSatisfy { $0 == 0 } })
        }),
        ("bits are most-significant first; narrow pages are padded on the right", {
            var row = [UInt8](repeating: 0, count: 10)
            row[0] = 255; row[9] = 255
            let r = printedRows(encodeRows([row]))[0]
            expectEqual(r[0], 0x80)
            expectEqual(r[1], 0x40)
            expect(r[2...].allSatisfy { $0 == 0 })
        }),
        ("wider pages are cropped to 1680 dots", {
            let r = printedRows(encodeRows([[UInt8](repeating: 255, count: 1700)]))[0]
            expectEqual(r.count, 210)
            expect(r.allSatisfy { $0 == 0xFF })
        }),
        ("the end of the last page is trimmed to 8 mm", {
            let rows = printedRows(encodeRows([black] + Array(repeating: white, count: 200), trim: true))
            expectEqual(rows.count, 72)                 // 1 + 64 kept rows, padded to 3 strips
        }),
        ("earlier pages keep their full length", {
            let rows = printedRows(encodeRows([black] + Array(repeating: white, count: 200), trim: true, isLast: false))
            expectEqual(rows.count, 216)                // 201 rows padded to 9 strips
        }),
        ("dithering leaves pure black and white unchanged", {
            let pattern = (0..<48).map { y in (0..<1680).map { x in UInt8((x / 7 + y / 5) % 2 == 0 ? 255 : 0) } }
            expectEqual(encodeRows(pattern, dither: true), encodeRows(pattern, dither: false))
        }),
        ("dithering 50 % gray sets about half the dots", {
            let gray = Array(repeating: [UInt8](repeating: 128, count: 1680), count: 48)
            let bits = printedRows(encodeRows(gray, dither: true)).flatMap { $0 }.reduce(0) { $0 + $1.nonzeroBitCount }
            let ratio = Double(bits) / Double(1680 * 48)
            expect(ratio > 0.45 && ratio < 0.55, "ratio \(ratio)")
        }),
        ("a full job: start, strips, end; copies repeat the pages", {
            let doc = pwgDocument(width: 1678, height: 30, pages: 2) { _, x, _ in x < 100 ? 0 : 255 }
            let r = try encode(doc, copies: 2)
            expectEqual(r.pages, 4)
            expect(r.data.starts(with: ESCPOS.jobStart))
            expectEqual(Array(r.data.suffix(7)), ESCPOS.jobEnd)
            expectEqual(printedRows(r.data).count, 4 * 48)
        }),
        ("pages longer than the limit are cut off", {
            let doc = pwgDocument(width: 1678, height: 100, pages: 2)
            expectEqual(printedRows(try encode(doc, maxRows: 48).data).count, 2 * 48)
        }),
        ("a canceled job stops at a strip boundary and still ends properly", {
            let r = try encode(pwgDocument(width: 1678, height: 240), stopAfterStrips: 2)
            expect(r.stopped)
            expectEqual(printedRows(r.data).count, 48)
            expectEqual(Array(r.data.suffix(7)), ESCPOS.jobEnd)
        }),
    ])
}
