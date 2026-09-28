import { BridgeProtocol } from '../core/protocol.js'
import type { BridgeError } from '../core/core-bridge-client.js'

export interface NativeTransport {
    send(messageJson: string): void
    onMessage(listener: (messageJson: string) => void): void
    /** 信道建立失败（reqId 重试耗尽/宿主拒绝/入口不存在）时通知上层，
     * 上层应将全部 pending 请求以该错误 fail（docs/06 §3.1）。 */
    onChannelError(listener: (error: BridgeError) => void): void
    /** 移除 onMessage 挂载的 listener（listeners 原本只增不减——装载器失败重试经
     * registerWebEntry 会累积 stale 分发；提供移除面 + 注册幂等——该语义的完整描述见 web-entry.ts 头注释）。 */
    removeOnMessage(listener: (messageJson: string) => void): void
    /** 移除 onChannelError 挂载的 listener。 */
    removeChannelErrorListener(listener: (error: BridgeError) => void): void
}

/** requestBridgeChannel 入口的同步 ack（docs/04 §3.1 通道建立入口契约，四态）：
 * ① 匹配 → { ok, reqId }；② 限频 → { error: 'rate_limited' }；
 * ③ 入口不存在（老宿主）；④ 请求畸形 → { error: 'malformed' }。禁止静默。 */
interface ChannelAck {
    ok?: boolean
    reqId?: string
    error?: string
}

/** 通道建立请求的 opts 信封（忽略未知字段的前向兼容规则）。 */
interface ChannelRequestOpts {
    reqId: string
    [key: string]: unknown
}

/** bridge:channel 投递事件信封（docs/06 §2.2）。 */
interface ChannelEventEnvelope {
    type?: string
    reqId?: string
}

declare global {
    interface Window {
        __jsbridge2__?: {
            callNativeApi?: (messageJson: string) => void
            receive?: (messageJson: string) => void
            /** transport 控制面哑入口（v1 裁决）：只做一件事——触发建通道。
             * 仅 Android（@JavascriptInterface）等具备同步注入面的平台注入；
             * iOS WKWebView 无同步通道，不注入（resident 语义，由 JS 侧同步探测达成）。 */
            requestBridgeChannel?: (optsJson: string) => string
        }
        NativeBridge?: { postMessage: (messageJson: string) => void }
        webkit?: {
            messageHandlers?: {
                NativeBridge?: { postMessage: (messageJson: string) => void }
            }
        }
    }
}

export interface ChannelOptions {
    /** 单次 requestBridgeChannel 发出后等待投递的窗口（ms），超时换新 reqId 重试。 */
    channelTimeoutMs?: number
    /** reqId 重试上限，耗尽后本地 fail E_CHANNEL_CLOSED。 */
    maxChannelRetries?: number
    /** 重试退避基数（ms）：入口缺失/投递超时路径固定间隔退避；
     * ack 错误（rate_limited / invalid ack）路径乘以已重试次数线性放大。 */
    retryBackoffMs?: number
}

const DEFAULT_CHANNEL_TIMEOUT_MS = 2000
const DEFAULT_MAX_CHANNEL_RETRIES = 3
const RETRY_BACKOFF_MS = 500

/** 双实例守卫——同页面第二次 createNativeTransport() 不再产生踩踏（docs/06 §5.1），
 * console.warn 留证据并复用既有实例。 */
let sharedTransport: NativeTransport | null = null

function channelError(code: string, message: string, retryable: boolean): BridgeError {
    return { code, message, retryable, details: {} }
}

