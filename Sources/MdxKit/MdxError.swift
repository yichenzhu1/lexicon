import Foundation

public enum MdxError: LocalizedError {
    case truncatedFile(String)
    case badChecksum(String)
    case unsupportedVersion(String)
    case unsupportedEncryption(String)
    case unsupportedCompression(UInt32)
    case corruptData(String)
    case encodingFailure(String)

    public var errorDescription: String? {
        switch self {
        case .truncatedFile(let s): return "Truncated dictionary file: \(s)"
        case .badChecksum(let s): return "Checksum mismatch: \(s)"
        case .unsupportedVersion(let s): return "Unsupported MDict version: \(s)"
        case .unsupportedEncryption(let s): return "Unsupported encryption: \(s)"
        case .unsupportedCompression(let t): return "Unsupported compression type \(t)"
        case .corruptData(let s): return "Corrupt dictionary data: \(s)"
        case .encodingFailure(let s): return "Text encoding failure: \(s)"
        }
    }
}
