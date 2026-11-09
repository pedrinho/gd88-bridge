// The one and only owner of the Bluetooth link to the GD-88 (RFCOMM serial channel via IOBluetooth).
// Runs on the main thread, whose run loop delivers IOBluetooth callbacks.
//
// Never sent (from the PeriPage protocol docs): 10 FF E0/EE AA AA (maintenance mode, writes flash),
// 10 FF 20 F4 (writes serial), 10 FF 70 F1 00 (can corrupt prints), 10 FF 12 (auto-off), 10 FF 10 01 (speed).
import Foundation
import IOBluetooth

/// Bytes from the printer are a mix of three things:
///   "FF xx"  an event the printer pushes on its own (FF 02 lid opened, FF 05 lid closed, FF 01 no paper)
///   "AA"     its acknowledgement of the end-of-job command
///   other    the reply to the last query (status, battery, text)
/// 0xFF and 0xAA never occur in replies: status uses bits 0-4, battery is <= 100, text is ASCII.
enum PrinterStream {
    /// Takes everything it can classify out of `rx`; a lone trailing 0xFF stays until its second byte arrives.
    static func split(_ rx: inout [UInt8]) -> (replies: [UInt8], events: [UInt8], acks: Int) {
        var replies: [UInt8] = [], events: [UInt8] = [], acks = 0
        var i = 0
        while i < rx.count {
            if rx[i] == 0xFF {
                if i + 1 >= rx.count { break }
                events.append(rx[i + 1])
                i += 2
            } else if rx[i] == 0xAA {
                acks += 1
                i += 1
            } else {
                replies.append(rx[i])
                i += 1
            }
        }
        rx.removeFirst(i)
        return (replies, events, acks)
    }
}

