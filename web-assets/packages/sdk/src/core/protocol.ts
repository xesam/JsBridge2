export const BridgeProtocol = {
    KIND_REQUEST: 'request',
    KIND_RESPONSE: 'response',
    KIND_EVENT: 'event',
    METHOD_HANDSHAKE: 'bridge.handshake',
    METHOD_LIFECYCLE_STATE: 'runtime.state',
    METHOD_CANCEL_SCOPE: 'bridge.cancelScope',
    ERR_INVALID_MESSAGE: 'E_INVALID_MESSAGE',
    ERR_TIMEOUT: 'E_TIMEOUT',
    ERR_CANCELED: 'E_CANCELED',
    ERR_INTERNAL: 'E_INTERNAL',
} as const

export type BridgeKind = typeof BridgeProtocol.KIND_REQUEST | typeof BridgeProtocol.KIND_RESPONSE | typeof BridgeProtocol.KIND_EVENT
