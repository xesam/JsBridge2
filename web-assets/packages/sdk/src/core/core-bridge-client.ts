import { BridgeProtocol } from './protocol.js'

export interface Transport {
    send(messageJson: string): void
}

export interface BridgeError {
    code: string
    message: string
    retryable: boolean
    details: Record<string, unknown>
}

export interface CallOptions {
    success?: (payload: unknown) => void
    fail?: (error: BridgeError) => void
    timeoutMs?: number
    keep?: boolean
    signal?: AbortSignal
    [key: string]: unknown
}

interface BridgeRequest {
    id: string
    sessionId: string
    kind: string
    method: string
    ts: number
    timeoutMs: number
    keep: boolean
    payload: Record<string, unknown>
    reqId: null
    done: null
    ok: null
    error: null
}

export interface PendingEntry {
    request: BridgeRequest
    success: ((payload: unknown) => void) | undefined
    fail: ((error: BridgeError) => void) | undefined
    keep: boolean
    timeoutMs: number
    timeoutHandle: ReturnType<typeof setTimeout> | null
    signal?: AbortSignal
    onAbort?: () => void
}

interface SettledEntry {
    reason: string
    expiresAt: number
}

interface IncomingMessage {
    kind: string
    method?: string
    sessionId?: string
    reqId?: string
    done?: boolean
    ok?: boolean
    payload?: unknown
    error?: BridgeError
}

export class CoreBridgeClient {
    #transport: Transport
    #sessionId: string
    #pendingMap = new Map<string, PendingEntry>()
    #settledMap = new Map<string, SettledEntry>()
    #seq = 0
    #eventHandlers = new Map<string, (payload: unknown) => void>()
    #settledTtlMs = 60000
    #settledMaxSize = 1000

    constructor(transport: Transport, sessionId = '') {
        this.#transport = transport
        this.#sessionId = typeof sessionId === 'string' ? sessionId : ''
    }

    setSessionId(sessionId: string): void {
        this.#sessionId = typeof sessionId === 'string' ? sessionId : ''
    }

    getSessionId(): string {
        return this.#sessionId
    }

    registerEventHandler(
        method: string,
        handler: (payload: unknown) => void,
        signal?: AbortSignal,
    ): void {
        if (typeof method !== 'string' || method.length === 0) {
            throw new Error('event method must be non-empty string')
        }
        if (typeof handler !== 'function') {
            throw new Error('event handler must be function')
        }
        this.#eventHandlers.set(method, handler)
        if (signal) {
            const onAbort = (): void => {
                if (this.#eventHandlers.get(method) === handler) {
                    this.#eventHandlers.delete(method)
                }
            }
            signal.addEventListener('abort', onAbort, { once: true })
        }
    }

    callNativeApi(method: string, data?: CallOptions, overrideSessionId?: string): void {
        this.#cleanupSettled()
        if (typeof method !== 'string' || method.length === 0) {
            throw new Error('method must be non-empty string')
        }

        const requestData = data ?? {}
        const success = requestData.success
        const fail = requestData.fail
        const timeoutMs = typeof requestData.timeoutMs === 'number' ? requestData.timeoutMs : 10000
        const keep = requestData.keep === true
        const signal = requestData.signal

        const payload: Record<string, unknown> = { ...requestData }
        delete payload.success
        delete payload.fail
        delete payload.timeoutMs
        delete payload.keep
        delete payload.signal

        if (signal?.aborted) {
            if (typeof fail === 'function') {
                try {
                    fail({
                        code: BridgeProtocol.ERR_CANCELED,
                        message: `Request canceled: ${method}`,
                        retryable: true,
                        details: {},
                    })
                } catch (callbackError) {
                    console.error('fail callback error', callbackError)
                }
            }
            return
        }

        const request: BridgeRequest = {
            id: this.#nextId(),
            sessionId: typeof overrideSessionId === 'string' ? overrideSessionId : this.#sessionId,
            kind: BridgeProtocol.KIND_REQUEST,
            method,
            ts: Date.now(),
            timeoutMs,
            keep,
            payload,
            reqId: null,
            done: null,
            ok: null,
            error: null,
        }

        // 序列化先行：失败（如 payload 含循环引用）→ 本地 fail E_INTERNAL，
        // 且零残留——此时尚未挂监听/定时器/入表，不存在僵尸 pending（docs/09 C57 变体）。
        let requestJson: string
        try {
            requestJson = JSON.stringify(request)
        } catch (error) {
            this.#invokeFail(
                { request, success, fail, keep, timeoutMs, timeoutHandle: null } as PendingEntry,
                {
                    code: BridgeProtocol.ERR_INTERNAL,
                    message: `Request serialize failed: ${method}`,
                    retryable: false,
                    details: {},
                },
            )
            return
        }

