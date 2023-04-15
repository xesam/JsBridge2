import Foundation

public struct RequestShapePolicy: PolicyRule {
    public init() {}

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        if input.message.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .deny(BridgeError(code: BridgeApiContract.errorInvalidMessage, message: "method is required"))
        }
        if input.message.kind != .request {
            return .deny(BridgeError(code: BridgeApiContract.errorInvalidMessage, message: "only request is accepted"))
        }
        return .allow()
    }
}
