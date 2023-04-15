import { BridgeClient } from '../core/bridge-client.js'
import { NativeTransport } from './native-transport.js'

export function registerWebEntry(bridgeClient: BridgeClient, transport: NativeTransport): void {
    transport.onMessage(messageJsonString => {
        bridgeClient.handleIncomingMessage(messageJsonString)
    })
}