final class BTLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private(set) var address: String?
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private(set) var mtu = 127
    private var rx: [UInt8] = []
    private var replies: [UInt8] = []
    private var closedByRemote = false
    private var sdpDone = false
    private var inflight = 0
    private var writeError: IOReturn = kIOReturnSuccess
    private var buffers: [Int: UnsafeMutableRawPointer] = [:]
    private var nextRef = 1
    private(set) var lastProgress = Date()
    var onEvent: ((UInt8) -> Void)?
    private let debug = ProcessInfo.processInfo.environment["GD88_DEBUG"] != nil
    private var lastClose: Date?
    /// Count of 0xAA bytes: the printer's acknowledgement of the end-of-job command (10 FF F1 45).
    /// 0xAA never occurs in a query reply (status uses bits 0-4, battery is <= 100, text is ASCII).
    private(set) var jobAcks = 0

    init(address: String?) { self.address = address }

    var isOpen: Bool { channel != nil && !closedByRemote }
    var healthy: Bool { isOpen && writeError == kIOReturnSuccess }

    /// One connection attempt. Returns nil on success, otherwise a reason.
    func open() -> String? {
        close()
        if address == nil, let found = pairedPrinterAddress() {
            address = found
            log("printer found: \(found)")
        }
        guard let addr = address, let dev = IOBluetoothDevice(addressString: addr) else {
            return "no paired GD-88/PeriPage printer (pair it in System Settings › Bluetooth)"
        }
        // Reconnecting right after a disconnect races with the old link shutting down
        // (the printer then drops the new channel), so keep at least 2 s between them.
        if let t = lastClose, Date().timeIntervalSince(t) < 2 { spin(2 - Date().timeIntervalSince(t)) }
        device = dev
        let rc = dev.openConnection()
        guard rc == kIOReturnSuccess else { return "printer not reachable (\(hexCode(rc)))" }
        guard let ch = serialChannelID(dev) else { dev.closeConnection(); return "printer has no serial-port service" }
        rx.removeAll(); replies.removeAll()
        closedByRemote = false; inflight = 0; writeError = kIOReturnSuccess
        var chan: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelSync(&chan, withChannelID: ch, delegate: self)
        guard r == kIOReturnSuccess, let c = chan else {
            dev.closeConnection()
            return "could not open serial channel \(ch) (\(hexCode(r)))"
        }
        channel = c
        mtu = Int(c.getMTU())
        lastProgress = Date()
        spin(0.3)                 // give the printer a moment before the first query
        if debug { log("debug: connected, RFCOMM channel \(ch), MTU \(mtu)") }
        return nil
    }

    func close() {
        if channel != nil && !closedByRemote { spin(10) { inflight == 0 || !isOpen } }
        // Forget the channel first: IOBluetooth reports this close later through the run loop,
        // and that callback must not be mistaken for the next connection closing.
        let c = channel
        channel = nil
        c?.close()
        if device != nil {
            device?.closeConnection()
            lastClose = Date()
        }
        device = nil
        for (_, p) in buffers { p.deallocate() }
        buffers.removeAll()
        inflight = 0
    }

    private func serialChannelID(_ dev: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        func find() -> BluetoothRFCOMMChannelID? {
            for case let rec as IOBluetoothSDPServiceRecord in (dev.services ?? []) {
                var ch: BluetoothRFCOMMChannelID = 0
                if rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess { return ch }
            }
            return nil
        }
        if let ch = find() { return ch }
        sdpDone = false
        if dev.performSDPQuery(self) == kIOReturnSuccess { spin(10) { sdpDone } }
        return find()
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { sdpDone = true }

    // MARK: incoming data: "FF xx" pairs are printer events, everything else is a query reply

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
        guard ch === channel else { return }          // late data from an earlier connection
        rx.append(contentsOf: UnsafeRawBufferPointer(start: ptr, count: length))
        if debug { log("debug: <- \(hexBytes(UnsafeRawBufferPointer(start: ptr, count: length)))") }
        let parts = PrinterStream.split(&rx)
        replies += parts.replies
        jobAcks += parts.acks
        for e in parts.events { onEvent?(e) }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        guard ch === channel else { return }          // our own close of an earlier channel
        log("printer closed the Bluetooth channel")
        closedByRemote = true
    }

    func rfcommChannelWriteComplete(_ ch: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        buffers.removeValue(forKey: Int(bitPattern: refcon))?.deallocate()
        guard ch === channel else { return }
        inflight = max(0, inflight - 1)
        if error != kIOReturnSuccess { writeError = error } else { lastProgress = Date() }
    }

    // MARK: sending

    /// Sends `data` as MTU-sized async writes with at most `window` in flight. While the window is
    /// full the run loop keeps going (events still arrive) and `whileWaiting` is called; it returns
    /// false to give up.
    func send(_ data: Data, window: Int = 8, whileWaiting: () -> Bool) -> Bool {
        var off = 0
        while off < data.count {
            while inflight >= window {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                if !healthy || !whileWaiting() { return false }
            }
            guard let c = channel, healthy else { return false }
            let n = min(mtu, data.count - off)
            let p = UnsafeMutableRawPointer.allocate(byteCount: n, alignment: 1)
            data.withUnsafeBytes { src in p.copyMemory(from: src.baseAddress! + off, byteCount: n) }
            let key = nextRef
            nextRef += 1
            let rc = c.writeAsync(p, length: UInt16(n), refcon: UnsafeMutableRawPointer(bitPattern: key))
            if rc != kIOReturnSuccess {
                p.deallocate()
                writeError = rc
                log("Bluetooth write failed (\(hexCode(rc)))")
                return false
            }
            buffers[key] = p
            inflight += 1
            off += n
        }
        return true
    }

    func waitForWrites(whileWaiting: () -> Bool) -> Bool {
        while inflight > 0 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if !healthy || !whileWaiting() { return false }
        }
        return true
    }

    /// Sends a query and waits for exactly `expect` reply bytes.
    func query(_ cmd: [UInt8], expect: Int, timeout: TimeInterval = 1.5) -> [UInt8]? {
        spin(0.05)              // late replies to earlier queries arrive here and are dropped
        replies.removeAll()
        if debug { log("debug: -> \(hexBytes(cmd))") }
        guard send(Data(cmd), whileWaiting: { true }), waitForWrites(whileWaiting: { true }) else {
            if debug { log("debug: query not sent (link healthy: \(healthy))") }
            return nil
        }
        spin(timeout) { replies.count >= expect || !healthy }
        guard replies.count >= expect else {
            if debug { log("debug: no reply within \(timeout)s (link healthy: \(healthy))") }
            return nil
        }
        let r = Array(replies.prefix(expect))
        replies.removeAll()
        return r
    }

    /// Sends a query whose reply is ASCII text of unknown length.
    func queryText(_ cmd: [UInt8], timeout: TimeInterval = 1.5) -> String? {
        spin(0.05)
        replies.removeAll()
        guard send(Data(cmd), whileWaiting: { true }), waitForWrites(whileWaiting: { true }) else { return nil }
        let end = Date().addingTimeInterval(timeout)
        var count = 0
        var changed = Date()
        while Date() < end && healthy {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if replies.count != count { count = replies.count; changed = Date() }
            if count > 0 && Date().timeIntervalSince(changed) > 0.15 { break }
        }
        guard !replies.isEmpty else { return nil }
        let text = String(decoding: replies.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        replies.removeAll()
        return text
    }
}

