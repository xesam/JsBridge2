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
    timeoutHandle: ReturnType<typeof setTimeout>
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

export class BridgeClient {
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
                fail({
                    code: BridgeProtocol.ERR_CANCELED,
                    message: `Request canceled: ${method}`,
                    retryable: true,
                    details: {},
                })
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

        const timeoutHandle = this.#createTimeout(request.id, request.method, timeoutMs)

        const onAbort = (): void => {
            const pending = this.#pendingMap.get(request.id)
            if (!pending) { return }
            clearTimeout(pending.timeoutHandle)
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

        this.#transport.send(JSON.stringify(request))
    }

    callNativeApiWithSession(method: string, data?: CallOptions, sessionId?: string): void {
        this.callNativeApi(method, data, sessionId)
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

        console.log(`ignore message kind=${String(message.kind)}`)
    }

    #nextId(): string {
        this.#seq += 1
        return `${Date.now()}_${this.#seq}_${Math.random().toString(36).slice(2, 8)}`
    }

    #parseMessage(messageJsonString: string): IncomingMessage | null {
        if (typeof messageJsonString !== 'string' || messageJsonString.length === 0) {
            console.log('invalid message body', messageJsonString)
            return null
        }
        try {
            const message = JSON.parse(messageJsonString) as unknown
            if (!message || typeof message !== 'object') {
                console.log('invalid message object', messageJsonString)
                return null
            }
            return message as IncomingMessage
        } catch (_error) {
            console.log('invalid message json', messageJsonString)
            return null
        }
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

    #detachAbortListener(pending: PendingEntry): void {
        if (pending.signal && pending.onAbort) {
            pending.signal.removeEventListener('abort', pending.onAbort)
        }
    }

    #invokeFail(pending: PendingEntry, error: BridgeError): void {
        if (typeof pending.fail === 'function') { pending.fail(error) }
    }

    #invokeSuccess(pending: PendingEntry, payload: unknown): void {
        if (typeof pending.success === 'function') { pending.success(payload) }
    }

    #validateResponseMessage(message: IncomingMessage): PendingEntry | null {
        if (typeof message.reqId !== 'string' || message.reqId.length === 0) {
            console.log('ignore response without reqId', message)
            return null
        }
        if (this.#settledMap.has(message.reqId)) {
            const settled = this.#settledMap.get(message.reqId)!
            console.log('late response dropped', { reqId: message.reqId, reason: settled.reason })
            return null
        }
        const pending = this.#pendingMap.get(message.reqId)
        if (!pending) {
            console.log(`pending callback not found: ${message.reqId}`)
            return null
        }
        const responseSession = typeof message.sessionId === 'string' ? message.sessionId : ''
        const requestSession = typeof pending.request.sessionId === 'string' ? pending.request.sessionId : ''
        if (requestSession && responseSession && responseSession !== requestSession) {
            console.log('ignore response session mismatch', { reqId: message.reqId, requestSession, responseSession })
            return null
        }
        return pending
    }

    #handleResponse(message: IncomingMessage): void {
        const pending = this.#validateResponseMessage(message)
        if (!pending) { return }

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

        const streamContinues = message.done === false && pending.keep === true
        if (streamContinues) {
            clearTimeout(pending.timeoutHandle)
            pending.timeoutHandle = this.#createTimeout(pending.request.id, pending.request.method, pending.timeoutMs)
            return
        }

        clearTimeout(pending.timeoutHandle)
        this.#detachAbortListener(pending)
        this.#pendingMap.delete(message.reqId!)
        this.#markSettled(message.reqId!, 'completed')
    }

    #handleEvent(message: IncomingMessage): void {
        if (typeof message.method !== 'string' || message.method.length === 0) {
            console.log('ignore event without method', message)
            return
        }
        const incomingSession = typeof message.sessionId === 'string' ? message.sessionId : ''
        if (this.#sessionId && incomingSession && incomingSession !== this.#sessionId) {
            console.log('ignore event session mismatch', { method: message.method, expectedSession: this.#sessionId, incomingSession })
            return
        }
        const handler = this.#eventHandlers.get(message.method)
        if (typeof handler === 'function') {
            handler(message.payload)
            return
        }
        console.log(`ignore event method=${message.method}`)
    }

    #markSettled(requestId: string, reason: string): void {
        if (this.#settledMap.size >= this.#settledMaxSize) {
            this.#cleanupSettled()
        }
        this.#settledMap.set(requestId, { reason, expiresAt: Date.now() + this.#settledTtlMs })
    }

    #cleanupSettled(): void {
        const now = Date.now()
        for (const [requestId, settled] of this.#settledMap.entries()) {
            if (settled.expiresAt <= now) { this.#settledMap.delete(requestId) }
        }
    }
}
