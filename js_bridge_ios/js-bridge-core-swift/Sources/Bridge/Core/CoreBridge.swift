import Foundation

/// 业务 handler（与 Page 解耦）：仅接收 payload，不感知 TrustedPageContext。
public typealias NativeRequestHandler = (JSONValue?) throws -> Result<JSONValue?, BridgeError>
/// 需要 Page 上下文的高级 handler：显式接收 TrustedPageContext。
public typealias NativeRequestHandlerWithContext = (TrustedPageContext, JSONValue?) throws -> Result<JSONValue?, BridgeError>
/// 流式 handler（与 Page 解耦）：仅接收 payload。
public typealias NativeStreamingHandler = (JSONValue?) throws -> [BridgeHandlerResult]
/// 需要 Page 上下文的高级流式 handler。
public typealias NativeStreamingHandlerWithContext = (TrustedPageContext, JSONValue?) throws -> [BridgeHandlerResult]

public enum BridgeHandlerResult {
    case success(JSONValue?, done: Bool)
    case failure(BridgeError)
}

/// Tier 1 — 核心协议层。纯消息分发，零 security 依赖。
/// 提供 handler 注册、分发、响应构建和事件推送。
public final class CoreBridge {
    private var transport: BridgeTransport?
    private var handlers: [String: NativeStreamingHandlerWithContext] = [:]
    public private(set) var sendFailureCount: Int = 0

    public init(transport: BridgeTransport? = nil) {
        self.transport = transport
    }

    public func attachTransport(_ transport: BridgeTransport?) {
        self.transport = transport
    }

    /// 供 JsBridge.bindTransport() 调用：将入站回调绑定到 transport。
    internal func bindTransportListener(_ listener: @escaping (String) -> Void) {
        transport?.bind(listener: listener)
    }

    /// 通过已绑定的 transport 发送预构建的 JSON 字符串。
    /// 供 bindTransport 闭环使用；与 Android 的 respondSuccess/respondFail 对齐。
    @discardableResult
    public func sendViaTransport(_ messageJson: String) -> Bool {
        guard let transport else {
            sendFailureCount += 1
            return false
        }
        let sent = transport.send(messageJson)
        if !sent {
            sendFailureCount += 1
        }
        return sent
    }

    // MARK: - Handler Registration

    public func registerHandler(method: String, handler: @escaping NativeRequestHandler) {
        handlers[method] = { _, payload in
            let result = try handler(payload)
            switch result {
            case .success(let value):
                return [.success(value, done: true)]
            case .failure(let error):
                return [.failure(error)]
            }
        }
    }

    public func registerHandlerWithContext(method: String, handler: @escaping NativeRequestHandlerWithContext) {
        handlers[method] = { context, payload in
            let result = try handler(context, payload)
            switch result {
            case .success(let value):
                return [.success(value, done: true)]
            case .failure(let error):
                return [.failure(error)]
            }
        }
    }

    public func registerStreamingHandler(method: String, handler: @escaping NativeStreamingHandler) {
        handlers[method] = { _, payload in
            try handler(payload)
        }
    }

    public func registerStreamingHandlerWithContext(method: String, handler: @escaping NativeStreamingHandlerWithContext) {
        handlers[method] = handler
    }

    // MARK: - Dispatch（纯分发，无策略）

    public func dispatch(request: BridgeMessage, context: TrustedPageContext) -> [String] {
        guard let handler = handlers[request.method] else {
            return [failResponse(for: request, error: BridgeError(
                code: BridgeApiContract.errorMethodNotFound,
                message: "Method not found: \(request.method)"
            )).toJsonString()].compactMap { $0 }
        }
        do {
            let results = try handler(context, request.payload)
            var responses: [String] = []
            for result in results {
                switch result {
                case .success(let payload, let done):
                    if let json = successResponse(for: request, payload: payload, done: done).toJsonString() {
                        responses.append(json)
                    }
                case .failure(let error):
                    if let json = failResponse(for: request, error: error).toJsonString() {
                        responses.append(json)
                    }
                }
            }
            return responses
        } catch {
            return [failResponse(for: request, error: BridgeError(
                code: BridgeApiContract.errorInternal,
                message: "handler exception: \(error.localizedDescription)"
            )).toJsonString()].compactMap { $0 }
        }
    }

    // MARK: - Event

    public func postEvent(method: String, payload: JSONValue?) -> Bool {
        guard let transport else {
            sendFailureCount += 1
            return false
        }
        let event = BridgeMessage(
            id: UUID().uuidString,
            sessionId: "",
            kind: .event,
            method: method,
            payload: payload
        )
        guard let json = event.toJsonString() else {
            sendFailureCount += 1
            return false
        }
        let sent = transport.send(json)
        if !sent {
            sendFailureCount += 1
        }
        return sent
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
        transport?.close()
    }
}
