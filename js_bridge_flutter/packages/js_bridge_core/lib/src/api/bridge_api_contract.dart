/// Stable public contract constants mirrored across all platforms.
class BridgeApiContract {
  BridgeApiContract._();

  static const String methodHandshake = 'bridge.handshake';
  static const String methodLifecycle = 'runtime.state';
  static const String methodCancelScope = 'bridge.cancelScope';

  /// 协议方法集：框架装配 MethodGatePolicy 时自动并入 methodWhitelist 放行集（docs/03 §9）。
  /// methodWhitelist 语义为业务方法白名单，宿主无需显式列入协议方法（显式列入亦合法，冗余无副作用）。
  /// 仅含 JS → Native request 方向协议方法（runtime.state 为 Native → JS event，不经过 MethodGatePolicy）。
  /// 新增协议 request 方法时，必须同步加入本集合并四端同步（docs/03 §7 保留方法）。
  static const Set<String> protocolMethods = <String>{
    methodHandshake,
    methodCancelScope,
  };

  /// 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
  static const String errorInvalidMessage = 'E_INVALID_MESSAGE';
  static const String errorPolicyDeny = 'E_POLICY_DENY';
  /// transport 层词汇（v1 裁决，docs/03 §8 传输层类）——JS 客户端本地产生、不跨端
  /// 传输；Native 侧不作业务使用，本常量仅为四端契约对齐声明（Android 同款注册）。
  static const String errorChannelClosed = 'E_CHANNEL_CLOSED';
  /// 安全策略层（HandshakeGatePolicy）：会话未建立即调用非握手方法
  static const String errorNotReady = 'E_NOT_READY';
  static const String errorOriginDeny = 'E_ORIGIN_DENY';
  static const String errorMethodNotAllowed = 'E_METHOD_NOT_ALLOWED';
  static const String errorSessionInvalid = 'E_SESSION_INVALID';
  static const String errorMethodNotFound = 'E_METHOD_NOT_FOUND';
  static const String errorInternal = 'E_INTERNAL';
}
