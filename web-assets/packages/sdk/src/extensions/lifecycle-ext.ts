import { BridgeProtocol } from '../core/protocol.js'
import { BridgeClient } from '../core/bridge-client.js'

export interface StatePayload {
    state: string
    seq?: number
    [key: string]: unknown
}

export interface LifecycleBridge {
    currentState: string
    lastSeq: number
    listeners: Array<(payload: StatePayload) => void>
    handleState(payload: unknown): void
    on(listener: (payload: StatePayload) => void): void
    off(listener: (payload: StatePayload) => void): void
    getState(): string
}

export function createLifecycleBridge(
    bridgeClient: BridgeClient,
    options?: { lifecycleMethod?: string }
): LifecycleBridge {
    const config = options ?? {}
    const lifecycleMethod = config.lifecycleMethod ?? BridgeProtocol.METHOD_LIFECYCLE_STATE

    const lifecycleBridge: LifecycleBridge = {
        currentState: 'unknown',
        lastSeq: -1,
        listeners: [],
        handleState(payload: unknown): void {
            if (!payload || typeof (payload as StatePayload).state !== 'string') {
                console.log('runtime.state payload invalid', payload)
                return
            }
            const typedPayload = payload as StatePayload
            const seq = typeof typedPayload.seq === 'number' ? typedPayload.seq : 0
            if (seq <= this.lastSeq) {
                console.log('runtime.state ignored', payload, `lastSeq=${this.lastSeq}`)
                return
            }
            this.lastSeq = seq
            this.currentState = typedPayload.state
            console.log('runtime.state accepted', payload)
            this.listeners.forEach(listener => {
                try { listener(typedPayload) } catch (e) { console.log('lifecycle listener error', e) }
            })
        },
        on(listener: (payload: StatePayload) => void): void { this.listeners.push(listener) },
        off(listener: (payload: StatePayload) => void): void {
            this.listeners = this.listeners.filter(item => item !== listener)
        },
        getState(): string { return this.currentState },
    }

    bridgeClient.registerEventHandler(lifecycleMethod, payload => lifecycleBridge.handleState(payload))
    return lifecycleBridge
}
