export const BridgeProtocol = {
    KIND_REQUEST: 'request',
    KIND_RESPONSE: 'response',
    KIND_EVENT: 'event',
    METHOD_HANDSHAKE: 'bridge.handshake',
    METHOD_LIFECYCLE_STATE: 'runtime.state',
    METHOD_CANCEL_SCOPE: 'bridge.cancelScope',
    ERR_INVALID_MESSAGE: 'E_INVALID_MESSAGE',
    ERR_POLICY_DENY: 'E_POLICY_DENY',
    ERR_ORIGIN_DENY: 'E_ORIGIN_DENY',
    ERR_METHOD_NOT_ALLOWED: 'E_METHOD_NOT_ALLOWED',
    ERR_SESSION_INVALID: 'E_SESSION_INVALID',
    ERR_METHOD_NOT_FOUND: 'E_METHOD_NOT_FOUND',
    ERR_TIMEOUT: 'E_TIMEOUT',
    ERR_CANCELED: 'E_CANCELED',
    ERR_INTERNAL: 'E_INTERNAL',
    // transport 层（v1 裁决新增，见 docs/03 §8 传输层类）
    ERR_CHANNEL_CLOSED: 'E_CHANNEL_CLOSED',
    ERR_NOT_READY: 'E_NOT_READY',
    // 通道建立（pull 模型，见 docs/04 §3.1 通道建立入口契约 / docs/06 信道建立机制）
    CHANNEL_EVENT_TYPE: 'bridge:channel',
    REQUEST_CHANNEL_ENTRY: 'requestBridgeChannel',
} as const

export type BridgeKind = typeof BridgeProtocol.KIND_REQUEST | typeof BridgeProtocol.KIND_RESPONSE | typeof BridgeProtocol.KIND_EVENT
