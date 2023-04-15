import Foundation

public struct HandshakeGatePolicy: PolicyRule {
    public init() {}

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        if input.message.method == BridgeApiContract.methodHandshake {
            return .allow()
        }
        if !input.ready {
            return .deny(BridgeError(code: BridgeApiContract.errorPolicyDeny, message: "bridge handshake required"))
        }
        return .allow()
    }
}
