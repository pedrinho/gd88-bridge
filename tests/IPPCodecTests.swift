import Foundation

func runIPPCodecTests() {
    func nested(_ depth: Int) -> IPPValue {
        depth == 0 ? .integer(1) : .collection([IPPAttribute("inner", [nested(depth - 1)])])
    }
    suite("IPP encoding and decoding (RFC 8010)", [
        ("a message survives a write/read round trip", {
            let attrs: [IPPAttribute] = [
                charsetA("attributes-charset", ["utf-8"]),
                int("copies", 3), en("print-quality", 5), bool("color-supported", false),
                kw("sides-supported", ["one-sided", "two-sided-long-edge"]),
                txt("printer-info", "GD-88 ✓"), uriA("printer-uri", testPrinterURI),
                dpi("printer-resolution-default", 203, 203), rangeA("copies-supported", 1, 99),
                oob("printer-geo-location", Tag.unknown),
                coll("media-col", [[IPPAttribute("media-size", [.collection([int("x-dimension", 21000), int("y-dimension", 29700)])]),
                                    kw("media-type", "continuous")]]),
            ]
            let m = try parseIPP(encodeIPP(code: 0x000B, requestId: 42, groups: [(Tag.operation, attrs)]))
            expectEqual(m.code, 0x000B)
            expectEqual(m.requestId, 42)
            expectEqual(m.find("copies")?.values.first?.intValue, 3)
            expectEqual(m.find("print-quality")?.values.first?.intValue, 5)
            expectEqual(m.find("sides-supported")?.values.compactMap { $0.stringValue }, ["one-sided", "two-sided-long-edge"])
            expectEqual(m.find("printer-info")?.values.first?.stringValue, "GD-88 ✓")
            if case .resolution(let x, let y, let u)? = m.find("printer-resolution-default")?.values.first {
                expectEqual([x, y, Int32(u)], [203, 203, 3])
            } else { expect(false, "resolution missing") }
            if case .range(let lo, let hi)? = m.find("copies-supported")?.values.first { expectEqual([lo, hi], [1, 99]) }
            else { expect(false, "range missing") }
            if case .outOfBand(let t)? = m.find("printer-geo-location")?.values.first { expectEqual(t, Tag.unknown) }
            else { expect(false, "out-of-band value missing") }
            guard case .collection(let mc)? = m.find("media-col")?.values.first,
                  case .collection(let size)? = mc.first(where: { $0.name == "media-size" })?.values.first else {
                expect(false, "collection missing"); return
            }
            expectEqual(size.first(where: { $0.name == "y-dimension" })?.values.first?.intValue, 29700)
        }),
        ("text-with-language values are read as plain text", {
            var b = Array(encodeIPP(code: 2, groups: []).dropLast())       // header without the end tag
            b += [Tag.operation, Tag.textWithLanguage, 0, 1, 0x78, 0, 11, 0, 2, 0x65, 0x6E, 0, 5] + Array("hello".utf8) + [Tag.end]
            expectEqual(try parseIPP(b).find("x")?.values.first?.stringValue, "hello")
        }),
        ("truncated messages are rejected", {
            let full = encodeIPP(code: 0x000B, groups: [(Tag.operation, operationAttributes())])
            expectThrows { _ = try parseIPP(Array(full.prefix(full.count - 5))) }
            expectThrows { _ = try parseIPP([2, 0]) }
        }),
        ("a value without an attribute name is rejected", {
            expectThrows { _ = try parseIPP([2, 0, 0, 11, 0, 0, 0, 1, Tag.operation, Tag.integer, 0, 0, 0, 4, 0, 0, 0, 1, Tag.end]) }
        }),
        ("collections may nest 16 deep, not 17", {
            expectEqual(try parseIPP(encodeIPP(code: 2, groups: [(Tag.job, [IPPAttribute("c", [nested(16)])])])).groups.count, 1)
            expectThrows { _ = try parseIPP(encodeIPP(code: 2, groups: [(Tag.job, [IPPAttribute("c", [nested(17)])])])) }
        }),
        ("more than 4000 values are rejected", {
            expectThrows { _ = try parseIPP(encodeIPP(code: 2, groups: [(Tag.job, [ints("many", Array(0..<4001))])])) }
        }),
        ("more than 1 MB of attributes is rejected", {
            let big = IPPAttribute("big", Array(repeating: .octets([UInt8](repeating: 0x41, count: 60000)), count: 20))
            expectThrows { _ = try parseIPP(encodeIPP(code: 2, groups: [(Tag.job, [big])])) }
        }),
    ])
}

