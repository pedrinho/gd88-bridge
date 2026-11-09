// IPP/1.1-2.0 message encoding (RFC 8010 §3): reading requests and writing responses,
// including collections (RFC 8010 §3.1.6).
import Foundation

enum Tag {
    // delimiter tags
    static let operation: UInt8 = 0x01, job: UInt8 = 0x02, end: UInt8 = 0x03
    static let printer: UInt8 = 0x04, unsupportedGroup: UInt8 = 0x05
    // out-of-band values
    static let unsupported: UInt8 = 0x10, unknown: UInt8 = 0x12, noValue: UInt8 = 0x13
    // value tags
    static let integer: UInt8 = 0x21, boolean: UInt8 = 0x22, enumeration: UInt8 = 0x23
    static let octetString: UInt8 = 0x30, dateTime: UInt8 = 0x31, resolution: UInt8 = 0x32, range: UInt8 = 0x33
    static let begCollection: UInt8 = 0x34, textWithLanguage: UInt8 = 0x35, nameWithLanguage: UInt8 = 0x36
    static let endCollection: UInt8 = 0x37
    static let text: UInt8 = 0x41, name: UInt8 = 0x42, keyword: UInt8 = 0x44, uri: UInt8 = 0x45
    static let uriScheme: UInt8 = 0x46, charset: UInt8 = 0x47, language: UInt8 = 0x48, mimeType: UInt8 = 0x49
    static let memberName: UInt8 = 0x4A
}

indirect enum IPPValue {
    case integer(Int32)
    case enumeration(Int32)
    case boolean(Bool)
    case string(UInt8, String)              // text, name, keyword, uri, charset, language, mimeType, ...
    case octets([UInt8])                    // octetString
    case resolution(Int32, Int32, UInt8)    // units: 3 = dots per inch
    case range(Int32, Int32)
    case dateTime(Date)
    case collection([IPPAttribute])
    case outOfBand(UInt8)
    case raw(UInt8, [UInt8])

    var intValue: Int? {
        switch self {
        case .integer(let v), .enumeration(let v): return Int(v)
        default: return nil
        }
    }
    var stringValue: String? {
        if case .string(_, let s) = self { return s }
        return nil
    }
}

struct IPPAttribute {
    var name: String
    var values: [IPPValue]
    init(_ name: String, _ values: [IPPValue]) {
        self.name = name
        self.values = values
    }
}

struct IPPMessage {
    var major: UInt8 = 2
    var minor: UInt8 = 0
    var code: UInt16 = 0           // operation-id in requests, status-code in responses
    var requestId: UInt32 = 0
    var groups: [(tag: UInt8, attributes: [IPPAttribute])] = []

    func find(_ name: String, in tag: UInt8? = nil) -> IPPAttribute? {
        for g in groups where tag == nil || g.tag == tag {
            if let a = g.attributes.first(where: { $0.name == name }) { return a }
        }
        return nil
    }
}

struct IPPParseError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Reads one IPP message from a byte source; the document data (if any) stays in the source.
/// Bounded: at most 1 MB of attributes, 4000 values and collections nested 16 deep.
final class IPPReader {
    private let read: (Int) -> [UInt8]?
    init(read: @escaping (Int) -> [UInt8]?) { self.read = read }

    private var consumed = 0
    private var attributeCount = 0

    private func need(_ n: Int) throws -> [UInt8] {
        if n == 0 { return [] }
        consumed += n
        guard consumed <= Limits.maxIPPAttributeBytes else { throw IPPParseError("IPP attributes larger than 1 MB") }
        guard let b = read(n), b.count == n else { throw IPPParseError("truncated IPP message") }
        return b
    }
    private func countValue() throws {
        attributeCount += 1
        guard attributeCount <= Limits.maxIPPAttributes else { throw IPPParseError("too many IPP attribute values") }
    }
    private func u16() throws -> Int { let b = try need(2); return Int(b[0]) << 8 | Int(b[1]) }

