import Foundation

public struct SessionPolicy: PolicyRule {

    public init() {}

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        let method = input.message.method
        guard method != BridgeApiContract.methodHandshake else {
            return .allow()
        }
        let ctx = input.trustedPageContext
        guard let session = input.sessionRecord else {
            return .deny(BridgeError(
                code: BridgeApiContract.errorSessionInvalid,
                message: "session is required"
            ))
        }
        guard session.origin == ctx.origin else {
            return .deny(BridgeError(
                code: BridgeApiContract.errorSessionInvalid,
                message: "session origin mismatch"
            ))
        }
        guard session.pageInstanceId == ctx.pageInstanceId else {
            return .deny(BridgeError(
                code: BridgeApiContract.errorSessionInvalid,
                message: "session page mismatch"
            ))
        }
        return .allow()
    }
}
