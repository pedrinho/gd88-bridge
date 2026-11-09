// IPP Everywhere printer object (PWG 5100.14 subset) for the GD-88.
// Operations: Print-Job, Validate-Job, Cancel-Job, Get-Job-Attributes, Get-Jobs, Get-Printer-Attributes.
import Foundation

final class IPPService {
    let config: Config
    let queue: JobQueue
    let status: PrinterStatus
    private let started = Date()
    let uuid: String

    init(config: Config, queue: JobQueue, status: PrinterStatus) {
        self.config = config
        self.queue = queue
        self.status = status
        uuid = IPPService.loadOrCreateUUID(config.baseDir.appendingPathComponent("printer-uuid"))
    }

    var printerURI: String { "ipp://localhost:\(config.ippPort)/ipp/print" }
    private var upTime: Int { max(1, Int(Date().timeIntervalSince(started))) }
    private func upTime(at d: Date?) -> IPPValue {
        guard let d = d else { return .outOfBand(Tag.noValue) }
        return .integer(Int32(max(1, Int(d.timeIntervalSince(started)))))
    }

    private static func loadOrCreateUUID(_ file: URL) -> String {
        if let s = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let u = UUID().uuidString.lowercased()
        try? u.write(to: file, atomically: true, encoding: .utf8)
        return u
    }

    // MARK: request dispatch

    func handle(body: BodyReader) -> [UInt8] {
        let req: IPPMessage
        do {
            req = try IPPReader(read: { body.readExactly($0) }).message()
        } catch {
            var bad = IPPMessage()
            bad.major = 1; bad.minor = 1
            return response(bad, 0x0400, "malformed IPP request: \(error)")
        }
        guard req.major == 1 || req.major == 2 else {
            var r = req
            r.major = 1; r.minor = 1
            return response(r, 0x0503, "IPP version \(req.major).\(req.minor) not supported")
        }
        guard req.requestId >= 1 && req.requestId <= 0x7FFF_FFFF else {   // RFC 8011 §4.1.1
            return response(req, 0x0400, "request-id must be between 1 and 2^31-1")
        }
        if let bad = validate(req) { return bad }
        queue.expireIncoming(after: 60)
        switch req.code {
        case 0x0002: return printJob(req, body)
        case 0x0004: return validateJob(req)
        case 0x0005: return createJob(req)
        case 0x0006: return sendDocument(req, body)
        case 0x0008: return cancelJob(req)
        case 0x0009: return getJobAttributes(req)
        case 0x000A: return getJobs(req)
        case 0x000B: return getPrinterAttributes(req)
        case 0x0039: return cancelMyJobs(req)
        case 0x003B: return closeJob(req)
        case 0x003C: return identifyPrinter(req)
        default: return response(req, 0x0501, "operation 0x\(String(req.code, radix: 16)) not supported")
        }
    }

    static let operations = [0x0002, 0x0004, 0x0005, 0x0006, 0x0008, 0x0009, 0x000A, 0x000B, 0x0039, 0x003B, 0x003C]

    /// RFC 8011 §4.1.4 (charset and language come first) and §4.2 (target URI).
    private func validate(_ req: IPPMessage) -> [UInt8]? {
        guard let g = req.groups.first, g.tag == Tag.operation, g.attributes.count >= 2,
              g.attributes[0].name == "attributes-charset",
              g.attributes[1].name == "attributes-natural-language" else {
            return response(req, 0x0400, "attributes-charset and attributes-natural-language must be the first operation attributes")
        }
        let charset = g.attributes[0].values.first?.stringValue?.lowercased() ?? ""
        guard ["utf-8", "us-ascii"].contains(charset) else {
            return response(req, 0x040D, "charset \(charset) is not supported")
        }
        let hasPrinterURI = req.find("printer-uri", in: Tag.operation) != nil
        let jobOperations: Set<UInt16> = [0x0006, 0x0008, 0x0009, 0x003B]
        if jobOperations.contains(req.code) {
            let hasJobURI = req.find("job-uri", in: Tag.operation) != nil
            let hasJobId = req.find("job-id", in: Tag.operation) != nil
            if !hasJobURI && !(hasPrinterURI && hasJobId) {
                return response(req, 0x0400, "job-uri, or printer-uri and job-id, required")
            }
        } else if !hasPrinterURI {
            return response(req, 0x0400, "printer-uri required")
        }
        return nil
    }

