import Foundation

// MARK: - Handler API

/// Simple Handler: 单帧响应，通信在 handler 返回时结束（done 恒为 true）。
/// 第一个形参是内核派生并注入的页面上下文。
public typealias SimpleHandler = (TrustedPageContext, JSONValue?) throws -> BridgeHandlerResult

/// Response Emitter: 异步多响应发送器
public typealias ResponseEmitter = @Sendable (Result<JSONValue?, BridgeError>, Bool) async -> Void

/// Async Handler: 带 ResponseEmitter 参数，可在返回后继续推帧。
/// 多帧响应的唯一表达方式。第一个形参是内核派生并注入的页面上下文。
public typealias AsyncHandler = @Sendable (TrustedPageContext, JSONValue?, ResponseEmitter?) async throws -> Void

public enum BridgeHandlerResult {
    case success(JSONValue?)
    case failure(BridgeError)
}

/// Tier 1 — 核心协议层。纯消息分发，零 security 依赖。
/// 提供 handler 注册、分发、响应构建和事件推送。
///
/// 并发模型：register/dispatch 可跨线程发生，全部可变状态（`transport` / `handlers` /
/// `_sendFailureCount`）经同一把 `NSLock` 保护；回调（handler / transport.send）恒在锁外调用，
/// 避免用户回调重入Bridge内核时死锁。`@unchecked Sendable` 的保证即来自该锁，
/// 而非"确认无共享可变状态"。
public final class CoreBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: BridgeTransport?

    // 内部统一 handler 存储：区分同步（单帧）和异步（可多帧）
    private enum InternalHandler {
        case sync((TrustedPageContext, JSONValue?) throws -> BridgeHandlerResult)
        case async(AsyncHandler)
    }

    private var handlers: [String: InternalHandler] = [:]
    /// 发送链失败计数（只写计数，供调试观测；可观测性由 postEvent 返回值断言
    /// 承载，见 conformance C17）。
    private var _sendFailureCount: Int = 0

    public init(transport: BridgeTransport? = nil) {
        self.transport = transport
    }

    public func attachTransport(_ transport: BridgeTransport?) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    /// 供 JsBridge.bindTransport() 调用：将入站回调绑定到 transport。
    internal func bindTransportListener(_ listener: @escaping (String) -> Void) {
        lock.lock()
        let currentTransport = transport
        lock.unlock()
        currentTransport?.bind(listener: listener)
    }

    /// 通过已绑定的 transport 发送预构建的 JSON 字符串。
    /// 供 bindTransport 闭环使用；与 Android 的 respondSuccess/respondFail 对齐。
    @discardableResult
    public func sendViaTransport(_ messageJson: String) -> Bool {
        lock.lock()
        let currentTransport = transport
        lock.unlock()
        guard let currentTransport else {
            recordSendFailure("sendViaTransport: no transport attached")
            return false
        }
        let sent = currentTransport.send(messageJson)
        if !sent {
            recordSendFailure("sendViaTransport: transport.send returned false")
        }
        return sent
    }

    /// 发送链失败计数 + 审计日志（锁外打印，避免持锁做 IO）。
    private func recordSendFailure(_ reason: String) {
        lock.lock()
        _sendFailureCount += 1
        lock.unlock()
        print("[JsBridge] send failure: \(reason)")
    }

    // MARK: - Handler Registration

    /// Register a Simple Handler: single-response, communication ends when handler returns.
    /// 同一 method 重复注册时**后者覆盖前者**（last wins）。
    public func registerSimpleHandler(method: String, handler: @escaping SimpleHandler) {
        lock.lock()
        handlers[method] = .sync(handler)
        lock.unlock()
    }

    /// Register an Async Handler: multi-response with ResponseEmitter, can push frames after return.
    /// 多帧响应的唯一表达方式；同一 method 重复注册时**后者覆盖前者**（last wins）。
    public func registerAsyncHandler(method: String, handler: @escaping AsyncHandler) {
        lock.lock()
        handlers[method] = .async(handler)
        lock.unlock()
    }

    // MARK: - Dispatch（纯分发，无策略）

    public func dispatch(request: BridgeMessage, context: TrustedPageContext) -> [String] {
        // Tier-1 kind 路由守卫（docs/09 C64 / docs/08 dispatch 契约）：仅 request 信封参与派发。
        // response/event 是 Native→JS 方向（docs/03 §1），standalone 使用 CoreBridge 时按 method
        // 命中同名 handler 属协议路由错误而非"无策略"自由；JsBridge 路径已在策略链
        // RequestShapePolicy 先行拒绝，此处为 belt-and-braces。
        guard request.kind == .request else {
            print("[JsBridge] dispatch dropped: non-request kind=\(request.kind.rawValue) method=\(request.method) reqId=\(request.reqId ?? "nil")")
            return []
        }
        // 拷贝出 handler 后立即释放锁：用户回调恒在锁外执行，避免重入死锁
        lock.lock()
        let handler = handlers[request.method]
        lock.unlock()

        guard let handler else {
            return serializeResponses([failResponse(for: request, error: BridgeError(
                code: BridgeApiContract.errorMethodNotFound,
                message: "Method not found: \(request.method)"
            ))])
        }

        switch handler {
        case .sync(let syncHandler):
            // 同步 handler：直接调用并返回单帧结果（done 恒为 true）
            do {
                let result = try syncHandler(context, request.payload)
                switch result {
                case .success(let payload):
                    return serializeResponses([successResponse(for: request, payload: payload, done: true)])
                case .failure(let error):
                    return serializeResponses([failResponse(for: request, error: error)])
                }
            } catch {
                return serializeResponses([failResponse(for: request, error: BridgeError(
                    code: BridgeApiContract.errorInternal,
                    message: "handler exception: \(error.localizedDescription)"
                ))])
            }

        case .async(let asyncHandler):
            // 异步 handler：启动 Task，dispatch 立即返回空数组
            // 复制 request 数据避免 Swift 6 并发检查错误
            let requestId = request.id
            let sessionId = request.sessionId
            let method = request.method
            let timeoutMs = request.timeoutMs
            let keep = request.keep
            let payload = request.payload
            let origin = context.origin
            let pageInstanceId = context.pageInstanceId

            Task { [weak self] in
                guard let self else { return }
                let context = TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId)

                let emitter: ResponseEmitter = { [weak self] result, done in
                    guard let self else { return }
                    
                    let response: BridgeMessage
                    switch result {
                    case .success(let responsePayload):
                        response = BridgeMessage(
                            id: UUID().uuidString,
                            sessionId: sessionId,
                            kind: .response,
                            method: method,
                            timeoutMs: timeoutMs,
                            keep: keep,
                            payload: responsePayload,
                            reqId: requestId,
                            done: done,
                            ok: true,
                            error: nil
                        )
                    case .failure(let error):
                        response = BridgeMessage(
                            id: UUID().uuidString,
                            sessionId: sessionId,
                            kind: .response,
                            method: method,
                            timeoutMs: timeoutMs,
                            keep: keep,
                            payload: nil,
                            reqId: requestId,
                            done: true,
                            ok: false,
                            error: error
                        )
                    }
                    
                    guard let json = response.toJsonString() else {
                        self.recordSendFailure("response serialization failed: kind=\(response.kind.rawValue) method=\(response.method) reqId=\(response.reqId ?? "nil")")
                        return
                    }
                    _ = self.sendViaTransport(json)
                }
                
                do {
                    try await asyncHandler(context, payload, emitter)
                } catch {
                    let errorResponse = BridgeMessage(
                        id: UUID().uuidString,
                        sessionId: sessionId,
                        kind: .response,
                        method: method,
                        timeoutMs: timeoutMs,
                        keep: keep,
                        payload: nil,
                        reqId: requestId,
                        done: true,
                        ok: false,
                        error: BridgeError(
                            code: BridgeApiContract.errorInternal,
                            message: "async handler exception: \(error.localizedDescription)"
                        )
                    )
                    guard let json = errorResponse.toJsonString() else {
                        self.recordSendFailure("async handler exception response serialization failed: reqId=\(requestId)")
                        return
                    }
                    _ = self.sendViaTransport(json)
                }
            }
            
            return []
        }
    }

    // MARK: - Event

    public func postEvent(method: String, payload: JSONValue?) -> Bool {
        lock.lock()
        let currentTransport = transport
        lock.unlock()
        guard let currentTransport else {
            recordSendFailure("postEvent: no transport attached")
            return false
        }
        let event = BridgeMessage(
            id: UUID().uuidString,
            // 事件帧 sessionId 恒为空串 = 广播（C22 空串语义；v1 唯一形态，无定向投送入口，验收锚点 C55）
            sessionId: "",
            kind: .event,
            method: method,
            payload: payload
        )
        guard let json = event.toJsonString() else {
            recordSendFailure("postEvent: event serialization failed: method=\(method)")
            return false
        }
        let sent = currentTransport.send(json)
        if !sent {
            recordSendFailure("postEvent: transport.send returned false: method=\(method)")
        }
        return sent
    }

    // MARK: - Response Serialization

    /// 响应序列化出口（dispatch 与 JsBridge 复用）：
    /// 编码失败的帧计入 sendFailureCount 并留日志（对齐 Android 行为）。
    internal func serializeResponses(_ responses: [BridgeMessage]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(responses.count)
        for response in responses {
            if let json = response.toJsonString() {
                out.append(json)
            } else {
                recordSendFailure("response serialization failed: kind=\(response.kind.rawValue) method=\(response.method) reqId=\(response.reqId ?? "nil")")
            }
        }
        return out
    }

    // MARK: - Response Builders

    public func successResponse(for request: BridgeMessage, payload: JSONValue?, done: Bool) -> BridgeMessage {
        BridgeMessage(
            id: UUID().uuidString,
            sessionId: request.sessionId,
            kind: .response,
            method: request.method,
            timeoutMs: request.timeoutMs,
            keep: request.keep,
            payload: payload,
            reqId: request.id,
            done: done,
            ok: true,
            error: nil
        )
    }

    public func failResponse(for request: BridgeMessage, error: BridgeError) -> BridgeMessage {
        BridgeMessage(
            id: UUID().uuidString,
            sessionId: request.sessionId,
            kind: .response,
            method: request.method,
            timeoutMs: request.timeoutMs,
            keep: request.keep,
            payload: nil,
            reqId: request.id,
            done: true,
            ok: false,
            error: error
        )
    }

    // MARK: - Lifecycle

    public func destroy() {
        lock.lock()
        let currentTransport = transport
        lock.unlock()
        currentTransport?.close()
    }
}
