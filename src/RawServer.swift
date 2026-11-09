// Raw printer-data entry point (CUPS socket:// backend, "AppSocket/JetDirect") for a queue that
// uses the vendor's GD-88 driver. Off by default (--raw-port N turns it on).
//
// Security: anything on this Mac, including a web page in a browser, can connect to a localhost
// port. Raw data therefore never goes to the printer as-is: validateRawJob() accepts only the
// command sequence the vendor driver produces, so printer settings or maintenance commands
// (e.g. 10 FF E0 AA AA, which writes flash) can't be smuggled in.
//
// The connection is held open until the job has printed: a normal close means success;
// a reset (RST) tells CUPS the job failed.
import Darwin
import Foundation

/// Creates a TCP listener bound to 127.0.0.1 only.
func listenLocal(port: UInt16) -> Int32? {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
    var yes: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(s, 16) == 0 else { close(s); return nil }
    return s
}

/// Closes with RST instead of FIN so the peer sees an error.
func resetSocket(_ fd: Int32) {
    var lg = linger(l_onoff: 1, l_linger: 0)
    setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
    close(fd)
}

/// Checks that raw data is a complete GD-88 job made only of the commands the vendor driver emits
/// (see docs/PROTOCOL.md). Returns nil if it is, otherwise the reason it was rejected.
func validateRawJob(_ d: [UInt8]) -> String? {
    guard d.starts(with: [0x10, 0xFF, 0xF1, 0x02]) else { return "does not start with the GD-88 job-start command" }
    var i = 0
    var ended = false
    func at(_ p: [UInt8]) -> Bool { i + p.count <= d.count && d[i..<i + p.count].elementsEqual(p) }
    while i < d.count {
        if ended { return "data after the end-of-job command at byte \(i)" }
        if at([0x10, 0xFF, 0xF1, 0x02]) {                       // job start
            i += 4
        } else if at([0x10, 0xFF, 0xF1, 0x45]) {                // end of job
            i += 4
            ended = true
        } else if at([0x10, 0x40]) {                            // part of the driver's start sequence
            i += 2
        } else if at([0x1F, 0x80, 0x01, 0x10]) {                // part of the driver's start sequence
            i += 4
        } else if at([0x10, 0xFF, 0x10, 0x00]) {                // darkness n (0-2), not saved by the printer
            guard i + 4 < d.count, d[i + 4] <= 2 else { return "invalid darkness command at byte \(i)" }
            i += 5
        } else if at([0x1F, 0x11, 0x50]) || at([0x1F, 0x11, 0x51]) {   // page-mark search (label media)
            i += 3
        } else if at([0x1D, 0x0C]) {                            // page mark
            i += 2
        } else if at([0x1B, 0x4A]) {                            // feed n dots
            guard i + 2 < d.count else { return "truncated feed command at byte \(i)" }
            i += 3
        } else if at([0x1D, 0x76, 0x30]) {                      // GS v 0 raster strip
            guard i + 8 <= d.count else { return "truncated raster header at byte \(i)" }
            let mode = d[i + 3]
            let width = Int(d[i + 4]) | Int(d[i + 5]) << 8
            let height = Int(d[i + 6]) | Int(d[i + 7]) << 8
            guard mode <= 3, (1...216).contains(width), (1...1024).contains(height) else {
                return "unsupported raster strip (\(width) x \(height), mode \(mode)) at byte \(i)"
            }
            guard i + 8 + width * height <= d.count else { return "truncated raster data at byte \(i)" }
            i += 8 + width * height
        } else {
            return String(format: "unexpected byte 0x%02X at offset %d", d[i], i)
        }
    }
    return ended ? nil : "job does not end with the end-of-job command"
}

final class RawServer {
    let port: UInt16
    let queue: JobQueue
    let maxBytes: Int
    private let countLock = NSLock()
    private var active = 0

    init(port: UInt16, queue: JobQueue, maxBytes: Int) {
        self.port = port
        self.queue = queue
        self.maxBytes = maxBytes
    }

    func start() {
        guard let s = listenLocal(port: port) else {
            log("ERROR cannot listen on 127.0.0.1:\(port) (errno \(errno)); is another copy running?")
            exit(1)
        }
        log("raw printer data on 127.0.0.1:\(port) (vendor-driver jobs only)")
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(s, nil, nil)
                guard c >= 0 else { continue }
                countLock.lock()
                if active >= 4 {
                    countLock.unlock()
                    resetSocket(c)
                    continue
                }
                active += 1
                countLock.unlock()
                Thread.detachNewThread {
                    self.handle(c)
                    self.countLock.lock(); self.active -= 1; self.countLock.unlock()
                }
            }
        }
    }

    private func handle(_ fd: Int32) {
        var tv = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                data.append(contentsOf: buf[0..<n])
                if data.count > maxBytes { log("raw job rejected: larger than \(maxBytes >> 20) MB"); resetSocket(fd); return }
                // Not a GD-88 job (e.g. an HTTP request from a web page): refuse at once, don't wait for the end.
                if data.count >= 4 && !data.starts(with: [0x10, 0xFF, 0xF1, 0x02]) {
                    log("raw job rejected (\(data.count) bytes so far): does not start with the GD-88 job-start command")
                    resetSocket(fd)
                    return
                }
            } else if n == 0 {
                break
            } else {
                log("raw job: read error (errno \(errno))")
                resetSocket(fd)
                return
            }
        }
        if data.isEmpty { close(fd); return }
        if let reason = validateRawJob(data) {
            log("raw job rejected (\(data.count) bytes): \(reason)")
            resetSocket(fd)
            return
        }
        let job = Job(id: queue.makeId(), payload: .escpos(Data(data)), name: "raw job", user: "cups",
                      copies: 1, quality: 4, source: "raw")
        queue.submit(job)
        job.finished.wait()
        if queue.with(job, { $0.state == .completed }) { close(fd) } else { resetSocket(fd) }
    }
}