    // MARK: icons (printer-icons)

    private lazy var icons: [String: [UInt8]] = {
        var d: [String: [UInt8]] = [:]
        for s in [48, 128, 512] { d["/icon-\(s).png"] = Array(makePrinterIcon(size: s)) }
        return d
    }()
    private let iconLock = NSLock()
    func icon(_ path: String) -> [UInt8]? {
        iconLock.lock(); defer { iconLock.unlock() }
        return icons[path]
    }
    private var iconURIs: [String] { [48, 128, 512].map { "http://localhost:\(config.ippPort)/icon-\($0).png" } }

    private func response(_ req: IPPMessage, _ statusCode: UInt16, _ message: String? = nil,
                          groups: [(UInt8, [IPPAttribute])] = []) -> [UInt8] {
        var w = IPPWriter()
        w.header(major: req.major, minor: req.minor, code: statusCode, requestId: req.requestId)
        w.group(Tag.operation)
        w.attribute(charsetA("attributes-charset", ["utf-8"]))
        w.attribute(langA("attributes-natural-language", ["en"]))
        if let m = message { w.attribute(txt("status-message", m)) }
        for (tag, attrs) in groups {
            w.group(tag)
            for a in attrs { w.attribute(a) }
        }
        w.end()
        return w.bytes
    }

    // MARK: jobs

    static let formats = ["application/octet-stream", "image/jpeg", "image/pwg-raster", "image/urf"]
    /// Apple Raster capabilities (AirPrint): version 1.4, 8-bit gray, copies, 203 dpi.
    static let urfSupported = ["V1.4", "W8", "CP1", "RS203"]

    private func checkFormat(_ req: IPPMessage) -> [UInt8]? {
        let format = req.find("document-format", in: Tag.operation)?.values.first?.stringValue ?? "application/octet-stream"
        if !IPPService.formats.contains(format) {
            return response(req, 0x040A, "document-format \(format) is not supported (send image/pwg-raster, image/urf or image/jpeg)",
                            groups: [(Tag.unsupportedGroup, [mime("document-format", [format])])])
        }
        if let c = req.find("compression", in: Tag.operation)?.values.first?.stringValue, c != "none" {
            return response(req, 0x040F, "compression \(c) is not supported",
                            groups: [(Tag.unsupportedGroup, [kw("compression", c)])])
        }
        return nil
    }

    private func validateJob(_ req: IPPMessage) -> [UInt8] {
        checkFormat(req) ?? response(req, 0x0000)
    }

    private enum Spooled { case document(JobPayload), empty, error([UInt8]) }

    /// Writes the request's document to the spool folder and turns it into something printable:
    /// PWG raster is used as-is, JPEG is rendered to raster first.
    private func spool(_ req: IPPMessage, _ body: BodyReader, id: Int) -> Spooled {
        let declared = req.find("document-format", in: Tag.operation)?.values.first?.stringValue ?? "application/octet-stream"
        let doc = config.spoolDir.appendingPathComponent("job-\(id).doc")
        makePrivateFile(doc)
        guard let fh = FileHandle(forWritingAtPath: doc.path) else { return .error(response(req, 0x0500, "cannot spool the job")) }
        var size = 0
        while let chunk = body.read(max: 256 * 1024) {
            size += chunk.count
            if size > config.maxDocumentBytes {
                try? fh.close()
                try? FileManager.default.removeItem(at: doc)
                body.abandon()                                   // stop reading; the connection is closed
                return .error(response(req, 0x0408, "document larger than \(config.maxDocumentBytes >> 20) MB"))
            }
            fh.write(Data(chunk))
        }
        try? fh.close()
        if body.failed {
            try? FileManager.default.removeItem(at: doc)
            return .error(response(req, 0x0400, "document data incomplete"))
        }
        if size == 0 { try? FileManager.default.removeItem(at: doc); return .empty }
        let actual = sniffFormat(doc)
        guard let format = actual, declared == "application/octet-stream" || declared == format else {
            try? FileManager.default.removeItem(at: doc)
            return .error(response(req, 0x0411, "document is not valid \(declared == "application/octet-stream" ? "PWG raster, Apple Raster or JPEG" : declared)"))
        }
        if format == "image/jpeg" {
            let ras = config.spoolDir.appendingPathComponent("job-\(id).ras")
            defer { try? FileManager.default.removeItem(at: doc) }
            do {
                try convertImageToRaster(doc, ras)
            } catch {
                try? FileManager.default.removeItem(at: ras)
                return .error(response(req, 0x0411, "cannot read the JPEG: \(error)"))
            }
            return .document(.pwg(ras))
        }
        let pwg = config.spoolDir.appendingPathComponent("job-\(id).pwg")
        try? FileManager.default.removeItem(at: pwg)
        do { try FileManager.default.moveItem(at: doc, to: pwg) } catch { return .error(response(req, 0x0500, "cannot spool the job")) }
        return .document(.pwg(pwg))
    }

