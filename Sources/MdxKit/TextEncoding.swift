import CoreFoundation
import Foundation

/// Text encodings that appear in MDX headers.
public enum MdictTextEncoding: String, Sendable {
    case utf8
    case utf16le
    case gb18030
    case big5
    case latin1
    case windows1252

    static func from(headerValue: String) -> MdictTextEncoding {
        switch headerValue.uppercased() {
        case "", "UTF-8", "UTF8": return .utf8
        case "UTF-16", "UTF16", "UTF-16LE": return .utf16le
        case "GBK", "GB2312", "GB18030": return .gb18030
        case "BIG5", "BIG-5": return .big5
        case "ISO8859-1", "ISO-8859-1", "LATIN1": return .latin1
        case "WINDOWS-1252", "WINDOWS1252", "CP1252": return .windows1252
        default: return .utf8
        }
    }

    /// Bytes per code unit; the null terminator in key blocks has this width.
    var unitWidth: Int { self == .utf16le ? 2 : 1 }

    private var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16le: return .utf16LittleEndian
        case .latin1: return .isoLatin1
        case .windows1252: return .windowsCP1252
        case .gb18030:
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        case .big5:
            let cf = CFStringEncoding(CFStringEncodings.big5.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    public func decode(_ data: Data) throws -> String {
        if let s = String(data: data, encoding: stringEncoding) { return s }
        // Fall back to lossy UTF-8 rather than failing the whole entry.
        if let s = String(data: data, encoding: .utf8) { return s }
        guard let s = String(bytes: data, encoding: .isoLatin1) else {
            throw MdxError.encodingFailure("cannot decode \(data.count) bytes as \(rawValue)")
        }
        return s
    }
}