        const failLocal = (pending: PendingEntry, error: BridgeError): void => {
            // 完整清理 + 落定标记在回调之前（与流/终帧落定路径同一顺序语义）
            this.#clearTimer(pending.timeoutHandle)
            this.#detachAbortListener(pending)
            this.#pendingMap.delete(pending.request.id)
            this.#markSettled(pending.request.id, 'send-failed')
            this.#invokeFail(pending, error)
        }

        const timeoutHandle = this.#armTimeout(request.id, request.method, timeoutMs)

        const onAbort = (): void => {
            const pending = this.#pendingMap.get(request.id)
            if (!pending) { return }
            this.#clearTimer(pending.timeoutHandle)
            this.#pendingMap.delete(request.id)
            this.#markSettled(request.id, 'canceled')
            this.#invokeFail(pending, {
                code: BridgeProtocol.ERR_CANCELED,
                message: `Request canceled: ${request.method}`,
                retryable: true,
                details: {},
            })
        }

        if (signal) {
            signal.addEventListener('abort', onAbort, { once: true })
        }

        this.#pendingMap.set(request.id, {
            request,
            success,
            fail,
            keep,
            timeoutMs,
            timeoutHandle,
            signal,
            onAbort,
        })

        // send 抛异常同样不得残留：完整清理（clearTimer/detach/delete/markSettled）
        // 后本地 fail E_INTERNAL——留一条带活定时器的僵尸条目会让迟到帧/超时表现出
        // 与真实请求一致的行为，掩盖故障类别（docs/09 C57 变体）。
        try {
            this.#transport.send(requestJson)
        } catch (error) {
            const pending = this.#pendingMap.get(request.id)
            if (pending) {
                failLocal(pending, {
                    code: BridgeProtocol.ERR_INTERNAL,
                    message: `Transport send failed: ${method}`,
                    retryable: false,
                    details: {},
                })
            }
        }
    }

    handleIncomingMessage(messageJsonString: string): void {
        this.#cleanupSettled()
        const message = this.#parseMessage(messageJsonString)
        if (!message) { return }

        if (message.kind === BridgeProtocol.KIND_EVENT) {
            this.#handleEvent(message)
            return
        }

        if (message.kind === BridgeProtocol.KIND_RESPONSE) {
            this.#handleResponse(message)
            return
        }

        // C50（docs/09 §3）：reqId 可关联但被放弃的入站消息，立即失败关联请求，
        // 而非放任其等待超时（E_TIMEOUT 会伪装真实故障类别）。
        this.#failUndeliverablePending(message)
    }

    #nextId(): string {
        this.#seq += 1
        return `${Date.now()}_${this.#seq}_${Math.random().toString(36).slice(2, 8)}`
    }

    #parseMessage(messageJsonString: string): IncomingMessage | null {
        if (typeof messageJsonString !== 'string' || messageJsonString.length === 0) {
            // 字节级不可处理 → 结构上无法关联请求，只能丢弃
            console.error('invalid message body', messageJsonString)
            return null
        }
        try {
            const message = JSON.parse(messageJsonString) as unknown
            if (!message || typeof message !== 'object') {
                console.error('invalid message object', messageJsonString)
                return null
            }
            return message as IncomingMessage
        } catch (_error) {
            console.error('invalid message json', messageJsonString)
            return null
        }
    }

    /** 入站消息 kind 未知/缺失，但 reqId 可关联到挂起请求 → 立即快速失败（E_INTERNAL）。
     * reqId 无法关联（缺失 / 非 pending）时维持原静默忽略——快速失败只针对「本可以送达、
     * 却因消息形态被放弃」的请求。 */
    #failUndeliverablePending(message: IncomingMessage): void {
        if (typeof message.reqId !== 'string' || message.reqId.length === 0) { return }
        const pending = this.#pendingMap.get(message.reqId)
        if (!pending) { return }
        this.#clearTimer(pending.timeoutHandle)
        this.#detachAbortListener(pending)
        this.#pendingMap.delete(message.reqId)
        this.#markSettled(message.reqId, 'undeliverable')
        this.#invokeFail(pending, {
            code: BridgeProtocol.ERR_INTERNAL,
            message: `Undeliverable response (unsupported kind=${String(message.kind)}): ${pending.request.method}`,
            retryable: false,
            details: {},
        })
    }

    #createTimeout(requestId: string, requestMethod: string, timeoutMs: number): ReturnType<typeof setTimeout> {
        return setTimeout(() => {
            const pending = this.#pendingMap.get(requestId)
            if (!pending) { return }
            this.#detachAbortListener(pending)
            this.#pendingMap.delete(requestId)
            this.#markSettled(requestId, 'timeout')
            this.#invokeFail(pending, {
                code: BridgeProtocol.ERR_TIMEOUT,
                message: `Request timeout: ${requestMethod}`,
                retryable: true,
                details: {},
            })
        }, timeoutMs)
    }

    // 协议 v1 语义：!(timeoutMs > 0) 表示不超时，不创建定时器（含 NaN、0、负数）；正数才挂载超时
    #armTimeout(requestId: string, requestMethod: string, timeoutMs: number): ReturnType<typeof setTimeout> | null {
        if (!(timeoutMs > 0)) {
            return null
        }
        return this.#createTimeout(requestId, requestMethod, timeoutMs)
    }

    #clearTimer(handle: ReturnType<typeof setTimeout> | null): void {
        if (handle !== null) {
            clearTimeout(handle)
        }
    }

    #detachAbortListener(pending: PendingEntry): void {
        if (pending.signal && pending.onAbort) {
            pending.signal.removeEventListener('abort', pending.onAbort)
        }
    }

    /** 用户回调统一收口：异常捕获后 console.error，不向 transport 调用方穿透
     * （用户回调抛异常不得破坏落定状态，docs/09 C57）。 */
    #invokeFail(pending: PendingEntry, error: BridgeError): void {
        if (typeof pending.fail === 'function') {
            try {
                pending.fail(error)
            } catch (callbackError) {
                console.error('fail callback error', callbackError, 'originError=', error.code)
            }
        }
    }

    #invokeSuccess(pending: PendingEntry, payload: unknown): void {
        if (typeof pending.success === 'function') {
            try {
                pending.success(payload)
            } catch (callbackError) {
                console.error('success callback error', callbackError)
            }
        }
    }

    #validateResponseMessage(message: IncomingMessage): PendingEntry | null {
        if (typeof message.reqId !== 'string' || message.reqId.length === 0) {
            return null
        }
        if (this.#settledMap.has(message.reqId)) {
            const settled = this.#settledMap.get(message.reqId)!
            // 该日志被 conformance C21 依赖（TTL 内迟到帧被 settled 条目拦截），勿删
            console.log('late response dropped', { reqId: message.reqId, reason: settled.reason })
            return null
        }
        const pending = this.#pendingMap.get(message.reqId)
        if (!pending) {
            // 该日志被 conformance C21 依赖（TTL 过期后迟到帧重新归类为 pending-not-found），勿删
            console.log(`pending callback not found: ${message.reqId}`)
            return null
        }
        return pending
    }

    /** 落定路径统一顺序语义：清理（clearTimer/detach/delete/markSettled）先于用户回调
     * （与 #createTimeout / onAbort / #failUndeliverablePending / failAllPending 一致）。
     * 回调抛异常由 #invokeSuccess / #invokeFail 捕获，不向 transport 调用方穿透，
     * 也不破坏落定状态（docs/09 C57）。 */
    #handleResponse(message: IncomingMessage): void {
        const pending = this.#validateResponseMessage(message)
        if (!pending) { return }

        // 会话错配（跨会话串扰）fail-fast 落定（对齐 C50 精确失败）：
        // reqId 已关联到本 pending，静默丢弃会把真实故障伪装成 E_TIMEOUT，且连日志都没有
        const responseSession = typeof message.sessionId === 'string' ? message.sessionId : ''
        const requestSession = typeof pending.request.sessionId === 'string' ? pending.request.sessionId : ''
        if (requestSession && responseSession && responseSession !== requestSession) {
            this.#clearTimer(pending.timeoutHandle)
            this.#detachAbortListener(pending)
            this.#pendingMap.delete(message.reqId!)
            this.#markSettled(message.reqId!, 'session-mismatch')
            console.log('response session mismatch', {
                reqId: message.reqId,
                requestSession,
                responseSession,
            })
            this.#invokeFail(pending, {
                code: BridgeProtocol.ERR_SESSION_INVALID,
                message: `Response session mismatch: expected ${requestSession}, got ${responseSession}`,
                retryable: false,
                details: {},
            })
            return
        }

        // 流帧仅指 ok=true 的成功续流帧：ok=false 且 done=false 属协议违例形态，
        // docs/03 §4.3 规定流中错误必须 done=true 终结——fail 帧一律按终帧行为
        // 落定（至多触发一次 fail，不再因流保持存活而重复失败或再补发 E_TIMEOUT）
        const streamContinues = message.done === false && pending.keep === true && message.ok === true
        if (streamContinues) {
            // 流帧（守卫已含 ok===true）：先清旧定时器并续期，再投递回调——
            // 回调抛异常不影响后续帧
            this.#clearTimer(pending.timeoutHandle)
            pending.timeoutHandle = this.#armTimeout(pending.request.id, pending.request.method, pending.timeoutMs)
            this.#invokeSuccess(pending, message.payload)
            return
        }

        // 终帧：先清理 + 落定标记，再投递回调——迟到同 reqId 帧由 settled 机制丢弃
        this.#clearTimer(pending.timeoutHandle)
        this.#detachAbortListener(pending)
        this.#pendingMap.delete(message.reqId!)
        this.#markSettled(message.reqId!, 'completed')

        if (message.ok === true) {
            this.#invokeSuccess(pending, message.payload)
        } else {
            this.#invokeFail(pending, message.error ?? {
                code: BridgeProtocol.ERR_INTERNAL,
                message: `Request failed without error: ${pending.request.method}`,
                retryable: false,
                details: {},
            })
        }
    }

    #handleEvent(message: IncomingMessage): void {
        if (typeof message.method !== 'string' || message.method.length === 0) {
            return
        }
        const incomingSession = typeof message.sessionId === 'string' ? message.sessionId : ''
        if (this.#sessionId && incomingSession && incomingSession !== this.#sessionId) {
            return
        }
        const handler = this.#eventHandlers.get(message.method)
        if (typeof handler === 'function') {
            try {
                handler(message.payload)
            } catch (callbackError) {
                // 事件回调异常收口（与 #invokeSuccess/#invokeFail 的 C57 收口对称）：
                // 事件回调不经 try/catch 会沿 native-transport 收包循环穿透为 uncaught
                // error，并中断同一投递批次中后续 listener
                console.error('event handler error', callbackError, 'method=', message.method)
            }
            return
        }
    }

    #markSettled(requestId: string, reason: string): void {
        if (this.#settledMap.size >= this.#settledMaxSize) {
            this.#cleanupSettled()
        }
        this.#settledMap.set(requestId, { reason, expiresAt: Date.now() + this.#settledTtlMs })
    }

    #cleanupSettled(): void {
        const now = Date.now()
        // forEach 普通遍历（删除当前项安全），避免 for..of 的迭代协议依赖
        this.#settledMap.forEach((settled, requestId) => {
            if (settled.expiresAt <= now) { this.#settledMap.delete(requestId) }
        })
    }

    /** 信道建立失败时由 transport 经 web-entry 调用，将全部 pending 请求以指定错误 fail
     * （如 E_CHANNEL_CLOSED）——相比各自等到超时（E_TIMEOUT）更精确、更快，且错误码可指导
     * 自救策略（退避重试建通道）。
     * 使用 Map.forEach 普通遍历（删除当前项对 forEach 安全）。 */
    failAllPending(error: BridgeError): void {
        this.#pendingMap.forEach((pending, requestId) => {
            this.#clearTimer(pending.timeoutHandle)
            this.#detachAbortListener(pending)
            this.#pendingMap.delete(requestId)
            this.#markSettled(requestId, 'channel-closed')
            this.#invokeFail(pending, error)
        })
    }
}