    private func newJob(_ req: IPPMessage, id: Int, payload: JobPayload) -> Job {
        let copies = min(99, max(1, req.find("copies", in: Tag.job)?.values.first?.intValue ?? 1))
        var quality = req.find("print-quality", in: Tag.job)?.values.first?.intValue ?? 4
        if ![3, 4, 5].contains(quality) { quality = 4 }
        let name = clean(req.find("job-name", in: Tag.operation)?.values.first?.stringValue ?? "Untitled")
        return Job(id: id, payload: payload, name: name.isEmpty ? "Untitled" : name, user: requestingUser(req),
                   copies: copies, quality: quality, source: "ipp")
    }

    private func requestingUser(_ req: IPPMessage) -> String {
        clean(req.find("requesting-user-name", in: Tag.operation)?.values.first?.stringValue ?? "anonymous", max: 64)
    }

    /// server-error-busy when too many jobs are queued or printing (protects memory and disk).
    private func busy(_ req: IPPMessage) -> [UInt8]? {
        guard queue.activeCount >= config.maxActiveJobs else { return nil }
        return response(req, 0x0507, "too many jobs waiting (\(config.maxActiveJobs)); try again later")
    }

    private func printJob(_ req: IPPMessage, _ body: BodyReader) -> [UInt8] {
        if let err = checkFormat(req) ?? busy(req) { return err }
        let id = queue.makeId()
        switch spool(req, body, id: id) {
        case .error(let r): return r
        case .empty: return response(req, 0x0400, "Print-Job without document data")
        case .document(let payload):
            let job = newJob(req, id: id, payload: payload)
            queue.submit(job)
            return response(req, 0x0000, groups: [(Tag.job, jobAttributes(job, brief: true))])
        }
    }

    private func createJob(_ req: IPPMessage) -> [UInt8] {
        if let err = checkFormat(req) ?? busy(req) { return err }
        let job = newJob(req, id: queue.makeId(), payload: .none)
        queue.register(job)
        return response(req, 0x0000, groups: [(Tag.job, jobAttributes(job, brief: true))])
    }

    private func sendDocument(_ req: IPPMessage, _ body: BodyReader) -> [UInt8] {
        guard let id = jobId(req), let job = queue.find(id) else { return response(req, 0x0406, "job not found") }
        guard case .boolean? = req.find("last-document", in: Tag.operation)?.values.first else {
            return response(req, 0x0400, "last-document is required")
        }
        if let err = checkFormat(req) { return err }
        let (finished, hasDoc) = queue.with(job) { ($0.state.isFinished, $0.hasDocument) }
        if finished { return response(req, 0x0404, "job is already finished") }
        if hasDoc { return response(req, 0x0509, "this printer accepts one document per job") }
        switch spool(req, body, id: id) {
        case .error(let r):
            return r
        case .empty:
            // Allowed: an empty last document just closes the job.
            queue.finish(job, .completed, reasons: ["job-completed-successfully"], message: "no document")
        case .document(let payload):
            queue.attach(job, payload)
        }
        return response(req, 0x0000, groups: [(Tag.job, jobAttributes(job, brief: true))])
    }

