import Foundation

public enum BridgeApiContract {
    public static let methodHandshake = "bridge.handshake"
    public static let methodLifecycle = "runtime.state"
    public static let methodCancelScope = "bridge.cancelScope"

    /// 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
    public static let errorInvalidMessage = "E_INVALID_MESSAGE"
    public static let errorPolicyDeny = "E_POLICY_DENY"
    public static let errorOriginDeny = "E_ORIGIN_DENY"
    public static let errorMethodNotAllowed = "E_METHOD_NOT_ALLOWED"
    public static let errorSessionInvalid = "E_SESSION_INVALID"
    public static let errorCapabilityDeny = "E_CAPABILITY_DENY"
    public static let errorMethodNotFound = "E_METHOD_NOT_FOUND"
    public static let errorInternal = "E_INTERNAL"
}
