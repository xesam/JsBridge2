import Foundation

public struct MethodGatePolicy: PolicyRule {
    private let methodWhitelist: Set<String>

    public init(methodWhitelist: Set<String>) {
        self.methodWhitelist = methodWhitelist
    }

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        guard methodWhitelist.contains(input.message.method) else {
            return .deny(BridgeError(
                code: BridgeApiContract.errorMethodNotAllowed,
                message: "method not allowed: \(input.message.method)"
            ))
        }
        return .allow()
    }
}
