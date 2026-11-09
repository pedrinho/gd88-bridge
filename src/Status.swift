// What we know about the printer, and how it maps to IPP printer-state / printer-state-reasons.
//
// Status byte (10 FF 40) bits: measured on this GD-88 for 0x02/0x04; 0x01/0x08/0x10 from the
// reverse-engineered PeriPage V1.22 protocol document (A6 firmware), not yet seen on the A40.
// Keyword rules: RFC 8011 §5.4.12 (any "-error" reason => printer-state must be stopped).
import Foundation

struct PrinterInfo {
    var model = ""        // 10 FF 20 F0  e.g. "PeriPage_A40"
    var firmware = ""     // 10 FF 20 F1  e.g. "V6.0.4"
    var serial = ""       // 10 FF 20 F2
    var hardware = ""     // 10 FF 30 10
    var name = ""         // 10 FF 30 11  Bluetooth name
    var isEmpty: Bool { model.isEmpty && firmware.isEmpty }
}

struct StatusBits {
    static let printError: UInt8 = 0x01
    static let lidOpen: UInt8 = 0x02
    static let noPaper: UInt8 = 0x04
    static let lowBattery: UInt8 = 0x08
    static let overheat: UInt8 = 0x10
    /// Conditions that must be cleared before printing (low battery does not block).
    static let blocking: UInt8 = printError | lidOpen | noPaper | overheat
}

struct StatusSnapshot {
    var state: Int32            // 3 idle, 4 processing, 5 stopped
    var reasons: [String]
    var message: String
    var battery: Int?           // smoothed %, nil = unknown
    var info: PrinterInfo
    var changedAt: Date
    var lastRefresh: Date?
    var statusByte: UInt8?
}

final class PrinterStatus {
    private let lock = NSLock()
    private var statusByte: UInt8?
    private var batteryReadings: [Int] = []
    private var info = PrinterInfo()
    private var connectProblem: String?
    private var jobActive = false
    private var changedAt = Date()
    private var lastRefresh: Date?

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    func setStatus(_ b: UInt8?) {
        locked {
            if b != statusByte { statusByte = b; changedAt = Date() }
        }
    }
    func currentStatus() -> UInt8? { locked { statusByte } }

    func addBattery(_ pct: Int) {
        guard (0...100).contains(pct) else { return }
        locked {
            batteryReadings.append(pct)
            if batteryReadings.count > 5 { batteryReadings.removeFirst() }
        }
    }
    func setInfo(_ i: PrinterInfo) { locked { info = i } }
    func getInfo() -> PrinterInfo { locked { info } }
    func setConnectProblem(_ p: String?) {
        locked { if p != connectProblem { connectProblem = p; changedAt = Date() } }
    }
    func setJobActive(_ a: Bool) { locked { if a != jobActive { jobActive = a; changedAt = Date() } } }
    func markRefreshed() { locked { lastRefresh = Date() } }

    func snapshot() -> StatusSnapshot {
        locked {
            var reasons: [String] = []
            var messages: [String] = []
            let battery = batteryReadings.isEmpty ? nil : batteryReadings.sorted()[batteryReadings.count / 2]
            if let s = statusByte {
                if s & StatusBits.lidOpen != 0 {
                    reasons.append("cover-open-error"); messages.append("Lid open")
                } else if s & StatusBits.noPaper != 0 {
                    // with the lid open the paper bit is set too, so only report paper with the lid closed
                    reasons.append("media-empty-error"); messages.append("Out of paper")
                }
                if s & StatusBits.overheat != 0 {
                    reasons.append("other-error"); messages.append("Print head too hot, cooling down")
                }
                if s & StatusBits.printError != 0 {
                    if !reasons.contains("other-error") { reasons.append("other-error") }
                    messages.append("Printer error")
                }
                if s & StatusBits.lowBattery != 0 {
                    reasons.append("marker-supply-low-warning"); messages.append("Battery low")
                }
            }
            if let b = battery, b <= 15, !reasons.contains("marker-supply-low-warning") {
                reasons.append("marker-supply-low-warning"); messages.append("Battery low (\(b)%)")
            }
            if let p = connectProblem {
                reasons.append("connecting-to-device-report"); messages.append(p)
            }
            let hasError = reasons.contains { $0.hasSuffix("-error") }
            let state: Int32 = hasError ? 5 : (jobActive ? 4 : 3)
            return StatusSnapshot(state: state, reasons: reasons.isEmpty ? ["none"] : reasons,
                                  message: messages.joined(separator: "; "), battery: battery, info: info,
                                  changedAt: changedAt, lastRefresh: lastRefresh, statusByte: statusByte)
        }
    }
}
