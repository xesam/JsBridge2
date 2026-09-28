import { CoreBridgeClient, BridgeError } from '../core/core-bridge-client.js'
import { NativeTransport } from './native-transport.js'

/** registerWebEntry 幂等接线（每 transport 一份）：装载器失败重试（getBridge 的
 * readyPromise 清空后重跑 orchestrate）会对同一 shared transport 重复注册——
 * 若只增不减，前次（已废弃 client 的）listener 会累积为 stale 分发。重复注册时
 * 先移除上一次的 listener 再挂新 wiring，保证消息始终只送达最新 client（一次）。
 * transport 无移除面（宿主自定义实现）时退化为仅追加，维持向后兼容。 */
const entryWiring = new WeakMap<NativeTransport, () => void>()

export function registerWebEntry(bridgeClient: CoreBridgeClient, transport: NativeTransport): void {
    const previousDispose = entryWiring.get(transport)
    if (typeof previousDispose === 'function') { previousDispose() }

    const onMessage = (messageJsonString: string): void => {
        bridgeClient.handleIncomingMessage(messageJsonString)
    }
    const onChannelError = (error: BridgeError): void => {
        bridgeClient.failAllPending(error)
    }
    transport.onMessage(onMessage)
    transport.onChannelError(onChannelError)

    const canDispose = typeof transport.removeOnMessage === 'function' &&
        typeof transport.removeChannelErrorListener === 'function'
    if (canDispose) {
        entryWiring.set(transport, () => {
            transport.removeOnMessage(onMessage)
            transport.removeChannelErrorListener(onChannelError)
        })
    }
}
