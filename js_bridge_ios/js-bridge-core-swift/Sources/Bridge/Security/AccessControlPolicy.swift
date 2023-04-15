import Foundation

public struct AccessControlPolicy: PolicyRule {
    private let allowedOrigins: Set<String>
    private let methodWhitelist: Set<String>

    public init(allowedOrigins: Set<String>, methodWhitelist: Set<String>) {
        self.allowedOrigins = allowedOrigins
        self.methodWhitelist = methodWhitelist
    }

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        let method = input.message.method
        let origin = input.trustedPageContext.origin

        if !allowedOrigins.contains("*") && !allowedOrigins.contains(origin) {
            return .deny(BridgeError(code: BridgeApiContract.errorOriginDeny, message: "origin not allowed"))
        }
        if !methodWhitelist.contains(method) {
            return .deny(BridgeError(code: BridgeApiContract.errorMethodNotAllowed, message: "method not allowed"))
        }
        if method == BridgeApiContract.methodHandshake {
            return .allow()
        }
        guard let session = input.sessionRecord else {
            return .deny(BridgeError(code: BridgeApiContract.errorSessionInvalid, message: "session is required"))
        }
        if session.origin != origin || session.pageInstanceId != input.trustedPageContext.pageInstanceId {
            return .deny(BridgeError(code: BridgeApiContract.errorSessionInvalid, message: "session mismatch"))
        }
        if !session.capabilities.contains(method) {
            return .deny(BridgeError(code: BridgeApiContract.errorCapabilityDeny, message: "capability denied"))
        }
        return .allow()
    }
}
