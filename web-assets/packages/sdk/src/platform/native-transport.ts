export interface NativeTransport {
    send(messageJson: string): void
    onMessage(listener: (messageJson: string) => void): void
}

declare global {
    interface Window {
        __bridgeReceiveFromNative?: (messageJson: string) => void
        NativeBridge?: { postMessage: (messageJson: string) => void }
        webkit?: {
            messageHandlers?: {
                NativeBridge?: { postMessage: (messageJson: string) => void }
            }
        }
        $__native__?: { callNativeApi: (messageJson: string) => void }
    }
}

export function createNativeTransport(): NativeTransport {
    let port: MessagePort | null = null
    const queue: string[] = []
    const listeners: Array<(messageJson: string) => void> = []
    let flushTimer: ReturnType<typeof setTimeout> | null = null

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
        if (window.$__native__ && typeof window.$__native__.callNativeApi === 'function') {
            return messageJson => window.$__native__!.callNativeApi(messageJson)
        }
        return null
    }

    const emitMessage = (messageJson: string): void => {
        for (const listener of listeners) { listener(messageJson) }
    }

    const scheduleFlush = (): void => {
        if (flushTimer !== null) { return }
        flushTimer = setTimeout(() => { flushTimer = null; flushQueue() }, 50)
    }

    const flushQueue = (): void => {
        const sender = resolveSender()
        if (!sender) {
            if (queue.length > 0) { scheduleFlush() }
            return
        }
        while (queue.length > 0) { sender(queue.shift()!) }
    }

    window.__bridgeReceiveFromNative = function(messageJson: string): void { emitMessage(messageJson) }

    window.addEventListener('message', (event: MessageEvent) => {
        if (event.data !== 'bridge:init') { return }
        if (!event.ports || !event.ports[0]) { return }
        port = event.ports[0]
        port.onmessage = function(messageEvent: MessageEvent): void { emitMessage(messageEvent.data as string) }
        flushQueue()
    })

    return {
        send(messageJson: string): void {
            const sender = resolveSender()
            if (sender) { sender(messageJson); return }
            queue.push(messageJson)
            scheduleFlush()
        },
        onMessage(listener: (messageJson: string) => void): void {
            listeners.push(listener)
            flushQueue()
        },
    }
}
