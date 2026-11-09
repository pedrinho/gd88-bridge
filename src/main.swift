// gd88bridge: print to a GD-88 / PeriPage A40 thermal printer from macOS over classic Bluetooth.
//
//   IPP Everywhere printer on ipp://localhost:8631/ipp/print   (driverless queue, status + battery)
//   raw printer data on 127.0.0.1:<port> with --raw-port N      (off by default; for the vendor driver)
//
// Usage: gd88bridge [--printer XX-XX-XX-XX-XX-XX] [--ipp-port N] [--raw-port N] [--dry-run] [--keep-spool] [--no-bonjour]
//        gd88bridge --encode IN.raster OUT.bin [--quality 3|4|5] [--no-trim]   (offline test)
//        gd88bridge --decode IN.raster OUT.gray                                (offline test)
// A port of 0 turns that entry point off; the raw port is off unless --raw-port is given.
// Without --printer, the first paired Bluetooth device whose name starts with "GD-88" or
// "PeriPage" is used.
import CoreBluetooth
import Foundation
import IOBluetooth

setvbuf(stderr, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let home = FileManager.default.homeDirectoryForCurrentUser
var config = Config(baseDir: home.appendingPathComponent("Library/Application Support/GD88Bridge"),
                    spoolDir: home.appendingPathComponent("Library/Caches/GD88Bridge"))
var args = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
func flag(_ f: String) -> Bool {
    guard let i = args.firstIndex(of: f) else { return false }
    args.remove(at: i)
    return true
}

// MARK: offline test tools

if let input = value(after: "--encode") {
    guard let output = args.first else { log("usage: --encode IN OUT [--quality N] [--no-trim]"); exit(2) }
    args.removeFirst()
    let quality = Int(value(after: "--quality") ?? "4") ?? 4
    let trim = !flag("--no-trim")
    FileManager.default.createFile(atPath: output, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: output) else { log("cannot write \(output)"); exit(1) }
    do {
        let r = try convertRaster(url: URL(fileURLWithPath: input), copies: 1, quality: quality, trim: trim,
                                  shouldStop: { false }, emit: { fh.write($0); return true })
        try fh.close()
        log("encoded \(r.pages) page(s) -> \(output)")
        exit(0)
    } catch {
        log("encode failed: \(error)")
        exit(1)
    }
}

if let input = value(after: "--decode") {
    guard let output = args.first else { log("usage: --decode IN OUT"); exit(2) }
    FileManager.default.createFile(atPath: output, contents: nil)
    guard let fh = FileHandle(forWritingAtPath: output) else { log("cannot write \(output)"); exit(1) }
    do {
        let reader = try RasterReader(url: URL(fileURLWithPath: input))
        var pages = 0
        while let p = try reader.nextPage() {
            var line = [UInt8](repeating: 0, count: p.bytesPerLine)
            for _ in 0..<p.height { try reader.readLine(into: &line); fh.write(Data(line)) }
            pages += 1
            log("page \(pages): \(p.width)x\(p.height) \(p.bitsPerPixel)bpp colorspace \(p.colorSpace) \(p.resX)dpi")
        }
        try fh.close()
        exit(0)
    } catch {
        log("decode failed: \(error)")
        exit(1)
    }
}

// MARK: service

if let p = value(after: "--ipp-port") { config.ippPort = UInt16(p) ?? config.ippPort }
if let p = value(after: "--raw-port") { config.rawPort = UInt16(p) ?? config.rawPort }
if let a = value(after: "--printer") { config.printerAddress = a.lowercased().replacingOccurrences(of: ":", with: "-") }
config.dryRun = flag("--dry-run")
config.keepSpool = flag("--keep-spool")
config.bonjour = !flag("--no-bonjour")
// A dry run gets its own spool folder, so it never touches (or clears) the real bridge's jobs.
if config.dryRun { config.spoolDir = config.spoolDir.appendingPathComponent("dry-run") }
if !args.isEmpty { log("unknown arguments: \(args.joined(separator: " "))"); exit(2) }

for dir in [config.baseDir, config.spoolDir] { makePrivateDirectory(dir) }
// Jobs don't survive a restart, so documents left over from an earlier run are deleted.
for f in (try? FileManager.default.contentsOfDirectory(atPath: config.spoolDir.path)) ?? [] where f.hasPrefix("job-") {
    try? FileManager.default.removeItem(at: config.spoolDir.appendingPathComponent(f))
}

log("gd88bridge starting\(config.dryRun ? " (DRY RUN: nothing is sent to the printer)" : "")")

// Open the ports first: the Bluetooth calls below can wait for the user to answer the macOS
// Bluetooth permission prompt, and jobs should be accepted (and queued) meanwhile.
let queue = JobQueue()
let printerStatus = PrinterStatus()
if config.rawPort != 0 { RawServer(port: config.rawPort, queue: queue, maxBytes: config.maxRawBytes).start() }
let bonjour = BonjourAdvertiser()
if config.ippPort != 0 {
    let ipp = IPPService(config: config, queue: queue, status: printerStatus)
    HTTPServer(port: config.ippPort, ipp: ipp).start()
    if config.bonjour {
        // AirPrint / IPP Everywhere TXT keys (Bonjour Printing Specification, PWG 5100.14 §4.2)
        bonjour.start(name: "HZTZ GD-88 (Bluetooth)", port: config.ippPort, txt: [
            ("txtvers", "1"), ("qtotal", "1"), ("rp", "ipp/print"),
            ("ty", "HZTZ GD-88"), ("product", "(GD-88)"), ("note", "Bluetooth, via this Mac"),
            ("adminurl", "http://localhost:\(config.ippPort)/"), ("priority", "50"),
            ("pdl", IPPService.formats.joined(separator: ",")),
            ("URF", IPPService.urfSupported.joined(separator: ",")),
            ("Color", "F"), ("Duplex", "F"), ("Copies", "T"), ("Fax", "F"), ("Scan", "F"),
            ("kind", "document,receipt"), ("PaperMax", "<legal-A4"),
            ("UUID", ipp.uuid), ("air", "none"),
        ])
    }
}

var permissionProbe: CBCentralManager?
if !config.dryRun {
    let names: [CBManagerAuthorization: String] = [.notDetermined: "not yet asked", .restricted: "restricted",
                                                   .denied: "DENIED", .allowedAlways: "allowed"]
    log("Bluetooth permission: \(names[CBManager.authorization] ?? "unknown")")
    if CBManager.authorization == .notDetermined {
        // Asks for permission now, so the macOS prompt doesn't appear in the middle of a job.
        permissionProbe = CBCentralManager(delegate: nil, queue: DispatchQueue(label: "bt-permission"))
    }
    if config.printerAddress == nil { config.printerAddress = pairedPrinterAddress() }
    if let a = config.printerAddress { log("printer: \(a)") } else {
        log("WARNING no paired GD-88/PeriPage printer found; pair it in System Settings › Bluetooth (will keep looking)")
    }
}
PrinterWorker(config: config, queue: queue, status: printerStatus).run()
