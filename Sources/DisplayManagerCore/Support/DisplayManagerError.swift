import Foundation

/// Errors shown to the user. `userMessage` is short and plain; `diagnosticDetail` is for the details view.
public enum DisplayManagerError: Error, LocalizedError, Hashable, Sendable {
    case displayplacerNotFound
    case unsupportedDisplayplacerVersion(found: String)
    case executableUnavailable(path: String, reason: String)
    case malformedListOutput(detail: String)
    case processTimedOut(seconds: Int)
    case invalidScreenSpec(String)
    case unsafeToken(String)
    case newerDocumentVersion(Int)
    case unsupportedDocumentVersion(Int)
    case invalidDocument(String)
    case documentTooLarge(bytes: Int)
    case persistenceFailed(String)
    case loginItemFailed(String)

    public var userMessage: String {
        switch self {
        case .displayplacerNotFound:
            "displayplacer was not found. Install it with Homebrew: brew install displayplacer"
        case .unsupportedDisplayplacerVersion(let found):
            "displayplacer \(found) is not supported. Update it with: brew upgrade displayplacer"
        case .executableUnavailable(let path, _):
            "displayplacer could not be started at \(path)."
        case .malformedListOutput:
            "Couldn't read the current display configuration from displayplacer."
        case .processTimedOut(let seconds):
            "displayplacer did not finish within \(seconds) seconds."
        case .invalidScreenSpec(let spec):
            "The display setting “\(spec)” is not valid."
        case .unsafeToken(let token):
            "The display setting contains characters that are not allowed: “\(token)”."
        case .newerDocumentVersion(let version):
            "This file was created by a newer version of DisplayManager (format \(version))."
        case .unsupportedDocumentVersion(let version):
            "This file uses an unsupported format version (\(version))."
        case .invalidDocument:
            "This file is not a valid DisplayManager layouts file."
        case .documentTooLarge(let bytes):
            "This file is too large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        case .persistenceFailed:
            "Couldn't save your layouts."
        case .loginItemFailed:
            "Couldn't change Launch at Login."
        }
    }

    public var diagnosticDetail: String? {
        switch self {
        case .executableUnavailable(_, let reason): reason
        case .malformedListOutput(let detail): detail
        case .invalidDocument(let detail): detail
        case .persistenceFailed(let detail): detail
        case .loginItemFailed(let detail): detail
        default: nil
        }
    }

    public var errorDescription: String? { userMessage }
}
