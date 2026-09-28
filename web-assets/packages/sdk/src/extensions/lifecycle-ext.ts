import { BridgeProtocol } from '../core/protocol.js'
import { CoreBridgeClient } from '../core/core-bridge-client.js'

export interface StatePayload {
    state: string
    seq?: number
    [key: string]: unknown
}

export interface LifecycleBridge {
    on(listener: (payload: StatePayload) => void): void
    off(listener: (payload: StatePayload) => void): void
    getState(): string
}

export function createLifecycleBridge(
    bridgeClient: CoreBridgeClient,
    options?: { lifecycleMethod?: string }
): LifecycleBridge {
    const config = options ?? {}
    const lifecycleMethod = config.lifecycleMethod ?? BridgeProtocol.METHOD_LIFECYCLE_STATE

    const listeners: Array<(payload: StatePayload) => void> = []
    let currentState = 'unknown'
    let lastSeq = -1

    // 内部回调（不入公共接口面）：注册给 CoreBridgeClient 的事件处理入口
    const handleState = (payload: unknown): void => {
        if (!payload || typeof (payload as StatePayload).state !== 'string') {
            console.log('runtime.state payload invalid', payload)
            return
        }
        const typedPayload = payload as StatePayload
        const seq = typeof typedPayload.seq === 'number' ? typedPayload.seq : 0
        if (seq <= lastSeq) {
            console.log('runtime.state ignored', payload, `lastSeq=${lastSeq}`)
            return
        }
        lastSeq = seq
        currentState = typedPayload.state
        listeners.forEach(listener => {
            try { listener(typedPayload) } catch (e) { console.error('lifecycle listener error', e) }
        })
    }

    const lifecycleBridge: LifecycleBridge = {
        on(listener: (payload: StatePayload) => void): void { listeners.push(listener) },
        off(listener: (payload: StatePayload) => void): void {
            const index = listeners.indexOf(listener)
            if (index !== -1) { listeners.splice(index, 1) }
        },
        getState(): string { return currentState },
    }

    bridgeClient.registerEventHandler(lifecycleMethod, handleState)
    return lifecycleBridge
}
