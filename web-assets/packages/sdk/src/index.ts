export { BridgeProtocol } from './core/protocol.js'
export type { BridgeKind } from './core/protocol.js'

export { CoreBridgeClient } from './core/core-bridge-client.js'
export type { Transport, CallOptions, BridgeError } from './core/core-bridge-client.js'

export { createNativeTransport } from './platform/native-transport.js'
export type { NativeTransport, ChannelOptions } from './platform/native-transport.js'

export { registerWebEntry } from './platform/web-entry.js'

export { getBridge } from './platform/loader.js'
export type { BridgeLoaderOptions, BridgeReadyResult } from './platform/loader.js'

export { createJsBridgeClient } from './js-bridge-client.js'
export type { JsBridgeClient } from './js-bridge-client.js'

export { createReadyExtension } from './extensions/ready-ext.js'
export type { ReadyExtension, ReadyCallbacks, ReadyOptions } from './extensions/ready-ext.js'

export { createLifecycleBridge } from './extensions/lifecycle-ext.js'
export type { LifecycleBridge, StatePayload } from './extensions/lifecycle-ext.js'
