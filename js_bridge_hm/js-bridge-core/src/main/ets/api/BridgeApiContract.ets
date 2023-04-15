export class BridgeApiContract {
  static readonly METHOD_HANDSHAKE: string = 'bridge.handshake';
  static readonly METHOD_LIFECYCLE: string = 'runtime.state';
  static readonly METHOD_CANCEL_SCOPE: string = 'bridge.cancelScope';

  /// 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
  static readonly ERR_INVALID_MESSAGE: string = 'E_INVALID_MESSAGE';
  static readonly ERR_POLICY_DENY: string = 'E_POLICY_DENY';
  static readonly ERR_ORIGIN_DENY: string = 'E_ORIGIN_DENY';
  static readonly ERR_METHOD_NOT_ALLOWED: string = 'E_METHOD_NOT_ALLOWED';
  static readonly ERR_SESSION_INVALID: string = 'E_SESSION_INVALID';
  static readonly ERR_CAPABILITY_DENY: string = 'E_CAPABILITY_DENY';
  static readonly ERR_METHOD_NOT_FOUND: string = 'E_METHOD_NOT_FOUND';
  static readonly ERR_INTERNAL: string = 'E_INTERNAL';
}