    private func closeJob(_ req: IPPMessage) -> [UInt8] {
        guard let id = jobId(req), let job = queue.find(id) else { return response(req, 0x0406, "job not found") }
        let (finished, hasDoc) = queue.with(job) { ($0.state.isFinished, $0.hasDocument) }
        if finished { return response(req, 0x0404, "job is already finished") }
        if !hasDoc { queue.finish(job, .completed, reasons: ["job-completed-successfully"], message: "closed without a document") }
        return response(req, 0x0000)
    }

    private func cancelMyJobs(_ req: IPPMessage) -> [UInt8] {
        let user = requestingUser(req)
        let ids = req.find("job-ids", in: Tag.operation).map { Set($0.values.compactMap { $0.intValue }) }
        var canceled: [Int] = []
        for job in queue.all() {
            let (jid, owner, done) = queue.with(job) { ($0.id, $0.user, $0.state.isFinished) }
            if done || owner != user { continue }
            if let ids = ids, !ids.contains(jid) { continue }
            _ = queue.cancel(jid)
            canceled.append(jid)
        }
        return response(req, 0x0000, canceled.isEmpty ? "no jobs to cancel" : nil)
    }

    private func identifyPrinter(_ req: IPPMessage) -> [UInt8] {
        let actions = req.find("identify-actions", in: Tag.operation)?.values.compactMap { $0.stringValue } ?? ["flash"]
        if let bad = actions.first(where: { $0 != "flash" }) {
            return response(req, 0x040B, "identify-actions \(bad) not supported",
                            groups: [(Tag.unsupportedGroup, [kw("identify-actions", bad)])])
        }
        identifyLock.lock()
        let now = Date()
        let tooSoon = lastIdentify.map { now.timeIntervalSince($0) < config.identifyInterval } ?? false
        if !tooSoon { lastIdentify = now }
        identifyLock.unlock()
        if !tooSoon { queue.requestIdentify() }      // rate-limited: each identify is a Bluetooth connection
        return response(req, 0x0000)
    }
    private let identifyLock = NSLock()
    private var lastIdentify: Date?

    private func jobId(_ req: IPPMessage) -> Int? {
        if let i = req.find("job-id", in: Tag.operation)?.values.first?.intValue { return i }
        if let u = req.find("job-uri", in: Tag.operation)?.values.first?.stringValue { return Int(u.split(separator: "/").last ?? "") }
        return nil
    }

    private func getJobAttributes(_ req: IPPMessage) -> [UInt8] {
        guard let id = jobId(req), let job = queue.find(id) else { return response(req, 0x0406, "job not found") }
        return response(req, 0x0000, groups: [(Tag.job, jobAttributes(job, brief: false))])
    }

    private func cancelJob(_ req: IPPMessage) -> [UInt8] {
        guard let id = jobId(req) else { return response(req, 0x0400, "missing job-id") }
        switch queue.cancel(id) {
        case .notFound: return response(req, 0x0406, "job not found")
        case .notPossible: return response(req, 0x0404, "job already finished")
        case .canceled, .stopping: return response(req, 0x0000)
        }
    }