export function createNativeTransport(options?: ChannelOptions): NativeTransport {
    if (sharedTransport !== null) {
        console.warn('[jsbridge] createNativeTransport() called twice in one page — reusing existing transport (see docs/06 §5.1)')
        return sharedTransport
    }

    const config = options ?? {}
    const channelTimeoutMs = typeof config.channelTimeoutMs === 'number' ? config.channelTimeoutMs : DEFAULT_CHANNEL_TIMEOUT_MS
    const maxChannelRetries = typeof config.maxChannelRetries === 'number' ? config.maxChannelRetries : DEFAULT_MAX_CHANNEL_RETRIES
    const retryBackoffMs = typeof config.retryBackoffMs === 'number' ? config.retryBackoffMs : RETRY_BACKOFF_MS

    let port: MessagePort | null = null
    /** 已采纳端口对应的 reqId——同 reqId 重复投递幂等忽略（docs/06 §2.3）。 */
    let adoptedReqId: string | null = null
    /** 当前最新请求的 reqId——仅匹配它才采纳，其余为陈旧投递。 */
    let currentReqId: string | null = null
    let retryCount = 0
    let requestTimer: ReturnType<typeof setTimeout> | null = null
    let retryTimer: ReturnType<typeof setTimeout> | null = null
    const queue: string[] = []
    const listeners: Array<(messageJson: string) => void> = []
    const channelErrorListeners: Array<(error: BridgeError) => void> = []
    let flushTimer: ReturnType<typeof setTimeout> | null = null
    let reqCounter = 0

    const resolveSender = (): ((messageJson: string) => void) | null => {
        if (port) {
            return messageJson => port!.postMessage(messageJson)
        }
        if (window.NativeBridge && typeof window.NativeBridge.postMessage === 'function') {
            return messageJson => window.NativeBridge!.postMessage(messageJson)
        }
        if (
            window.webkit &&
            window.webkit.messageHandlers &&
            window.webkit.messageHandlers.NativeBridge &&
            typeof window.webkit.messageHandlers.NativeBridge.postMessage === 'function'
        ) {
            return messageJson => window.webkit!.messageHandlers!.NativeBridge!.postMessage(messageJson)
        }
        return null
    }

    /** 常驻通道平台（iOS WKScriptMessageHandler / Flutter / HarmonyOS）：
     * 通道随页面就绪即存活，无需 pull 请求（docs/04 §3.1 同步 ack 平台分层，iOS 豁免）。 */
    const isResidentChannel = (): boolean => {
        if (port !== null) { return false }
        return window.NativeBridge !== undefined || hasWebkitBridge()
    }

    function hasWebkitBridge(): boolean {
        return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.NativeBridge)
    }

    const emitMessage = (messageJson: string): void => {
        // slice(0) 产生快照副本，遍历期间原 listeners 增删不影响本次分发
        listeners.slice(0).forEach(listener => { listener(messageJson) })
    }

    const emitChannelError = (error: BridgeError): void => {
        channelErrorListeners.slice(0).forEach(listener => { listener(error) })
    }

    const scheduleFlush = (): void => {
        if (flushTimer !== null) { return }
        flushTimer = setTimeout(() => { flushTimer = null; flushQueue() }, 50)
    }

    const flushQueue = (): void => {
        const sender = resolveSender()
        // 无 sender 时不无限续期轮询（legacy-only 宿主经 send() 快速失败，
        // 信道重建路径由 send/onMessage/端口采纳显式触发冲刷）
        if (!sender) { return }
        while (queue.length > 0) { sender(queue.shift()!) }
    }

    /** 轮换粗语义（docs/06 §4.1/§4.3）：采纳新端口与关闭旧端口在同一语句块内同步完成，
     * 无双通道窗口；旧端口关闭时其上 in-flight 下行消息被丢弃，上层超时负责恢复。 */
    const adoptPort = (newPort: MessagePort): void => {
        if (port === newPort) { return }
        const oldPort = port
        port = newPort
        port.onmessage = function(messageEvent: MessageEvent): void { emitMessage(messageEvent.data as string) }
        if (oldPort) {
            oldPort.onmessage = null
            oldPort.close()
        }
        flushQueue()
    }

    const clearRequestTimer = (): void => {
        if (requestTimer !== null) { clearTimeout(requestTimer); requestTimer = null }
    }

    const clearRetryTimer = (): void => {
        if (retryTimer !== null) { clearTimeout(retryTimer); retryTimer = null }
    }

    /** 信道建立失败：通知上层 fail 全部 pending（retryable=true，自愈路径可再触发请求），
     * queue 保留——下次 send() 会重启请求周期（Bfcache/重试自愈，docs/06 §3.1/§5.2）。 */
    const channelFailed = (message: string): void => {
        currentReqId = null
        clearRequestTimer()
        emitChannelError(channelError(BridgeProtocol.ERR_CHANNEL_CLOSED, message, true))
    }

    const scheduleChannelRequest = (delayMs: number): void => {
        clearRetryTimer()
        retryTimer = setTimeout(() => { retryTimer = null; startChannelRequest() }, delayMs)
    }

    /** pull 因果序（docs/06 §1.3）：message 监听在本函数体之外的构造期先挂载，
     * 此处才发起请求——"先挂监听、后发请求"是同函数/同构造块内的语句顺序保证。 */
    const startChannelRequest = (): void => {
        if (port !== null) { return }                       // 已采纳
        if (isResidentChannel()) { return }                // 常驻通道平台豁免
        const bridgeObj = window.__jsbridge2__
        if (!bridgeObj || typeof bridgeObj.requestBridgeChannel !== 'function') {
            // 入口尚未注入（宿主在 onPageFinished 才 bind 的正常时序）或老宿主缺失：
            // 退避重试跨过宿主 bind 时机；耗尽后按入口不存在 fail（docs/04 §3.1 ack 四态）。
            // legacy 路径（API < M，__jsbridge2__.callNativeApi）本就是 pull 形态、无端口：
            // 构造期无法预知 pending（监听尚未挂载）也不轮询死等——首次 send() 时
            // 以 E_CHANNEL_CLOSED 快速失败（见 send() 内 legacy-only 分支）。
            if (window.__jsbridge2__ && typeof window.__jsbridge2__.callNativeApi === 'function') { return }
            if (retryCount + 1 >= maxChannelRetries) {
                channelFailed('requestBridgeChannel entry not available')
                return
            }
            retryCount++
            scheduleChannelRequest(retryBackoffMs)
            return
        }
        const reqId = 'r-' + (++reqCounter) + '-' + Math.random().toString(36).slice(2, 10)
        currentReqId = reqId
        adoptedReqId = null
        let ack: ChannelAck | null = null
        try {
            // 必须以方法调用形式在注入对象上调用（obj.method()），不得解构引用后调用：
            // Android 注入对象的包装层校验 this 绑定，解构引用会抛
            // "Java bridge method can't be invoked on a non-injected object"
            const ackRaw = bridgeObj.requestBridgeChannel(JSON.stringify({ reqId } satisfies ChannelRequestOpts))
            if (typeof ackRaw === 'string' && ackRaw.length > 0) {
                try { ack = JSON.parse(ackRaw) as ChannelAck } catch { ack = null }
            }
        } catch (e) {
            // 入口抛异常属于异常路径：保留 error 级（非诊断噪声）
            console.error('[jsbridge] requestBridgeChannel threw:', e)
        }
        if (ack && typeof ack.error === 'string') {
            // ack 四态之"限频"（退避）——重试换新 reqId；"畸形"本 SDK 不会发出，防御处理同路
            if (retryCount + 1 >= maxChannelRetries) {
                channelFailed('requestBridgeChannel rejected: ' + ack.error)
                return
            }
            retryCount++
            scheduleChannelRequest(retryBackoffMs * retryCount)
            return
        }
        // ack 四态之"成功"必须为显式 {ok:true, reqId:回显匹配}（docs/04 §3.1）：
        // 宿主返回 {ok:false} 而无 error 字段、回显 reqId 不匹配、或 ack 无法解析时，
        // 按无效 ack 处理，换新 reqId 重试
        if (!ack || ack.ok !== true || ack.reqId !== reqId) {
            if (retryCount + 1 >= maxChannelRetries) {
                channelFailed('requestBridgeChannel ack invalid: ' + JSON.stringify(ack))
                return
            }
            retryCount++
            scheduleChannelRequest(retryBackoffMs * retryCount)
            return
        }
        clearRequestTimer()
        requestTimer = setTimeout(() => {
            requestTimer = null
            // 最新请求 T 内无匹配投递 → 换新 reqId 重试（docs/06 §3.1 超时规则）
            if (retryCount + 1 >= maxChannelRetries) {
                channelFailed('channel not established after ' + maxChannelRetries + ' attempts')
                return
            }
            retryCount++
            scheduleChannelRequest(retryBackoffMs)
        }, channelTimeoutMs)
    }

    if (!window.__jsbridge2__) { (window as Window).__jsbridge2__ = {} }
    window.__jsbridge2__!.receive = function(messageJson: string): void { emitMessage(messageJson) }

    // ① 先挂监听（pull 因果序的第一环，随构造执行——构造即正确）
    window.addEventListener('message', (event: MessageEvent) => {
        let envelope: ChannelEventEnvelope | null = null
        if (typeof event.data === 'string' && event.data.length > 0) {
            try { envelope = JSON.parse(event.data) as ChannelEventEnvelope } catch { return }
        } else if (event.data && typeof event.data === 'object') {
            envelope = event.data as ChannelEventEnvelope
        }
        if (!envelope || envelope.type !== BridgeProtocol.CHANNEL_EVENT_TYPE) { return }
        if (!event.ports || !event.ports[0]) { return }
        const deliveredPort = event.ports[0]
        // 投递信任边界（docs/06 §2.2 / docs/09 C59）：bridge:channel 投递只能来自
        // Native 经由主 frame 的注入通道——采纳前必须校验 event.source === window
        //（投递源只能是主 frame 自身）。跨域 iframe 构造的同形事件（source 为
        // iframe 的 window）一律拒绝：关闭其携带端口、不采纳、reqId 路径不受劫持。
        // reqId 是配对凭证而非信任凭证——它可能经 console 等途径泄露，绝不单独作为采纳依据。
        if (event.source !== window) {
            deliveredPort.close()
            return
        }
        const reqId = typeof envelope.reqId === 'string' ? envelope.reqId : ''
        if (currentReqId !== null && reqId === currentReqId && adoptedReqId !== reqId) {
            adoptedReqId = reqId
            retryCount = 0
            clearRequestTimer()
            clearRetryTimer()
            adoptPort(deliveredPort)
            return
        }
        // 陈旧投递（reqId 已被轮换）或同 reqId 重复投递 → 丢弃并关闭端口，防泄漏（docs/06 §2.3/§4.2）
        deliveredPort.close()
    })

    // Bfcache 恢复自愈（docs/06 §5.2）：绕过 onPageFinished 的页面快照恢复，
    // 主动失效旧端口（Native 侧已销毁）并以新 reqId 重新请求
    window.addEventListener('pageshow', (event: PageTransitionEvent) => {
        if (!event.persisted) { return }
        const oldPort = port
        port = null
        adoptedReqId = null
        if (oldPort) {
            oldPort.onmessage = null
            oldPort.close()
            console.warn('[jsbridge] page restored from Bfcache — channel invalidated, re-requesting')
        }
        retryCount = 0
        startChannelRequest()
    })

    // ② 后发请求（因果序第二环）
    startChannelRequest()

    const transport: NativeTransport = {
        send(messageJson: string): void {
            const sender = resolveSender()
            if (sender) { sender(messageJson); return }
            const bridgeObj = window.__jsbridge2__
            const legacyOnlyHost = !!bridgeObj &&
                typeof bridgeObj.callNativeApi === 'function' &&
                typeof bridgeObj.requestBridgeChannel !== 'function' &&
                !isResidentChannel()
            if (legacyOnlyHost) {
                // legacy-only 宿主（仅 __jsbridge2__.callNativeApi）：既无端口也无常驻通道，
                // 不做 50ms 无限轮询死等——直接 onChannelError（E_CHANNEL_CLOSED，
                // message 注明 legacy host）使 pending 快速失败，而非各自拖到超时。
                // 不得先入队再判：legacy-only 宿主的 queue 永远无法 flush，先入队=线性泄漏
                channelFailed('legacy host (only __jsbridge2__.callNativeApi): channel unavailable')
                return
            }
            queue.push(messageJson)
            if (currentReqId === null && port === null && !isResidentChannel()) {
                // 信道此前已失败（或尚未启动）→ 重启请求周期（自愈，retryable 语义）
                retryCount = 0
                startChannelRequest()
            } else {
                scheduleFlush()
            }
        },
        onMessage(listener: (messageJson: string) => void): void {
            // 注册幂等：同一 listener 重复注册不产生重复分发
            if (listeners.indexOf(listener) === -1) { listeners.push(listener) }
            flushQueue()
        },
        onChannelError(listener: (error: BridgeError) => void): void {
            if (channelErrorListeners.indexOf(listener) === -1) { channelErrorListeners.push(listener) }
        },
        removeOnMessage(listener: (messageJson: string) => void): void {
            const index = listeners.indexOf(listener)
            if (index !== -1) { listeners.splice(index, 1) }
        },
        removeChannelErrorListener(listener: (error: BridgeError) => void): void {
            const index = channelErrorListeners.indexOf(listener)
            if (index !== -1) { channelErrorListeners.splice(index, 1) }
        },
    }

    sharedTransport = transport
    return transport
}
