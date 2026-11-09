// Print jobs from both entry points (raw :9100 and IPP :8631) share one FIFO queue,
// because the printer accepts only one Bluetooth connection at a time.
import Foundation

/// IPP job-state values (RFC 8011 §5.3.7).
enum JobState: Int32 {
    case pending = 3, held = 4, processing = 5, stopped = 6, canceled = 7, aborted = 8, completed = 9
    var isFinished: Bool { rawValue >= 7 }
}

enum JobPayload {
    case none           // Create-Job: document not sent yet
    case escpos(Data)   // raw path: already printer-ready bytes from the vendor driver
    case pwg(URL)       // IPP path: spooled PWG (or CUPS) raster document
}

final class Job {
    let id: Int
    let name: String
    let user: String
    let copies: Int
    let quality: Int        // IPP print-quality: 3 draft, 4 normal, 5 high
    let source: String      // "raw" or "ipp"
    let createdAt = Date()
    let finished = DispatchSemaphore(value: 0)

    // Mutable state below is only touched while holding JobQueue.lock.
    var payload: JobPayload
    var kOctets: Int        // document size, kept after the spool file is deleted
    var state: JobState = .pending
    var reasons: [String] = ["none"]
    var message = ""
    var impressions = 0
    var processingAt: Date?
    var completedAt: Date?
    var cancelRequested = false

    init(id: Int, payload: JobPayload, name: String, user: String, copies: Int, quality: Int, source: String) {
        self.id = id
        self.payload = payload
        self.name = name
        self.user = user
        self.copies = copies
        self.quality = quality
        self.source = source
        kOctets = Job.kOctets(payload)
    }

    static func size(of payload: JobPayload) -> Int {
        switch payload {
        case .none: return 0
        case .escpos(let d): return d.count
        case .pwg(let url): return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
    }
    static func kOctets(_ p: JobPayload) -> Int { (size(of: p) + 1023) / 1024 }

    var hasDocument: Bool {
        if case .none = payload { return false }
        return true
    }
}

final class JobQueue {
    enum Work { case job(Job), refresh, identify }

    private let lock = NSCondition()
    private var pending: [Job] = []
    private var history: [Job] = []
    private var nextId = 1
    private var refreshRequested = false
    private var identifyRequested = false

    func makeId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    private func remember(_ job: Job) {
        history.append(job)
        // keep the last 50 finished jobs for Get-Jobs / Get-Job-Attributes
        let finished = history.filter { $0.state.isFinished }
        if finished.count > 50, let drop = finished.first { history.removeAll { $0 === drop } }
    }

    /// Print-Job (or a raw job): the document is already there.
    func submit(_ job: Job) {
        lock.lock()
        remember(job)
        pending.append(job)
        lock.signal()
        lock.unlock()
        log("job \(job.id) queued (\(job.source), \(job.kOctets) KB, \"\(job.name)\")")
    }

    /// Create-Job: the job exists but waits for Send-Document.
    func register(_ job: Job) {
        lock.lock()
        job.state = .held
        job.reasons = ["job-incoming"]
        remember(job)
        lock.unlock()
        log("job \(job.id) created, waiting for its document")
    }

    /// Send-Document: attach the document and queue the job for printing.
    func attach(_ job: Job, _ payload: JobPayload) {
        lock.lock()
        job.payload = payload
        job.kOctets = Job.kOctets(payload)
        job.state = .pending
        job.reasons = ["none"]
        pending.append(job)
        lock.signal()
        lock.unlock()
        log("job \(job.id) queued (\(job.source), \(job.kOctets) KB, \"\(job.name)\")")
    }

    func requestRefresh() {
        lock.lock(); refreshRequested = true; lock.signal(); lock.unlock()
    }

    func requestIdentify() {
        lock.lock(); identifyRequested = true; lock.signal(); lock.unlock()
    }

    /// Blocks up to `timeout` for the next job (or a status-refresh / identify request).
    func waitForWork(timeout: TimeInterval) -> Work? {
        lock.lock(); defer { lock.unlock() }
        let end = Date().addingTimeInterval(timeout)
        while pending.isEmpty && !refreshRequested && !identifyRequested {
            if !lock.wait(until: end) { return nil }
        }
        // CUPS asks for printer status right before sending a job; give that job 3 s to arrive,
        // since printing reads the status anyway (and saves a separate Bluetooth connection).
        if pending.isEmpty && refreshRequested && !identifyRequested {
            let grace = Date().addingTimeInterval(3)
            while pending.isEmpty && !identifyRequested { if !lock.wait(until: grace) { break } }
        }
        if !pending.isEmpty { refreshRequested = false; return .job(pending.removeFirst()) }
        if identifyRequested { identifyRequested = false; return .identify }
        refreshRequested = false
        return .refresh
    }

    /// Read or change a job's mutable state safely.
    @discardableResult
    func with<T>(_ job: Job, _ body: (Job) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(job)
    }

    func find(_ id: Int) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return history.first { $0.id == id }
    }

    func all() -> [Job] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return history.filter { !$0.state.isFinished }.count
    }

    func finish(_ job: Job, _ state: JobState, reasons: [String], message: String = "") {
        lock.lock()
        job.state = state
        job.reasons = reasons
        job.message = message
        job.completedAt = Date()
        let payload = job.payload
        lock.unlock()
        if case .pwg(let url) = payload { try? FileManager.default.removeItem(at: url) }
        job.finished.signal()
        log("job \(job.id) \(state) \(reasons.joined(separator: ",")) \(message)")
    }

    /// Cancel-Job: waiting jobs end at once; a printing job stops at the next strip boundary.
    enum CancelResult { case canceled, stopping, notPossible, notFound }
    func cancel(_ id: Int) -> CancelResult {
        lock.lock()
        guard let job = history.first(where: { $0.id == id }) else { lock.unlock(); return .notFound }
        if job.state.isFinished { lock.unlock(); return .notPossible }
        let waiting = pending.firstIndex(where: { $0 === job })
        if let i = waiting { pending.remove(at: i) }
        if waiting != nil || !job.hasDocument {
            lock.unlock()
            finish(job, .canceled, reasons: ["job-canceled-by-user"])
            return .canceled
        }
        job.cancelRequested = true
        lock.unlock()
        return .stopping
    }

    /// multiple-operation-time-out: Create-Job without Send-Document is aborted after `seconds`.
    func expireIncoming(after seconds: TimeInterval) {
        let stale = all().filter { j in
            with(j) { !$0.hasDocument && $0.state == .held && Date().timeIntervalSince($0.createdAt) > seconds }
        }
        for j in stale { finish(j, .aborted, reasons: ["aborted-by-system"], message: "no document received") }
    }
}