func runHTTPTests() {
    suite("HTTP layer (host check, lengths, request bodies)", [
        ("only names of this Mac are accepted as Host (DNS-rebinding defence)", {
            for ok in ["localhost", "localhost:8631", "LOCALHOST:8631", "127.0.0.1:8631", "[::1]:8631", "[::1]",
                       "gd88-bridge.local:8631", "gd88-bridge.local.", "  localhost  "] {
                expect(HTTPServer.isAllowedHost(ok), "should accept \(ok)")
            }
            for bad in [nil, "", "evil.example", "evil.example:8631", "localhost.evil.example", "127.0.0.2",
                        "[::2]:8631", "localhost:abc", "localhost:", "[::1]x", "[::1", "192.168.1.10:8631"] {
                expect(!HTTPServer.isAllowedHost(bad), "should refuse \(bad ?? "nil")")
            }
        }),
        ("Content-Length must be a non-negative number below 2^31", {
            expectEqual(HTTPServer.parseLength("10"), 10)
            expectEqual(HTTPServer.parseLength(" 42 "), 42)
            for bad in ["-5", "abc", "", "99999999999", "1e3", "+7"] { expectEqual(HTTPServer.parseLength(bad), nil) }
        }),
        ("a Content-Length body is read exactly", {
            let conn = feed(Array("helloEXTRA".utf8))
            let b = BodyReader(conn: conn, contentLength: 5, chunked: false)
            expectEqual(b.readExactly(5).map { String(decoding: $0, as: UTF8.self) }, "hello")
            expect(b.read(max: 10) == nil)
            expect(b.isFinished && !b.failed)
            close(conn.fd)
        }),
        ("chunked bodies with extensions and trailers", {
            let conn = feed(Array("5;name=x\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: y\r\n\r\n".utf8))
            let b = BodyReader(conn: conn, contentLength: nil, chunked: true)
            var got = [UInt8]()
            while let d = b.read(max: 4) { got += d }
            expectEqual(String(decoding: got, as: UTF8.self), "hello world")
            expect(b.isFinished && !b.failed)
            close(conn.fd)
        }),
        ("bad chunk sizes fail cleanly instead of crashing", {
            for text in ["-5\r\nhello\r\n0\r\n\r\n", "zz\r\n", "FFFFFFFFF\r\n", "\r\n"] {
                let conn = feed(Array(text.utf8))
                let b = BodyReader(conn: conn, contentLength: nil, chunked: true)
                while b.read(max: 100) != nil {}
                expect(b.failed, "should fail: \(text.debugDescription)")
                close(conn.fd)
            }
        }),
        ("a body that ends early is reported as failed", {
            let conn = feed(Array("abcd".utf8))
            let b = BodyReader(conn: conn, contentLength: 10, chunked: false)
            expect(b.readExactly(10) == nil)
            expect(b.failed)
            close(conn.fd)
        }),
        ("drain stops at its limit", {
            let conn = feed([UInt8](repeating: 1, count: 200_000))
            expect(!BodyReader(conn: conn, contentLength: 200_000, chunked: false).drain(limit: 64 * 1024))
            close(conn.fd)
        }),
    ])
}

func runJobQueueTests() {
    func job(_ q: JobQueue, _ payload: JobPayload = .escpos(Data([1]))) -> Job {
        Job(id: q.makeId(), payload: payload, name: "t", user: "u", copies: 1, quality: 4, source: "ipp")
    }
    func next(_ q: JobQueue, _ timeout: TimeInterval = 0.2) -> Job? {
        if case .job(let j)? = q.waitForWork(timeout: timeout) { return j }
        return nil
    }
    suite("Job queue", [
        ("jobs come out in order", {
            let q = JobQueue()
            let a = job(q), b = job(q)
            q.submit(a); q.submit(b)
            expect(next(q) === a)
            expect(next(q) === b)
            expect(q.waitForWork(timeout: 0.05) == nil)
        }),
        ("Create-Job waits for its document", {
            let q = JobQueue()
            let j = job(q, .none)
            q.register(j)
            expectEqual(q.with(j) { $0.state }, .held)
            expectEqual(q.with(j) { $0.reasons }, ["job-incoming"])
            expect(next(q, 0.05) == nil)
            q.attach(j, .escpos(Data([1])))
            expect(next(q) === j)
        }),
        ("cancel: waiting jobs end at once, a printing job is asked to stop", {
            let q = JobQueue()
            let waiting = job(q), printing = job(q)
            q.submit(printing); q.submit(waiting)
            _ = next(q)                                         // the worker took `printing`
            q.with(printing) { $0.state = .processing }
            expect(q.cancel(waiting.id) == .canceled)
            expectEqual(q.with(waiting) { $0.state }, .canceled)
            expect(q.cancel(printing.id) == .stopping)
            expect(q.with(printing) { $0.cancelRequested })
            expect(q.cancel(waiting.id) == .notPossible)
            expect(q.cancel(999) == .notFound)
        }),
        ("a job created without a document is canceled immediately", {
            let q = JobQueue()
            let j = job(q, .none)
            q.register(j)
            expect(q.cancel(j.id) == .canceled)
        }),
        ("Create-Job without Send-Document expires", {
            let q = JobQueue()
            let j = job(q, .none)
            q.register(j)
            q.expireIncoming(after: 0)
            expectEqual(q.with(j) { $0.state }, .aborted)
        }),
        ("identify requests and refreshes are delivered; a job wins over a refresh", {
            let q = JobQueue()
            q.requestIdentify()
            if case .identify? = q.waitForWork(timeout: 0.2) {} else { expect(false, "no identify") }
            q.requestRefresh()
            let j = job(q)
            q.submit(j)
            expect(next(q) === j)
        }),
        ("activeCount counts unfinished jobs", {
            let q = JobQueue()
            let a = job(q), b = job(q)
            q.submit(a); q.submit(b)
            expectEqual(q.activeCount, 2)
            q.finish(a, .completed, reasons: ["job-completed-successfully"])
            expectEqual(q.activeCount, 1)
        }),
    ])
}
