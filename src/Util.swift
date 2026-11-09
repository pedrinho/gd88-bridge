// Shared helpers: logging, hex formatting, run-loop spinning.
import Foundation

private let logLock = NSLock()
private let stampFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    logLock.lock()
    let line = "\(stampFormat.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logLock.unlock()
}

func hexBytes<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

func hexCode(_ r: Int32) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }

/// Run the current thread's run loop (so IOBluetooth callbacks are delivered) until
/// `done()` is true or `seconds` have passed.
func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}
