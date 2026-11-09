// Announces the IPP printer with Bonjour (DNS-SD) to this Mac only, so it appears in
// System Settings › Printers & Scanners › Add Printer like any AirPrint printer.
//
// Everything is registered on kDNSServiceInterfaceIndexLocalOnly: nothing is announced on the network.
// The server only listens on 127.0.0.1, so the service points at a private host name
// (gd88-bridge.local) whose only address record is 127.0.0.1, also local-only.
import dnssd
import Foundation

final class BonjourAdvertiser {
    static let hostName = "gd88-bridge.local."
    private static let localOnly = UInt32.max          // kDNSServiceInterfaceIndexLocalOnly ((uint32_t)-1)
    private var connection: DNSServiceRef?
    private var hostRecord: DNSRecordRef?
    private var service: DNSServiceRef?
    private let queue = DispatchQueue(label: "bonjour")

    func start(name: String, port: UInt16, txt: [(String, String)]) {
        var conn: DNSServiceRef?
        var err = DNSServiceCreateConnection(&conn)
        guard err == kDNSServiceErr_NoError, let c = conn else {
            log("Bonjour: cannot connect to mDNSResponder (\(err))")
            return
        }
        connection = c

        var address: [UInt8] = [127, 0, 0, 1]
        var record: DNSRecordRef?
        err = DNSServiceRegisterRecord(c, &record, DNSServiceFlags(kDNSServiceFlagsShared), BonjourAdvertiser.localOnly,
                                       BonjourAdvertiser.hostName, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                       UInt16(address.count), &address, 0,
                                       { _, _, _, error, _ in
                                           if error != kDNSServiceErr_NoError { log("Bonjour: host record failed (\(error))") }
                                       }, nil)
        guard err == kDNSServiceErr_NoError else {
            log("Bonjour: cannot register \(BonjourAdvertiser.hostName) (\(err))")
            return
        }
        hostRecord = record

        var txtData = [UInt8]()
        for (k, v) in txt {
            let entry = Array("\(k)=\(v)".utf8.prefix(255))
            txtData.append(UInt8(entry.count))
            txtData += entry
        }
        var svc: DNSServiceRef? = c          // shares the connection above
        err = DNSServiceRegister(&svc, DNSServiceFlags(kDNSServiceFlagsShareConnection), BonjourAdvertiser.localOnly,
                                 name, "_ipp._tcp,_universal", nil, BonjourAdvertiser.hostName, port.bigEndian,
                                 UInt16(txtData.count), txtData,
                                 { _, _, error, name, _, _, _ in
                                     if error == kDNSServiceErr_NoError {
                                         log("Bonjour: announced \"\(name.map { String(cString: $0) } ?? "?")\" to this Mac only")
                                     } else {
                                         log("Bonjour: announcement failed (\(error))")
                                     }
                                 }, nil)
        guard err == kDNSServiceErr_NoError else {
            log("Bonjour: cannot register the printer (\(err))")
            return
        }
        service = svc
        DNSServiceSetDispatchQueue(c, queue)
    }
}
