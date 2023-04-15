import Foundation

public struct PolicyInput {
    public let message: BridgeMessage
    public let trustedPageContext: TrustedPageContext
    public let ready: Bool
    public let sessionRecord: SessionRecord?

    public init(
        message: BridgeMessage,
        trustedPageContext: TrustedPageContext,
        ready: Bool,
        sessionRecord: SessionRecord?
    ) {
        self.message = message
        self.trustedPageContext = trustedPageContext
        self.ready = ready
        self.sessionRecord = sessionRecord
    }
}

public struct PolicyDecision {
    public let allowed: Bool
    public let error: BridgeError?

    public static func allow() -> PolicyDecision {
        PolicyDecision(allowed: true, error: nil)
    }

    public static func deny(_ error: BridgeError) -> PolicyDecision {
        PolicyDecision(allowed: false, error: error)
    }
}

public protocol PolicyRule {
    func evaluate(_ input: PolicyInput) -> PolicyDecision
}

public final class PolicyEngine {
    private let rules: [PolicyRule]

    public init(rules: [PolicyRule]) {
        self.rules = rules
    }

    public func evaluate(_ input: PolicyInput) -> PolicyDecision {
        for rule in rules {
            let result = rule.evaluate(input)
            if !result.allowed {
                return result
            }
        }
        return .allow()
    }
}
