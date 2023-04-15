export { BridgeProtocol } from './core/protocol.js'
export type { BridgeKind } from './core/protocol.js'

export { BridgeClient } from './core/bridge-client.js'
export type { Transport, CallOptions, BridgeError, PendingEntry } from './core/bridge-client.js'

export { createNativeTransport } from './platform/native-transport.js'
export type { NativeTransport } from './platform/native-transport.js'

export { registerWebEntry } from './platform/web-entry.js'

export { createSessionApi } from './extensions/session-ext.js'
export type { SessionApi } from './extensions/session-ext.js'

export { createReadyExtension } from './extensions/ready-ext.js'
export type { ReadyExtension, ReadyCallbacks } from './extensions/ready-ext.js'

export { createLifecycleBridge } from './extensions/lifecycle-ext.js'
export type { LifecycleBridge, StatePayload } from './extensions/lifecycle-ext.js'
