import Foundation

public struct OriginPolicy: PolicyRule {
    private let allowedOrigins: Set<String>

    public init(allowedOrigins: Set<String>) {
        self.allowedOrigins = allowedOrigins
    }

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        guard allowedOrigins.contains(input.trustedPageContext.origin) else {
            return .deny(BridgeError(
                code: BridgeApiContract.errorOriginDeny,
                message: "origin not allowed: \(input.trustedPageContext.origin)"
            ))
        }
        return .allow()
    }
}
