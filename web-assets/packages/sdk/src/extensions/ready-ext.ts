import { BridgeProtocol } from '../core/protocol.js'
import { JsBridgeClient } from '../js-bridge-client.js'
import { BridgeError } from '../core/core-bridge-client.js'

export interface ReadyCallbacks {
    onSuccess?: (res: unknown) => void
    onFail?: (err: BridgeError) => void
}

/** bootstrapReady 可选配置，透传握手超时——非容器降级不再被硬编码 10s 锁死。 */
export interface ReadyOptions {
    timeoutMs?: number
}

export interface ReadyExtension {
    bootstrapReady(callbacks?: ReadyCallbacks, options?: ReadyOptions): void
}

export function createReadyExtension(
    jsBridgeClient: JsBridgeClient,
    options?: { readyMethod?: string }
): ReadyExtension {
    const config = options ?? {}
    const readyMethod = config.readyMethod ?? BridgeProtocol.METHOD_HANDSHAKE

    function bootstrapReady(callbacks?: ReadyCallbacks, readyOptions?: ReadyOptions): void {
        const handlers = callbacks ?? {}
        const data: Record<string, unknown> = {
            success(res: unknown): void {
                if (res && typeof (res as Record<string, unknown>).sessionId === 'string' &&
                    ((res as Record<string, unknown>).sessionId as string).length > 0) {
                    jsBridgeClient.setSessionId((res as Record<string, unknown>).sessionId as string)
                }
                if (typeof handlers.onSuccess === 'function') { handlers.onSuccess(res) }
            },
            fail(err: BridgeError): void {
                if (typeof handlers.onFail === 'function') { handlers.onFail(err) }
            },
        }
        if (readyOptions && typeof readyOptions.timeoutMs === 'number') {
            data.timeoutMs = readyOptions.timeoutMs
        }
        jsBridgeClient.callNativeApi(readyMethod, data)
    }

    return { bootstrapReady }
}