    private func getJobs(_ req: IPPMessage) -> [UInt8] {
        let which = req.find("which-jobs", in: Tag.operation)?.values.first?.stringValue ?? "not-completed"
        guard ["completed", "not-completed", "all"].contains(which) else {
            return response(req, 0x040B, "which-jobs \(which) not supported",
                            groups: [(Tag.unsupportedGroup, [kw("which-jobs", which)])])
        }
        let limit = req.find("limit", in: Tag.operation)?.values.first?.intValue ?? Int.max
        let requested = Set(req.find("requested-attributes", in: Tag.operation)?.values.compactMap { $0.stringValue } ?? [])
        let full = !requested.isEmpty && !requested.isSubset(of: ["job-id", "job-uri"])
        let ids = req.find("job-ids", in: Tag.operation).map { Set($0.values.compactMap { $0.intValue }) }
        let myJobs = req.find("my-jobs", in: Tag.operation)?.values.first.flatMap { v -> Bool? in
            if case .boolean(let b) = v { return b }
            return nil
        } ?? false
        let user = requestingUser(req)
        var jobs = queue.all().filter { job in
            let (id, owner, done) = queue.with(job) { ($0.id, $0.user, $0.state.isFinished) }
            if let ids = ids { return ids.contains(id) }          // job-ids overrides which-jobs
            if myJobs && owner != user { return false }
            return which == "all" || (which == "completed") == done
        }
        if which == "completed" { jobs.reverse() }   // newest first
        let groups = jobs.prefix(max(0, limit)).map { job -> (UInt8, [IPPAttribute]) in
            (Tag.job, full ? jobAttributes(job, brief: false) : [int("job-id", job.id), uriA("job-uri", "\(printerURI)/\(job.id)")])
        }
        return response(req, 0x0000, groups: groups)
    }

    private func jobAttributes(_ job: Job, brief: Bool) -> [IPPAttribute] {
        queue.with(job) { j in
            var a: [IPPAttribute] = [
                int("job-id", j.id),
                uriA("job-uri", "\(printerURI)/\(j.id)"),
                en("job-state", Int(j.state.rawValue)),
                kw("job-state-reasons", j.reasons),
                txt("job-state-message", j.message),
            ]
            if brief { return a }
            a += [
                uriA("job-printer-uri", printerURI),
                nm("job-name", j.name),
                nm("job-originating-user-name", j.user),
                int("job-impressions-completed", j.impressions),
                int("job-media-sheets-completed", j.impressions),
                int("copies", j.copies),
                en("print-quality", j.quality),
                int("number-of-documents", 1),
                int("job-k-octets", j.kOctets),
                IPPAttribute("time-at-creation", [upTime(at: j.createdAt)]),
                IPPAttribute("time-at-processing", [upTime(at: j.processingAt)]),
                IPPAttribute("time-at-completed", [upTime(at: j.completedAt)]),
                int("job-printer-up-time", upTime),
            ]
            return a
        }
    }

    // MARK: printer

    private func getPrinterAttributes(_ req: IPPMessage) -> [UInt8] {
        let requested = req.find("requested-attributes", in: Tag.operation)?.values.compactMap { $0.stringValue } ?? ["all"]
        let wanted = Set(requested)
        // Refresh the printer's status in the background now and then (never on this request's path).
        let snap = status.snapshot()
        if !config.dryRun && queue.activeCount == 0 && (snap.lastRefresh.map { Date().timeIntervalSince($0) > 120 } ?? true) {
            status.markRefreshed()
            queue.requestRefresh()
        }
        let all = printerAttributes(snap)
        let groupsAsked = !wanted.isDisjoint(with: ["all", "printer-description", "job-template"])
        let out = all.filter { a in
            if a.name == "media-col-database" { return wanted.contains(a.name) }   // never part of "all"
            return groupsAsked || wanted.contains(a.name)
        }
        return response(req, 0x0000, groups: [(Tag.printer, out)])
    }

    private func mediaCol(_ y: IPPValue) -> [IPPAttribute] {
        [
            IPPAttribute("media-size", [.collection([IPPAttribute("x-dimension", [.integer(21000)]),
                                                     IPPAttribute("y-dimension", [y])])]),
            int("media-bottom-margin", 0), int("media-left-margin", 0),
            int("media-right-margin", 0), int("media-top-margin", 0),
            kw("media-source", "main"),
            kw("media-type", "continuous"),
        ]
    }