final class PrinterWorker {
    let config: Config
    let queue: JobQueue
    let status: PrinterStatus
    private let link: BTLink
    private var eventSeen = false
    private var paperOutSinceLidOpened = false
    private let beatLock = NSLock()
    private var heartbeat = Date()
    private var watchdog: DispatchSourceTimer?

    init(config: Config, queue: JobQueue, status: PrinterStatus) {
        self.config = config
        self.queue = queue
        self.status = status
        link = BTLink(address: config.printerAddress)
        link.onEvent = { [unowned self] code in self.handleEvent(code) }
    }

    func run() -> Never {
        startWatchdog()
        while true {
            beat()
            autoreleasepool {
                switch queue.waitForWork(timeout: 5) {
                case .job(let job)?: process(job)
                case .refresh?: refresh()
                case .identify?: identify()
                case nil: break
                }
            }
        }
    }

    // MARK: watchdog: a Bluetooth call that hangs must never wedge printing

    private func beat() { beatLock.lock(); heartbeat = Date(); beatLock.unlock() }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [unowned self] in
            beatLock.lock()
            let silent = Date().timeIntervalSince(heartbeat)
            beatLock.unlock()
            if silent > 180 {
                log("ERROR printer worker unresponsive for \(Int(silent))s; exiting so launchd restarts the bridge")
                exit(1)
            }
        }
        t.resume()
        watchdog = t
    }

    // MARK: printer events and queries

    private func handleEvent(_ code: UInt8) {
        eventSeen = true
        var s = status.currentStatus() ?? 0
        switch code {
        case 0x02:
            paperOutSinceLidOpened = false
            s |= StatusBits.lidOpen | StatusBits.noPaper
            log("printer: lid opened")
        case 0x01:
            paperOutSinceLidOpened = true
            s |= StatusBits.noPaper
            log("printer: no paper")
        case 0x05:
            s &= ~StatusBits.lidOpen
            if !paperOutSinceLidOpened { s &= ~StatusBits.noPaper }
            log("printer: lid closed")
        default:
            log("printer: event ff \(String(format: "%02x", code))")
            return
        }
        status.setStatus(s)          // provisional until the next status query
    }

    @discardableResult
    private func readStatus(timeout: TimeInterval = 0.8) -> UInt8? {
        guard let r = link.query([0x10, 0xFF, 0x40], expect: 1, timeout: timeout) else { return nil }
        status.setStatus(r[0])
        return r[0]
    }

    private func readBattery() {
        if let r = link.query([0x10, 0xFF, 0x50, 0xF1], expect: 2) { status.addBattery(Int(r[0]) << 8 | Int(r[1])) }
    }

    private func readInfoIfNeeded() {
        guard status.getInfo().isEmpty else { return }
        var i = PrinterInfo()
        i.model = link.queryText([0x10, 0xFF, 0x20, 0xF0]) ?? ""
        i.firmware = link.queryText([0x10, 0xFF, 0x20, 0xF1]) ?? ""
        i.serial = link.queryText([0x10, 0xFF, 0x20, 0xF2]) ?? ""
        i.hardware = link.queryText([0x10, 0xFF, 0x30, 0x10]) ?? ""
        i.name = link.queryText([0x10, 0xFF, 0x30, 0x11]) ?? ""
        status.setInfo(i)
        log("printer: \(i.model) firmware \(i.firmware) hardware \(i.hardware) serial \(i.serial) name \(i.name)")
    }

    /// Background status refresh requested by the IPP side (rate-limited there).
    private func refresh() {
        status.markRefreshed()
        guard !config.dryRun else { return }
        if let err = link.open() {
            log("status refresh: \(err)")
            return
        }
        readInfoIfNeeded()
        readBattery()
        readStatus()
        link.close()
        let s = status.snapshot()
        log("status refresh: \(s.reasons.joined(separator: ",")) battery \(s.battery.map { "\($0)%" } ?? "?")")
    }

    /// Identify-Printer ("flash"): connecting turns the printer's light blue for a few seconds.
    private func identify() {
        log("identify: connecting for 3 s so the printer's light flashes blue")
        guard !config.dryRun else { return }
        if let err = link.open() { log("identify: \(err)"); return }
        spin(3)
        link.close()
    }

    // MARK: jobs

    private enum Ready { case ready, canceled, timedOut(String) }
    private enum Sent { case done(Int), canceled(Int), failed(String) }

    private func cancelRequested(_ job: Job) -> Bool { queue.with(job) { $0.cancelRequested } }

    private func process(_ job: Job) {
        queue.with(job) {
            $0.state = .processing
            $0.processingAt = Date()
            $0.reasons = ["job-printing"]
        }
        status.setJobActive(true)
        defer {
            status.setJobActive(false)
            status.setConnectProblem(nil)
        }
        if config.dryRun { dryRun(job); return }

        let deadline = Date().addingTimeInterval(30 * 60)
        switch waitUntilReady(job, deadline: deadline) {
        case .canceled:
            link.close()
            queue.finish(job, .canceled, reasons: ["job-canceled-by-user"])
            return
        case .timedOut(let why):
            link.close()
            queue.finish(job, .aborted, reasons: ["aborted-by-system"], message: why)
            return
        case .ready:
            break
        }

        queue.with(job) { $0.state = .processing; $0.reasons = ["job-printing"]; $0.message = "" }
        let started = Date()
        let acksBefore = link.jobAcks
        let result = transmit(job, deadline: deadline)
        if link.healthy {
            // The printer answers the end-of-job command with 0xAA once it has taken the whole job.
            spin(30) { link.jobAcks > acksBefore || !link.healthy }
            if link.jobAcks == acksBefore { log("job \(job.id): no end-of-job acknowledgement from the printer") }
            readStatus()
            readBattery()
        }
        link.close()
        let secs = String(format: "%.1fs", Date().timeIntervalSince(started))
        switch result {
        case .done(let pages):
            queue.with(job) { $0.impressions = pages }
            queue.finish(job, .completed, reasons: ["job-completed-successfully"], message: "printed in \(secs)")
        case .canceled(let pages):
            queue.with(job) { $0.impressions = pages }
            queue.finish(job, .canceled, reasons: ["job-canceled-by-user"])
        case .failed(let why):
            queue.finish(job, .aborted, reasons: ["aborted-by-system"], message: why)
        }
    }

    /// Connects (retrying) and holds the job until the status byte shows no blocking condition.
    private func waitUntilReady(_ job: Job, deadline: Date) -> Ready {
        var connectedAt: Date?
        var announced = false
        while true {
            beat()
            if cancelRequested(job) { return .canceled }
            if Date() > deadline { return .timedOut("printer did not become ready within 30 minutes") }
            if !link.isOpen {
                if let err = link.open() {
                    status.setConnectProblem("Printer off or out of range")
                    queue.with(job) { $0.message = "Waiting for the printer (off or out of range)" }
                    log("job \(job.id): \(err); retrying")
                    if !pause(5, job) { return .canceled }
                    continue
                }
                status.setConnectProblem(nil)
                connectedAt = Date()
                readInfoIfNeeded()
                readBattery()
            }
            eventSeen = false
            guard let s = readStatus() ?? readStatus() else {     // one retry before reconnecting
                log("job \(job.id): no status reply; reconnecting")
                link.close()
                continue
            }
            if s & StatusBits.blocking == 0 { return .ready }
            let snap = status.snapshot()
            queue.with(job) { $0.state = .stopped; $0.reasons = ["printer-stopped"]; $0.message = snap.message }
            if !announced { log("job \(job.id) held: \(snap.message)"); announced = true }
            if let t = connectedAt, Date().timeIntervalSince(t) > 120 {
                link.close()                      // don't keep the printer busy; look again in a minute
                if !pause(60, job) { return .canceled }
                continue
            }
            spin(2) { eventSeen || cancelRequested(job) }   // lid closed etc. wakes us at once
        }
    }

    /// Sleeps while disconnected, checking for cancel. Returns false if the job was canceled.
    private func pause(_ seconds: TimeInterval, _ job: Job) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            beat()
            if cancelRequested(job) { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return true
    }

    private func transmit(_ job: Job, deadline: Date) -> Sent {
        var stalledSince: Date?
        let whileWaiting: () -> Bool = { [unowned self] in
            beat()
            if Date().timeIntervalSince(link.lastProgress) > 20 {
                let snap = status.snapshot()
                if stalledSince == nil {
                    stalledSince = Date()
                    log("job \(job.id): printer stopped taking data (\(snap.message.isEmpty ? "no reason reported" : snap.message))")
                }
                queue.with(job) {
                    $0.state = .stopped
                    $0.reasons = ["printer-stopped"]
                    $0.message = snap.message.isEmpty ? "Printer paused" : snap.message
                }
                if Date() > deadline { return false }
            } else if stalledSince != nil {
                stalledSince = nil
                log("job \(job.id): printer resumed")
                queue.with(job) { $0.state = .processing; $0.reasons = ["job-printing"]; $0.message = "" }
            }
            return true
        }
        switch queue.with(job, { $0.payload }) {
        case .none:
            return .done(0)
        case .escpos(let data):
            var off = 0
            while off < data.count {
                let n = min(4096, data.count - off)
                guard link.send(data.subdata(in: off..<off + n), whileWaiting: whileWaiting) else {
                    return .failed("Bluetooth connection lost after \(off) bytes")
                }
                off += n
            }
            return link.waitForWrites(whileWaiting: whileWaiting) ? .done(1) : .failed("Bluetooth connection lost")
        case .pwg(let url):
            do {
                let r = try convertRaster(
                    url: url, copies: job.copies, quality: job.quality, trim: true,
                    shouldStop: { [unowned self] in cancelRequested(job) },
                    emit: { [unowned self] block in link.send(block, whileWaiting: whileWaiting) },
                    pageDone: { [unowned self] n in queue.with(job) { $0.impressions = n } })
                if r.failed { return .failed("Bluetooth connection lost") }
                guard link.waitForWrites(whileWaiting: whileWaiting) else { return .failed("Bluetooth connection lost") }
                return r.stopped ? .canceled(r.pages) : .done(r.pages)
            } catch {
                return .failed("bad print data: \(error)")
            }
        }
    }

    /// --dry-run: convert as usual but write the printer bytes to a file instead of Bluetooth.
    private func dryRun(_ job: Job) {
        let out = config.spoolDir.appendingPathComponent("dryrun-\(job.id).bin")
        makePrivateFile(out)
        guard let fh = try? FileHandle(forWritingTo: out) else {
            queue.finish(job, .aborted, reasons: ["aborted-by-system"], message: "cannot write \(out.path)")
            return
        }
        defer { try? fh.close() }
        var pages = 1
        switch queue.with(job, { $0.payload }) {
        case .none:
            pages = 0
        case .escpos(let d):
            fh.write(d)
        case .pwg(let url):
            do {
                let r = try convertRaster(url: url, copies: job.copies, quality: job.quality, trim: true,
                                          shouldStop: { [unowned self] in cancelRequested(job) },
                                          emit: { fh.write($0); return true })
                pages = r.pages
                if r.stopped {
                    queue.with(job) { $0.impressions = pages }
                    queue.finish(job, .canceled, reasons: ["job-canceled-by-user"], message: "dry run: canceled after \(pages) page(s)")
                    return
                }
                if config.keepSpool { try? FileManager.default.copyItem(at: url, to: config.spoolDir.appendingPathComponent("dryrun-\(job.id).pwg")) }
            } catch {
                queue.finish(job, .aborted, reasons: ["aborted-by-system"], message: "bad print data: \(error)")
                return
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        queue.with(job) { $0.impressions = pages }
        queue.finish(job, .completed, reasons: ["job-completed-successfully"],
                     message: "dry run: \(pages) page(s), \(size) printer bytes in \(out.lastPathComponent)")
    }
}
