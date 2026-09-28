import { BridgeProtocol } from './core/protocol.js'
import { CoreBridgeClient, CallOptions } from './core/core-bridge-client.js'

export interface JsBridgeClient {
    getSessionId(): string
    setSessionId(sessionId: string): void
    callNativeApi(method: string, data?: CallOptions): void
    callNativeApiWithSession(method: string, data?: CallOptions, requestSessionId?: string): void
}

export function createJsBridgeClient(
    bridgeClient: CoreBridgeClient,
    options?: { readyMethod?: string }
): JsBridgeClient {
    const config = options ?? {}
    const readyMethod = config.readyMethod ?? BridgeProtocol.METHOD_HANDSHAKE

    function failNotReady(callback?: CallOptions): void {
        if (callback && typeof callback.fail === 'function') {
            callback.fail({
                code: BridgeProtocol.ERR_NOT_READY,
                message: 'Bridge not ready, sessionId missing.',
                retryable: true,
                details: {},
            })
        }
    }

    /** 单一 not-ready 门禁：持有有效 sessionId（显式请求级或已握手绑定），或本调用
     * 即握手方法本身 —— 两入口共用，行为不得因方法名不同而静默放行。 */
    function isReadyWith(explicitSessionId: string, method: string): boolean {
        if (explicitSessionId) { return true }
        if (bridgeClient.getSessionId()) { return true }
        return method === readyMethod
    }

    function callNativeApi(method: string, data?: CallOptions): void {
        if (!isReadyWith('', method)) {
            failNotReady(data)
            return
        }
        bridgeClient.callNativeApi(method, data)
    }

    function callNativeApiWithSession(method: string, data?: CallOptions, requestSessionId?: string): void {
        if (!isReadyWith(typeof requestSessionId === 'string' ? requestSessionId : '', method)) {
            failNotReady(data)
            return
        }
        bridgeClient.callNativeApi(method, data, requestSessionId)
    }

    return {
        getSessionId(): string { return bridgeClient.getSessionId() },
        setSessionId(sessionId: string): void { bridgeClient.setSessionId(sessionId) },
        callNativeApi,
        callNativeApiWithSession,
    }
}