    private func printerAttributes(_ s: StatusSnapshot) -> [IPPAttribute] {
        let a4 = mediaCol(.integer(29700))
        let roll = mediaCol(.range(2000, 100000))          // 20 mm ... 1 m on the 210 mm roll
        var model = "HZTZ GD-88"
        if !s.info.model.isEmpty { model += " (\(s.info.model.replacingOccurrences(of: "_", with: " ")))" }
        var attrs: [IPPAttribute] = [
            charsetA("charset-configured", ["utf-8"]),
            charsetA("charset-supported", ["utf-8"]),
            bool("color-supported", false),
            kw("compression-supported", ["none"]),
            en("finishings-default", 3),                       // 3 = none
            enums("finishings-supported", [3]),
            kw("identify-actions-default", ["flash"]),         // connecting turns the light blue
            kw("identify-actions-supported", ["flash"]),
            bool("job-ids-supported", true),
            kw("multiple-operation-time-out-action", "abort-job"),
            kw("overrides-supported", ["document-number", "pages"]),
            bool("preferred-attributes-supported", false),
            kw("print-content-optimize-default", "auto"),
            kw("print-content-optimize-supported", ["auto"]),
            kw("print-rendering-intent-default", "auto"),
            kw("print-rendering-intent-supported", ["auto"]),
            IPPAttribute("printer-config-change-date-time", [.dateTime(started)]),
            int("printer-config-change-time", 1),
            kw("printer-get-attributes-supported", ["document-format"]),
            uriA("printer-icons", iconURIs),
            IPPAttribute("printer-state-change-date-time", [.dateTime(s.changedAt)]),
            uriA("printer-supply-info-uri", "http://localhost:\(config.ippPort)/"),
            int("copies-default", 1),
            rangeA("copies-supported", 1, 99),
            mime("document-format-default", ["application/octet-stream"]),
            mime("document-format-supported", IPPService.formats),
            langA("generated-natural-language-supported", ["en"]),
            langA("natural-language-configured", ["en"]),
            kw("ipp-features-supported", ["ipp-everywhere"]),
            kw("ipp-versions-supported", ["1.1", "2.0"]),
            kw("job-creation-attributes-supported",
               ["copies", "media", "media-col", "orientation-requested", "print-color-mode", "print-quality",
                "print-scaling", "printer-resolution", "sides"]),
            ints("media-bottom-margin-supported", [0]),
            ints("media-left-margin-supported", [0]),
            ints("media-right-margin-supported", [0]),
            ints("media-top-margin-supported", [0]),
            coll("media-col-database", [a4, roll]),
            coll("media-col-default", [a4]),
            coll("media-col-ready", [a4]),
            kw("media-col-supported", ["media-bottom-margin", "media-left-margin", "media-right-margin",
                                       "media-size", "media-source", "media-top-margin", "media-type"]),
            kw("media-default", "iso_a4_210x297mm"),
            kw("media-ready", ["iso_a4_210x297mm"]),
            coll("media-size-supported", [
                [IPPAttribute("x-dimension", [.integer(21000)]), IPPAttribute("y-dimension", [.integer(29700)])],
                [IPPAttribute("x-dimension", [.integer(21000)]), IPPAttribute("y-dimension", [.range(2000, 100000)])],
            ]),
            kw("media-source-supported", ["main"]),
            kw("media-supported", ["iso_a4_210x297mm", "custom_min_210x20mm", "custom_max_210x1000mm"]),
            kw("media-type-supported", ["continuous"]),
            kw("multiple-document-handling-supported",
               ["separate-documents-uncollated-copies", "separate-documents-collated-copies"]),
            bool("multiple-document-jobs-supported", false),
            int("multiple-operation-time-out", 60),
            enums("operations-supported", IPPService.operations),
            en("orientation-requested-default", 3),
            enums("orientation-requested-supported", [3]),
            kw("output-bin-default", "face-up"),
            kw("output-bin-supported", ["face-up"]),
            int("pages-per-minute", 2),
            kw("pdl-override-supported", "attempted"),
            kw("print-color-mode-default", "monochrome"),
            kw("print-color-mode-supported", ["monochrome"]),
            en("print-quality-default", 4),
            enums("print-quality-supported", [3, 4, 5]),
            kw("print-scaling-default", "auto"),
            kw("print-scaling-supported", ["auto", "auto-fit", "fill", "fit", "none"]),
            txt("printer-device-id", "MFG:HZTZ;MDL:GD-88;CMD:PWGRaster;CLS:PRINTER;"),
            oob("printer-geo-location", Tag.unknown),
            txt("printer-info", "GD-88 thermal printer (Bluetooth)"),
            bool("printer-is-accepting-jobs", true),
            kw("printer-kind", ["document", "receipt"]),
            txt("printer-location", "Bluetooth"),
            txt("printer-make-and-model", model),
            uriA("printer-more-info", "http://localhost:\(config.ippPort)/"),
            nm("printer-name", "GD-88"),
            txt("printer-organization", ""),
            txt("printer-organizational-unit", ""),
            dpi("printer-resolution-default", 203, 203),
            dpi("printer-resolution-supported", 203, 203),
            en("printer-state", Int(s.state)),
            IPPAttribute("printer-state-change-time", [upTime(at: s.changedAt)]),
            txt("printer-state-message", s.message),
            kw("printer-state-reasons", s.reasons),
            int("printer-up-time", upTime),
            IPPAttribute("printer-current-time", [.dateTime(Date())]),
            uriA("printer-uri-supported", [printerURI]),
            uriA("printer-uuid", "urn:uuid:\(uuid)"),
            dpi("pwg-raster-document-resolution-supported", 203, 203),
            kw("pwg-raster-document-sheet-back", "normal"),
            kw("pwg-raster-document-type-supported", ["sgray_8"]),
            kw("urf-supported", IPPService.urfSupported),
            int("queued-job-count", queue.activeCount),
            kw("sides-default", "one-sided"),
            kw("sides-supported", ["one-sided"]),
            kw("uri-authentication-supported", ["none"]),
            kw("uri-security-supported", ["none"]),
            kw("which-jobs-supported", ["completed", "not-completed"]),
            // Battery as a supply: CUPS marker-* attributes and the PWG 5100.13 printer-supply equivalent.
            nm("marker-colors", ["none"]),
            ints("marker-high-levels", [100]),
            ints("marker-levels", [s.battery ?? -1]),
            ints("marker-low-levels", [15]),
            nm("marker-names", ["Battery"]),
            kw("marker-types", ["other"]),
            IPPAttribute("printer-supply", [.octets(Array(
                "index=1;class=supplyThatIsConsumed;type=other;unit=percent;maxcapacity=100;level=\(s.battery ?? -2);".utf8))]),
            txts("printer-supply-description", ["Battery"]),
        ]
        if !s.info.firmware.isEmpty {
            attrs.append(nm("printer-firmware-name", ["GD-88"]))
            attrs.append(txts("printer-firmware-string-version", [s.info.firmware]))
        }
        return attrs
    }

