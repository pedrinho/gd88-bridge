import Darwin
import Foundation

private struct Bridge {
    let config: Config
    let queue = JobQueue()
    let status = PrinterStatus()
    let ipp: IPPService

    init(maxDocumentBytes: Int = 1 << 20, maxActiveJobs: Int = 50) {
        let dir = tempDir()
        var c = Config(baseDir: dir.appendingPathComponent("base"), spoolDir: dir.appendingPathComponent("spool"))
        c.dryRun = true
        c.maxDocumentBytes = maxDocumentBytes
        c.maxActiveJobs = maxActiveJobs
        makePrivateDirectory(c.baseDir)
        makePrivateDirectory(c.spoolDir)
        config = c
        ipp = IPPService(config: c, queue: queue, status: status)
    }

    func call(_ request: [UInt8]) throws -> IPPMessage {
        let conn = feed(request)
        defer { close(conn.fd) }
        return try parseIPP(ipp.handle(body: BodyReader(conn: conn, contentLength: request.count, chunked: false)))
    }

    func call(_ op: UInt16, requestId: UInt32 = 1, _ op_attrs: [IPPAttribute] = operationAttributes(),
              job: [IPPAttribute] = [], document: [UInt8] = []) throws -> IPPMessage {
        var groups: [(UInt8, [IPPAttribute])] = [(Tag.operation, op_attrs)]
        if !job.isEmpty { groups.append((Tag.job, job)) }
        return try call(encodeIPP(code: op, requestId: requestId, groups: groups) + document)
    }

