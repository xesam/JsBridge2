import Foundation

public struct BridgeError: Error, Codable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var details: [String: String]

    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        details: [String: String] = [:]
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}
