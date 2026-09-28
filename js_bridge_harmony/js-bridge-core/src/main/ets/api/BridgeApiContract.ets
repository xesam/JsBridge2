export class BridgeApiContract {
  static readonly METHOD_HANDSHAKE: string = 'bridge.handshake';
  static readonly METHOD_LIFECYCLE: string = 'runtime.state';
  static readonly METHOD_CANCEL_SCOPE: string = 'bridge.cancelScope';

  /// 协议方法集：框架装配 MethodGatePolicy 时自动并入 methodWhitelist 放行集（docs/03 §9）。
  /// methodWhitelist 语义为业务方法白名单，宿主无需显式列入协议方法（显式列入亦合法，冗余无副作用）。
  /// 仅含 JS → Native request 方向协议方法（runtime.state 为 Native → JS event，不经过 MethodGatePolicy）。
  /// 新增协议 request 方法时，必须同步加入本集合并四端同步（docs/03 §7 保留方法）。
  /// ArkTS 的 static readonly 仅禁重新赋值、不禁 add/clear，故以静态方法返回防御性拷贝，
  /// 与其他三端的不可变常量保持等效的防篡改语义。
  static getProtocolMethods(): Set<string> {
    return new Set<string>([
      BridgeApiContract.METHOD_HANDSHAKE,
      BridgeApiContract.METHOD_CANCEL_SCOPE
    ]);
  }

  /// 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
  /// transport 层词汇（v1 裁决，docs/03 §8 传输层类）——JS 客户端本地产生、不跨端
  /// 传输；Native 侧不作业务使用，本常量仅为四端契约对齐声明（Android 同款注册）。
  static readonly ERR_CHANNEL_CLOSED: string = 'E_CHANNEL_CLOSED';
  static readonly ERR_INVALID_MESSAGE: string = 'E_INVALID_MESSAGE';
  static readonly ERR_POLICY_DENY: string = 'E_POLICY_DENY';
  // 安全策略层（HandshakeGatePolicy）：会话未建立即调用非握手方法
  static readonly ERR_NOT_READY: string = 'E_NOT_READY';
  static readonly ERR_ORIGIN_DENY: string = 'E_ORIGIN_DENY';
  static readonly ERR_METHOD_NOT_ALLOWED: string = 'E_METHOD_NOT_ALLOWED';
  static readonly ERR_SESSION_INVALID: string = 'E_SESSION_INVALID';
  static readonly ERR_METHOD_NOT_FOUND: string = 'E_METHOD_NOT_FOUND';
  static readonly ERR_INTERNAL: string = 'E_INTERNAL';
}
