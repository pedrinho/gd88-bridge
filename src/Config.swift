// Configuration, limits and small helpers shared by the bridge (kept out of main.swift so the
// unit tests can be built from every source file except main.swift).
import Foundation
import IOBluetooth

struct Config {
    var rawPort: UInt16 = 0            // off by default: only needed with the vendor's own driver
    var ippPort: UInt16 = 8631
    var dryRun = false
    var keepSpool = false
    var printerAddress: String?
    var bonjour = true
    var baseDir: URL
    var spoolDir: URL

    // Limits (see "Security" in the README)
    var maxDocumentBytes = 128 << 20   // per IPP document; larger: client-error-request-entity-too-large
    var maxRawBytes = 64 << 20         // per raw-port job
    var maxActiveJobs = 50             // queued + printing; more: server-error-busy
    var identifyInterval: TimeInterval = 10
}

enum Limits {
    static let maxPageRows = 8200          // ~1 m at 8 dots/mm, the longest media advertised
    static let maxImageRows = 8000         // JPEGs are scaled to fit 1680 x 8000 dots
    static let maxHTTPConnections = 32
    static let maxHTTPHeaderLines = 100
    static let maxHTTPLength = Int(Int32.max)
    static let maxIPPAttributeBytes = 1 << 20
    static let maxIPPAttributes = 4000
    static let maxIPPCollectionDepth = 16
}

/// Finds a paired GD-88 / PeriPage printer (Bluetooth name like "GD-88_XXXX").
func pairedPrinterAddress() -> String? {
    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return devices.first { d in
        let n = (d.name ?? "").lowercased()
        return n.hasPrefix("gd-88") || n.hasPrefix("peripage")
    }?.addressString
}

/// Makes client-supplied text (job and user names) safe for logs and the status page:
/// control characters become spaces and the length is capped.
func clean(_ s: String, max: Int = 200) -> String {
    let scalars = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
    let text = String(scalars).trimmingCharacters(in: .whitespaces)
    return text.count > max ? String(text.prefix(max)) + "…" : text
}

/// Creates (or tightens) a folder only the current user can read.
func makePrivateDirectory(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// Creates an empty file only the current user can read (print jobs contain people's documents).
@discardableResult
func makePrivateFile(_ url: URL) -> Bool {
    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
}