    // MARK: status page (GET /)

    func statusPage() -> String {
        let s = status.snapshot()
        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let state = [3: "idle", 4: "printing", 5: "stopped"][Int(s.state)] ?? "?"
        var rows = ""
        for job in queue.all().suffix(10).reversed() {
            let (id, name, st, msg, src) = queue.with(job) { ($0.id, $0.name, $0.state, $0.message, $0.source) }
            rows += "<tr><td>\(id)</td><td>\(esc(name))</td><td>\(src)</td><td>\(st)</td><td>\(esc(msg))</td></tr>"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>GD-88 bridge</title><style>body{font:14px -apple-system,sans-serif;margin:24px;max-width:760px}
        td,th{padding:4px 10px;text-align:left;border-bottom:1px solid #8884}</style></head><body>
        <h1>GD-88 bridge</h1>
        <p><b>State:</b> \(state) \(s.message.isEmpty ? "" : "— " + esc(s.message))<br>
        <b>Battery:</b> \(s.battery.map { "\($0)%" } ?? "unknown")<br>
        <b>Printer:</b> \(esc(s.info.model.isEmpty ? "not queried yet" : "\(s.info.model) \(s.info.firmware)"))<br>
        <b>IPP:</b> \(printerURI)\(config.dryRun ? " <b>(dry run)</b>" : "")</p>
        <table><tr><th>Job</th><th>Name</th><th>From</th><th>State</th><th>Message</th></tr>\(rows)</table>
        </body></html>
        """
    }
}
