import { CoreBridgeClient } from '../core/core-bridge-client.js'
import { createNativeTransport, NativeTransport, ChannelOptions } from './native-transport.js'
import { createJsBridgeClient, JsBridgeClient } from '../js-bridge-client.js'
import { registerWebEntry } from './web-entry.js'
import { createReadyExtension } from '../extensions/ready-ext.js'

export interface BridgeLoaderOptions extends ChannelOptions {
    /** SDK 脚本地址：window.JsBridgeSDK 不存在且给出此值时动态注入
     * （<script> 同步消费场景无需此参数）。 */
    sdkUrl?: string
    /** 动态注入脚本的加载超时（ms）。 */
    loadTimeoutMs?: number
    /** 握手超时（ms），透传给 bootstrapReady；缺省走 CoreBridgeClient 默认（10s）。 */
    handshakeTimeoutMs?: number
}

export interface BridgeReadyResult {
    client: JsBridgeClient
    transport: NativeTransport
    bridgeClient: CoreBridgeClient
}

interface SdkEntry {
    createNativeTransport: typeof createNativeTransport
    createJsBridgeClient: typeof createJsBridgeClient
    registerWebEntry: typeof registerWebEntry
    createReadyExtension: typeof createReadyExtension
}

const DEFAULT_LOAD_TIMEOUT_MS = 5000

/** 全 app 唯一 ready 信号（模块级单例）。 */
let readyPromise: Promise<BridgeReadyResult> | null = null

function injectScript(sdkUrl: string, timeoutMs: number): Promise<void> {
    return new Promise((resolve, reject) => {
        const script = document.createElement('script')
        script.src = sdkUrl
        const timer = setTimeout(() => {
            script.remove()
            reject(new Error('jsbridge-sdk load timeout: ' + sdkUrl))
        }, timeoutMs)
        script.onload = () => { clearTimeout(timer); resolve() }
        script.onerror = () => {
            clearTimeout(timer)
            script.remove()
            reject(new Error('jsbridge-sdk load failed: ' + sdkUrl))
        }
        document.head.appendChild(script)
    })
}

async function resolveSdkEntry(sdkUrl: string | undefined, loadTimeoutMs: number | undefined): Promise<SdkEntry> {
    const win = window as unknown as { JsBridgeSDK?: SdkEntry }
    if (win.JsBridgeSDK) { return win.JsBridgeSDK }
    if (sdkUrl) {
        await injectScript(sdkUrl, loadTimeoutMs ?? DEFAULT_LOAD_TIMEOUT_MS)
        if (win.JsBridgeSDK) { return win.JsBridgeSDK }
        throw new Error('sdk script loaded but window.JsBridgeSDK missing')
    }
    // ESM 直引场景（import { getBridge } from 'jsbridge-sdk'）：使用同模块构造器
    return {
        createNativeTransport,
        createJsBridgeClient,
        registerWebEntry,
        createReadyExtension,
    }
}

async function orchestrate(options: BridgeLoaderOptions): Promise<BridgeReadyResult> {
    const sdk = await resolveSdkEntry(options.sdkUrl, options.loadTimeoutMs)
    const transport = sdk.createNativeTransport(options)
    const bridgeClient = new CoreBridgeClient(transport)
    const client = sdk.createJsBridgeClient(bridgeClient)
    sdk.registerWebEntry(bridgeClient, transport)
    const ready = sdk.createReadyExtension(client)
    await new Promise<void>((resolve, reject) => {
        ready.bootstrapReady(
            {
                onSuccess: () => { resolve() },
                onFail: (err) => { reject(err) },
            },
            options.handshakeTimeoutMs !== undefined ? { timeoutMs: options.handshakeTimeoutMs } : undefined
        )
    })
    return { client, transport, bridgeClient }
}

/**
 * 官方装载器（docs/01 §5.2 异步加载 / docs/06 §6.3 getBridge 契约）。
 *
 * 把"文件就绪 → 通道就绪 → 会话就绪"三层折叠为一个 ready 信号：resolve 的
 * 是**握完手的 client**，不是文件本身。单例 Promise——全 app 唯一，幂等防重入，
 * 装载器单例即事实上的共享入口（v1 不提供 getSharedClient() 注册表）。
 *
 * 两个易错点已内置处理（要点正本见 sdk README getBridge）：
 * - 缓存清除发生在 promise 失败（reject）之后（executor 内置空缓存是无效操作）；
 * - 超时参数化（timeoutMs 仅为默认值）。
 */
export function getBridge(options?: BridgeLoaderOptions): Promise<BridgeReadyResult> {
    if (readyPromise) { return readyPromise }
    const opts = options ?? {}
    const attempt = orchestrate(opts)
    // 缓存清除：失败（reject）后若仍是当前缓存的 promise 才置空（已发给调用方的引用不受影响）
    attempt.catch(() => { if (readyPromise === attempt) { readyPromise = null } })
    readyPromise = attempt
    return attempt
}
