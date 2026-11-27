import Foundation

public enum RetinaLinkError: LocalizedError {
    case operation(String)
    case videoToolbox(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .operation(let message): message
        case .videoToolbox(let operation, let status): "\(operation) failed (OSStatus \(status))"
        }
    }
}
