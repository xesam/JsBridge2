import { BridgeProtocol } from '../core/protocol.js'
import { SessionApi } from './session-ext.js'
import { BridgeError } from '../core/bridge-client.js'

export interface ReadyCallbacks {
    onSuccess?: (res: unknown) => void
    onFail?: (err: BridgeError) => void
}

export interface ReadyExtension {
    bootstrapReady(callbacks?: ReadyCallbacks): void
}

export function createReadyExtension(
    sessionApi: SessionApi,
    options?: { readyMethod?: string }
): ReadyExtension {
    const config = options ?? {}
    const readyMethod = config.readyMethod ?? BridgeProtocol.METHOD_HANDSHAKE

    function bootstrapReady(callbacks?: ReadyCallbacks): void {
        const handlers = callbacks ?? {}
        sessionApi.callNativeApi(readyMethod, {
            success(res: unknown): void {
                console.log('bridge.handshake:success', res)
                if (res && typeof (res as Record<string, unknown>).sessionId === 'string' &&
                    ((res as Record<string, unknown>).sessionId as string).length > 0) {
                    sessionApi.setSessionId((res as Record<string, unknown>).sessionId as string)
                }
                if (typeof handlers.onSuccess === 'function') { handlers.onSuccess(res) }
            },
            fail(err: BridgeError): void {
                console.log('bridge.handshake:fail', err)
                if (typeof handlers.onFail === 'function') { handlers.onFail(err) }
            },
        })
    }

    return { bootstrapReady }
}
