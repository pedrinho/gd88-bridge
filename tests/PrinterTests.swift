import Foundation

func runPrinterStreamTests() {
    suite("Printer byte stream (events, acknowledgements, replies)", [
        ("events, AA and replies are separated", {
            var rx: [UInt8] = [0x00, 0xFF, 0x02, 0xAA, 0x45]
            let p = PrinterStream.split(&rx)
            expectEqual(p.replies, [0x00, 0x45])
            expectEqual(p.events, [0x02])
            expectEqual(p.acks, 1)
            expect(rx.isEmpty)
        }),
        ("an FF split across two deliveries waits for its second byte", {
            var rx: [UInt8] = [0x01, 0xFF]
            var p = PrinterStream.split(&rx)
            expectEqual(p.replies, [0x01])
            expect(p.events.isEmpty)
            expectEqual(rx, [0xFF])
            rx.append(0x05)
            p = PrinterStream.split(&rx)
            expectEqual(p.events, [0x05])
            expect(rx.isEmpty)
        }),
        ("text replies pass through unchanged", {
            var rx = Array("PeriPage_A40".utf8)
            let p = PrinterStream.split(&rx)
            expectEqual(String(decoding: p.replies, as: UTF8.self), "PeriPage_A40")
        }),
        ("lid open, lid closed and no paper events in one burst", {
            var rx: [UInt8] = [0xFF, 0x02, 0xFF, 0x01, 0xFF, 0x05]
            expectEqual(PrinterStream.split(&rx).events, [0x02, 0x01, 0x05])
        }),
    ])
}

func runStatusTests() {
    func snap(_ status: UInt8?, battery: [Int] = [], job: Bool = false, problem: String? = nil) -> StatusSnapshot {
        let s = PrinterStatus()
        s.setStatus(status)
        battery.forEach { s.addBattery($0) }
        s.setJobActive(job)
        s.setConnectProblem(problem)
        return s.snapshot()
    }
    suite("Printer status → IPP printer-state and reasons (RFC 8011)", [
        ("ready is idle with no reasons", {
            let s = snap(0x00)
            expectEqual(s.state, 3)
            expectEqual(s.reasons, ["none"])
            expectEqual(s.message, "")
        }),
        ("printing is processing", { expectEqual(snap(0x00, job: true).state, 4) }),
        ("lid open is cover-open-error and stopped (the paper bit is ignored while open)", {
            let s = snap(0x06)
            expectEqual(s.state, 5)
            expectEqual(s.reasons, ["cover-open-error"])
            expectEqual(s.message, "Lid open")
        }),
        ("no paper is media-empty-error and stopped", {
            let s = snap(0x04)
            expectEqual(s.state, 5)
            expectEqual(s.reasons, ["media-empty-error"])
        }),
        ("overheat is other-error and stopped", {
            let s = snap(0x10)
            expectEqual(s.state, 5)
            expect(s.reasons.contains("other-error"))
            expect(s.message.contains("too hot"))
        }),
        ("low battery is only a warning (not stopped)", {
            let s = snap(0x08)
            expectEqual(s.state, 3)
            expectEqual(s.reasons, ["marker-supply-low-warning"])
        }),
        ("battery is the median of the last readings", { expectEqual(snap(0, battery: [70, 66, 69]).battery, 69) }),
        ("battery at 15 % or less warns", {
            expect(snap(0, battery: [15]).reasons.contains("marker-supply-low-warning"))
            expect(!snap(0, battery: [16]).reasons.contains("marker-supply-low-warning"))
        }),
        ("readings outside 0-100 are ignored", { expectEqual(snap(0, battery: [250]).battery, nil) }),
        ("an unreachable printer is reported while a job waits", {
            let s = snap(nil, job: true, problem: "Printer off or out of range")
            expectEqual(s.state, 4)
            expectEqual(s.reasons, ["connecting-to-device-report"])
        }),
    ])
}

func runRawValidatorTests() {
    let strip: [UInt8] = [0x1D, 0x76, 0x30, 0x00, 0xD2, 0x00, 0x18, 0x00] + [UInt8](repeating: 0, count: 210 * 24)
    let job = ESCPOS.jobStart + strip + ESCPOS.jobEnd
    suite("Raw port filter (only the vendor driver's commands)", [
        ("a vendor-style job is accepted", { expectEqual(validateRawJob(job), nil) }),
        ("the label/marks variant is accepted", {
            let label = ESCPOS.jobStart + [0x1F, 0x11, 0x51] + strip + [0x1D, 0x0C, 0x1F, 0x11, 0x50, 0x10, 0xFF, 0xF1, 0x45]
            expectEqual(validateRawJob(label), nil)
        }),
        ("raster data may contain any bytes, including command-like ones", {
            let tricky = [0x1D, 0x76, 0x30, 0x00, 0x05, 0x00, 0x01, 0x00, 0x10, 0xFF, 0xE0, 0xAA, 0xAA] as [UInt8]
            expectEqual(validateRawJob(ESCPOS.jobStart + tricky + ESCPOS.jobEnd), nil)
        }),
        ("our own encoder's output is accepted", {
            let doc = pwgDocument(width: 1678, height: 50) { _, x, y in (x + y) % 3 == 0 ? 0 : 255 }
            expectEqual(validateRawJob(try encode(doc).data), nil)
        }),
        ("an HTTP request (cross-site printing from a web page) is rejected", {
            expect(validateRawJob(Array("POST / HTTP/1.1\r\nHost: localhost:9100\r\n\r\n".utf8)) != nil)
        }),
        ("the flash-writing maintenance command is rejected", {
            expect(validateRawJob(ESCPOS.jobStart + [0x10, 0xFF, 0xE0, 0xAA, 0xAA] + ESCPOS.jobEnd) != nil)
        }),
        ("the auto-off timer command is rejected", {
            expect(validateRawJob(ESCPOS.jobStart + [0x10, 0xFF, 0x12, 0x00, 0x05] + ESCPOS.jobEnd) != nil)
        }),
        ("darkness above 2 is rejected", {
            expect(validateRawJob([0x10, 0xFF, 0xF1, 0x02, 0x10, 0xFF, 0x10, 0x00, 0x03] + ESCPOS.jobEnd) != nil)
        }),
        ("a truncated strip is rejected", {
            expect(validateRawJob(ESCPOS.jobStart + Array(strip.prefix(1000)) + ESCPOS.jobEnd) != nil)
        }),
        ("an oversized strip is rejected", {
            expect(validateRawJob(ESCPOS.jobStart + [0x1D, 0x76, 0x30, 0x00, 0xD9, 0x00, 0x01, 0x00] + [UInt8](repeating: 0, count: 217) + ESCPOS.jobEnd) != nil)
        }),
        ("a job without the end-of-job command is rejected", { expect(validateRawJob(ESCPOS.jobStart + strip) != nil) }),
        ("data after the end-of-job command is rejected", { expect(validateRawJob(job + [0x1B, 0x40]) != nil) }),
        ("empty data is rejected", { expect(validateRawJob([]) != nil) }),
    ])
}