    func message() throws -> IPPMessage {
        let h = try need(8)
        var m = IPPMessage()
        m.major = h[0]
        m.minor = h[1]
        m.code = UInt16(h[2]) << 8 | UInt16(h[3])
        m.requestId = UInt32(h[4]) << 24 | UInt32(h[5]) << 16 | UInt32(h[6]) << 8 | UInt32(h[7])
        var groupTag: UInt8?
        var attrs: [IPPAttribute] = []
        while true {
            let tag = try need(1)[0]
            if tag < 0x10 {
                if let g = groupTag { m.groups.append((g, attrs)) }
                attrs = []
                if tag == Tag.end { break }
                groupTag = tag
                continue
            }
            try countValue()
            let name = String(decoding: try need(try u16()), as: UTF8.self)
            let raw = try need(try u16())
            let value = tag == Tag.begCollection ? .collection(try collection(depth: 1)) : decode(tag, raw)
            if !name.isEmpty {
                attrs.append(IPPAttribute(name, [value]))
            } else if !attrs.isEmpty {
                attrs[attrs.count - 1].values.append(value)      // additional value
            } else {
                throw IPPParseError("value without attribute name")
            }
        }
        return m
    }

    private func collection(depth: Int) throws -> [IPPAttribute] {
        guard depth <= Limits.maxIPPCollectionDepth else { throw IPPParseError("IPP collections nested too deeply") }
        var members: [IPPAttribute] = []
        while true {
            try countValue()
            let tag = try need(1)[0]
            _ = try need(try u16())                 // member name field is always empty
            let raw = try need(try u16())
            switch tag {
            case Tag.endCollection:
                return members
            case Tag.memberName:
                members.append(IPPAttribute(String(decoding: raw, as: UTF8.self), []))
            default:
                guard !members.isEmpty else { throw IPPParseError("collection value without member name") }
                let v = tag == Tag.begCollection ? .collection(try collection(depth: depth + 1)) : decode(tag, raw)
                members[members.count - 1].values.append(v)
            }
        }
    }

    private func decode(_ tag: UInt8, _ b: [UInt8]) -> IPPValue {
        func i32(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]))
        }
        switch tag {
        case Tag.integer where b.count == 4: return .integer(i32(0))
        case Tag.enumeration where b.count == 4: return .enumeration(i32(0))
        case Tag.boolean where b.count == 1: return .boolean(b[0] != 0)
        case Tag.resolution where b.count == 9: return .resolution(i32(0), i32(4), b[8])
        case Tag.range where b.count == 8: return .range(i32(0), i32(4))
        case Tag.octetString: return .octets(b)
        case 0x10...0x1F: return .outOfBand(tag)
        case Tag.textWithLanguage, Tag.nameWithLanguage:
            // 2-byte language length, language, 2-byte text length, text
            guard b.count >= 4 else { return .raw(tag, b) }
            let ll = Int(b[0]) << 8 | Int(b[1])
            guard b.count >= 2 + ll + 2 else { return .raw(tag, b) }
            let tl = Int(b[2 + ll]) << 8 | Int(b[3 + ll])
            guard b.count >= 4 + ll + tl else { return .raw(tag, b) }
            let s = String(decoding: b[(4 + ll)..<(4 + ll + tl)], as: UTF8.self)
            return .string(tag == Tag.textWithLanguage ? Tag.text : Tag.name, s)
        case 0x40...0x5F: return .string(tag, String(decoding: b, as: UTF8.self))
        default: return .raw(tag, b)
        }
    }
}

struct IPPWriter {
    private(set) var bytes: [UInt8] = []

    mutating func header(major: UInt8, minor: UInt8, code: UInt16, requestId: UInt32) {
        bytes += [major, minor, UInt8(code >> 8), UInt8(code & 0xFF)]
        bytes += [UInt8(requestId >> 24), UInt8((requestId >> 16) & 0xFF), UInt8((requestId >> 8) & 0xFF), UInt8(requestId & 0xFF)]
    }
    mutating func group(_ tag: UInt8) { bytes.append(tag) }
    mutating func end() { bytes.append(Tag.end) }

