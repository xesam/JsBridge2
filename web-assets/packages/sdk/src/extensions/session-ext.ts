import { BridgeProtocol } from '../core/protocol.js'
import { BridgeClient, CallOptions } from '../core/bridge-client.js'

export interface SessionApi {
    getSessionId(): string
    setSessionId(sessionId: string): void
    callNativeApi(method: string, data?: CallOptions): void
    callNativeApiWithSession(method: string, data?: CallOptions, requestSessionId?: string): void
}

export function createSessionApi(
    bridgeClient: BridgeClient,
    options?: { readyMethod?: string }
): SessionApi {
    const config = options ?? {}
    const readyMethod = config.readyMethod ?? BridgeProtocol.METHOD_HANDSHAKE

    function failNotReady(callback?: CallOptions): void {
        if (callback && typeof callback.fail === 'function') {
            callback.fail({
                code: BridgeProtocol.ERR_INVALID_MESSAGE,
                message: 'Bridge not ready, sessionId missing.',
                retryable: true,
                details: {},
            })
        }
    }

    function callNativeApi(method: string, data?: CallOptions): void {
        if (!bridgeClient.getSessionId() && method !== readyMethod) {
            failNotReady(data)
            return
        }
        bridgeClient.callNativeApi(method, data)
    }

    function callNativeApiWithSession(method: string, data?: CallOptions, requestSessionId?: string): void {
        bridgeClient.callNativeApiWithSession(method, data, requestSessionId)
    }

    return {
        getSessionId(): string { return bridgeClient.getSessionId() },
        setSessionId(sessionId: string): void { bridgeClient.setSessionId(sessionId) },
        callNativeApi,
        callNativeApiWithSession,
    }
}
