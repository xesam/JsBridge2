/// Stable public contract constants mirrored across all platforms.
class BridgeApiContract {
  BridgeApiContract._();

  static const String methodHandshake = 'bridge.handshake';
  static const String methodLifecycle = 'runtime.state';
  static const String methodCancelScope = 'bridge.cancelScope';

  /// 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
  static const String errorInvalidMessage = 'E_INVALID_MESSAGE';
  static const String errorPolicyDeny = 'E_POLICY_DENY';
  static const String errorOriginDeny = 'E_ORIGIN_DENY';
  static const String errorMethodNotAllowed = 'E_METHOD_NOT_ALLOWED';
  static const String errorSessionInvalid = 'E_SESSION_INVALID';
  static const String errorCapabilityDeny = 'E_CAPABILITY_DENY';
  static const String errorMethodNotFound = 'E_METHOD_NOT_FOUND';
  static const String errorInternal = 'E_INTERNAL';
}