    mutating func attribute(_ a: IPPAttribute) {
        for (i, v) in a.values.enumerated() { value(v, name: i == 0 ? a.name : "") }
    }

    private func be32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
    private mutating func tlv(_ tag: UInt8, _ name: String, _ value: [UInt8]) {
        let n = Array(name.utf8)
        bytes.append(tag)
        bytes += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n
        bytes += [UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
    }

    private mutating func value(_ v: IPPValue, name: String) {
        switch v {
        case .integer(let i): tlv(Tag.integer, name, be32(i))
        case .enumeration(let i): tlv(Tag.enumeration, name, be32(i))
        case .boolean(let b): tlv(Tag.boolean, name, [b ? 1 : 0])
        case .string(let tag, let s): tlv(tag, name, Array(s.utf8))
        case .octets(let b): tlv(Tag.octetString, name, b)
        case .resolution(let x, let y, let u): tlv(Tag.resolution, name, be32(x) + be32(y) + [u])
        case .range(let lo, let hi): tlv(Tag.range, name, be32(lo) + be32(hi))
        case .dateTime(let d): tlv(Tag.dateTime, name, dateTimeBytes(d))
        case .outOfBand(let tag): tlv(tag, name, [])
        case .raw(let tag, let b): tlv(tag, name, b)
        case .collection(let members):
            tlv(Tag.begCollection, name, [])
            for m in members {
                tlv(Tag.memberName, "", Array(m.name.utf8))
                for mv in m.values { value(mv, name: "") }
            }
            tlv(Tag.endCollection, "", [])
        }
    }

    /// RFC 2579 DateAndTime, in UTC.
    private func dateTimeBytes(_ d: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
        let y = c.year ?? 1970
        return [UInt8(y >> 8), UInt8(y & 0xFF), UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(c.hour ?? 0),
                UInt8(c.minute ?? 0), UInt8(c.second ?? 0), UInt8((c.nanosecond ?? 0) / 100_000_000), 0x2B, 0, 0]
    }
}

// MARK: attribute builders

func kw(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.keyword, $0) }) }
func kw(_ n: String, _ v: String) -> IPPAttribute { kw(n, [v]) }
func txt(_ n: String, _ v: String) -> IPPAttribute { IPPAttribute(n, [.string(Tag.text, v)]) }
func txts(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.text, $0) }) }
func nm(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.name, $0) }) }
func nm(_ n: String, _ v: String) -> IPPAttribute { nm(n, [v]) }
func uriA(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.uri, $0) }) }
func uriA(_ n: String, _ v: String) -> IPPAttribute { uriA(n, [v]) }
func mime(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.mimeType, $0) }) }
func charsetA(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.charset, $0) }) }
func langA(_ n: String, _ v: [String]) -> IPPAttribute { IPPAttribute(n, v.map { .string(Tag.language, $0) }) }
func ints(_ n: String, _ v: [Int]) -> IPPAttribute { IPPAttribute(n, v.map { .integer(Int32($0)) }) }
func int(_ n: String, _ v: Int) -> IPPAttribute { ints(n, [v]) }
func enums(_ n: String, _ v: [Int]) -> IPPAttribute { IPPAttribute(n, v.map { .enumeration(Int32($0)) }) }
func en(_ n: String, _ v: Int) -> IPPAttribute { enums(n, [v]) }
func bool(_ n: String, _ v: Bool) -> IPPAttribute { IPPAttribute(n, [.boolean(v)]) }
func dpi(_ n: String, _ x: Int, _ y: Int) -> IPPAttribute { IPPAttribute(n, [.resolution(Int32(x), Int32(y), 3)]) }
func rangeA(_ n: String, _ lo: Int, _ hi: Int) -> IPPAttribute { IPPAttribute(n, [.range(Int32(lo), Int32(hi))]) }
func coll(_ n: String, _ v: [[IPPAttribute]]) -> IPPAttribute { IPPAttribute(n, v.map { .collection($0) }) }
func oob(_ n: String, _ tag: UInt8) -> IPPAttribute { IPPAttribute(n, [.outOfBand(tag)]) }