    /// Sends a raw HTTP request through the real HTTP server loop and returns the response text.
    func http(_ request: String) -> String {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let server = HTTPServer(port: 0, ipp: ipp)
        let serverFd = fds[0], clientFd = fds[1]
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { server.serve(serverFd); done.signal() }
        _ = Array(request.utf8).withUnsafeBytes { Darwin.write(clientFd, $0.baseAddress, $0.count) }
        shutdown(clientFd, SHUT_WR)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(clientFd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        _ = done.wait(timeout: .now() + 5)
        close(clientFd)
        return String(decoding: out, as: UTF8.self)
    }
}

private let printJob: UInt16 = 0x0002, validateJob: UInt16 = 0x0004, createJob: UInt16 = 0x0005
private let sendDocument: UInt16 = 0x0006, cancelJob: UInt16 = 0x0008, getJobAttributes: UInt16 = 0x0009
private let getPrinterAttributes: UInt16 = 0x000B, identifyPrinter: UInt16 = 0x003C

func runIPPServiceTests() {
    let pwg = pwgDocument(width: 1678, height: 24) { _, x, _ in x < 50 ? 0 : 255 }
    suite("IPP printer (requests through the service)", [
        ("Get-Printer-Attributes describes the printer", {
            let b = Bridge()
            let r = try b.call(getPrinterAttributes)
            expectEqual(r.code, 0x0000)
            let formats = r.find("document-format-supported")?.values.compactMap { $0.stringValue } ?? []
            expect(formats.contains("image/pwg-raster") && formats.contains("image/urf") && formats.contains("image/jpeg"))
            expectEqual(r.find("printer-state")?.values.first?.intValue, 3)
            expect(r.find("urf-supported") != nil)
            expect(r.find("media-col-database") == nil, "media-col-database is never part of \"all\"")
            let only = try b.call(getPrinterAttributes, operationAttributes([kw("requested-attributes", ["media-col-database"])]))
            expect(only.find("media-col-database") != nil && only.find("printer-state") == nil)
        }),
        ("RFC 8011 request checks", {
            let b = Bridge()
            expectEqual(try b.call(getPrinterAttributes, requestId: 0).code, 0x0400)
            let noCharset = [langA("attributes-natural-language", ["en"]), uriA("printer-uri", testPrinterURI)]
            expectEqual(try b.call(getPrinterAttributes, noCharset).code, 0x0400)
            let noURI = [charsetA("attributes-charset", ["utf-8"]), langA("attributes-natural-language", ["en"])]
            expectEqual(try b.call(getPrinterAttributes, noURI).code, 0x0400)
            let badCharset = [charsetA("attributes-charset", ["koi8-r"]), langA("attributes-natural-language", ["en"]), uriA("printer-uri", testPrinterURI)]
            expectEqual(try b.call(getPrinterAttributes, badCharset).code, 0x040D)
            expectEqual(try b.call(encodeIPP(major: 0, minor: 0, code: getPrinterAttributes, groups: [(Tag.operation, operationAttributes())])).code, 0x0503)
            expectEqual(try b.call(0x0010).code, 0x0501)
        }),
        ("Print-Job queues a PWG document in a private spool file", {
            let b = Bridge()
            let r = try b.call(printJob, operationAttributes([nm("job-name", ["bad\nname\u{1B}[31m"]),
                                                              mime("document-format", ["image/pwg-raster"])]), document: pwg)
            expectEqual(r.code, 0x0000)
            expectEqual(r.find("job-id")?.values.first?.intValue, 1)
            guard let job = b.queue.find(1) else { expect(false, "job not queued"); return }
            expectEqual(job.name, "bad name [31m")
            guard case .pwg(let url) = b.queue.with(job, { $0.payload }) else { expect(false, "no document"); return }
            let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
            expectEqual(mode, 0o600)
        }),
        ("unsupported or invalid documents are refused", {
            let b = Bridge()
            expectEqual(try b.call(printJob, operationAttributes([mime("document-format", ["application/pdf"])]), document: pwg).code, 0x040A)
            expectEqual(try b.call(printJob, operationAttributes([mime("document-format", ["application/octet-stream"])]),
                                   document: Array("not a raster".utf8)).code, 0x0411)
            expectEqual(try b.call(printJob, operationAttributes([kw("compression", "gzip")]), document: pwg).code, 0x040F)
            expectEqual(b.queue.activeCount, 0)
        }),
        ("documents over the size limit are refused and not kept", {
            let b = Bridge(maxDocumentBytes: 4096)
            expectEqual(try b.call(printJob, document: pwg).code, 0x0408)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: b.config.spoolDir.path)) ?? []
            expect(left.isEmpty, "left behind: \(left)")
        }),
        ("too many waiting jobs gives server-error-busy", {
            let b = Bridge(maxActiveJobs: 2)
            expectEqual(try b.call(printJob, document: pwg).code, 0x0000)
            expectEqual(try b.call(printJob, document: pwg).code, 0x0000)
            expectEqual(try b.call(printJob, document: pwg).code, 0x0507)
            expectEqual(try b.call(createJob).code, 0x0507)
        }),
        ("Create-Job, then Send-Document", {
            let b = Bridge()
            let created = try b.call(createJob)
            expectEqual(created.find("job-state")?.values.first?.intValue, 4)
            let id = created.find("job-id")?.values.first?.intValue ?? 0
            expectEqual(try b.call(sendDocument, operationAttributes([int("job-id", id)]), document: pwg).code, 0x0400)  // no last-document
            let sent = try b.call(sendDocument, operationAttributes([int("job-id", id), bool("last-document", true)]), document: pwg)
            expectEqual(sent.code, 0x0000)
            expectEqual(sent.find("job-state")?.values.first?.intValue, 3)
            expectEqual(try b.call(sendDocument, operationAttributes([int("job-id", id), bool("last-document", true)]), document: pwg).code, 0x0509)
        }),
        ("Cancel-Job and Get-Job-Attributes", {
            let b = Bridge()
            _ = try b.call(printJob, document: pwg)
            expectEqual(try b.call(cancelJob, operationAttributes([int("job-id", 1)])).code, 0x0000)
            expectEqual(try b.call(getJobAttributes, operationAttributes([int("job-id", 1)])).find("job-state")?.values.first?.intValue, 7)
            expectEqual(try b.call(cancelJob, operationAttributes([int("job-id", 1)])).code, 0x0404)
            expectEqual(try b.call(getJobAttributes, operationAttributes([int("job-id", 99)])).code, 0x0406)
        }),
        ("Validate-Job checks the format only", {
            let b = Bridge()
            expectEqual(try b.call(validateJob, operationAttributes([mime("document-format", ["image/urf"])])).code, 0x0000)
            expectEqual(try b.call(validateJob, operationAttributes([mime("document-format", ["text/plain"])])).code, 0x040A)
        }),
        ("Identify-Printer is rate-limited (each one is a Bluetooth connection)", {
            let b = Bridge()
            expectEqual(try b.call(identifyPrinter).code, 0x0000)
            expectEqual(try b.call(identifyPrinter).code, 0x0000)
            if case .identify? = b.queue.waitForWork(timeout: 0.2) {} else { expect(false, "first identify missing") }
            expect(b.queue.waitForWork(timeout: 0.1) == nil, "second identify should be dropped")
        }),
        ("HTTP: requests for other host names are refused", {
            let b = Bridge()
            expect(b.http("GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n").hasPrefix("HTTP/1.1 400"))
            expect(b.http("GET / HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 400"), "missing Host")
            let ok = b.http("GET / HTTP/1.1\r\nHost: localhost:8631\r\nConnection: close\r\n\r\n")
            expect(ok.hasPrefix("HTTP/1.1 200") && ok.contains("GD-88 bridge"))
        }),
        ("HTTP: bad lengths and header floods are refused without crashing", {
            let b = Bridge()
            expect(b.http("POST /ipp/print HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/ipp\r\nContent-Length: -5\r\n\r\n").hasPrefix("HTTP/1.1 400"))
            expect(b.http("POST /ipp/print HTTP/1.1\r\nHost: localhost\r\nContent-Length: 99999999999\r\n\r\n").hasPrefix("HTTP/1.1 400"))
            let flood = (0..<150).map { "X-\($0): y\r\n" }.joined()
            expect(b.http("GET / HTTP/1.1\r\nHost: localhost\r\n\(flood)\r\n").hasPrefix("HTTP/1.1 431"))
            expect(b.http("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nabc").hasPrefix("HTTP/1.1 400"))
        }),
        ("the status page escapes job names", {
            let b = Bridge()
            _ = try b.call(printJob, operationAttributes([nm("job-name", ["<script>alert(1)</script>"])]), document: pwg)
            let page = b.ipp.statusPage()
            expect(!page.contains("<script>") && page.contains("&lt;script&gt;"))
        }),
    ])
}
