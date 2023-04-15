import Foundation

/// Tier 2 — 会话/策略/握手层，叠加在 CoreBridge 之上。
/// 拦截消息入口，插入策略链，策略通过后委托 CoreBridge 分发。
public final class JsBridge {
    public struct KernelConfig {
        public var maxReadyListeners: Int = 32
        public init() {}
    }

    public struct SecurityConfig {
        public var allowedOrigins: Set<String> = ["*"]
        public var methodWhitelist: Set<String> = []
        public var defaultCapabilities: Set<String> = []
        public var extraPolicies: [PolicyRule] = []
        public var sessionTtlMs: Int64 = 15 * 60 * 1000
        public var policyVersion: String = "1"
        public var requireHandshake: Bool = false
        public var requireAccessControl: Bool = false

        public init() {}

        public func withHandshakeGate() -> SecurityConfig {
            var c = self
            c.requireHandshake = true
            return c
        }

        public func withAccessControl() -> SecurityConfig {
            var c = self
            c.requireAccessControl = true
            return c
        }

        public static func secure() -> SecurityConfig {
            return SecurityConfig().withHandshakeGate().withAccessControl()
        }
    }

    public protocol ReadyListener: AnyObject {
        func onReady()
    }

    private let core: CoreBridge
    private let securityConfig: SecurityConfig
    private let kernelConfig: KernelConfig
    private var pageContextProvider: PageContextProvider?
    private let policyEngine: PolicyEngine
    private let sessionService: SessionServiceProtocol = SessionService()
    private var ready: Bool = false
    private var pageInstanceId: String = UUID().uuidString
    private var readyListeners: [() -> Void] = []

    public init(
        securityConfig: SecurityConfig,
        kernelConfig: KernelConfig = KernelConfig(),
        pageContextProvider: PageContextProvider? = nil,
        transport: BridgeTransport? = nil
    ) {
        if securityConfig.requireAccessControl && securityConfig.allowedOrigins.contains("*") {
            preconditionFailure(
                "JsBridge: AccessControlPolicy enabled but allowedOrigins is wildcard '*': "
                + "explicitly set allowedOrigins to obtain real origin protection. "
                + "Use Level 1 (withHandshakeGate only) if origin checks are not required."
            )
        }
        self.core = CoreBridge(transport: transport)
        self.securityConfig = securityConfig
        self.kernelConfig = kernelConfig
        self.pageContextProvider = pageContextProvider
        var rules: [PolicyRule] = [RequestShapePolicy()]
        if securityConfig.requireHandshake {
            rules.append(HandshakeGatePolicy())
        }
        if securityConfig.requireAccessControl {
            rules.append(AccessControlPolicy(
                allowedOrigins: securityConfig.allowedOrigins,
                methodWhitelist: securityConfig.methodWhitelist
            ))
        }
        self.policyEngine = PolicyEngine(rules: rules + securityConfig.extraPolicies)
    }

    // MARK: - Transport

    public func attachTransport(_ transport: BridgeTransport?) {
        core.attachTransport(transport)
    }

    /// 绑定 transport 入站回调，形成闭环：
    /// transport 收到 JS 消息 → 策略检查 → 分发 → 响应自动通过 transport 发回。
    ///
    /// 前置条件：
    /// 1. 已通过构造函数或 attachTransport 注入 transport。
    /// 2. 已注入 PageContextProvider（Level 2 必需；未注入时 processIncomingResponses 会 preconditionFailure）。
    ///
    /// 幂等：重复调用仅更新回调引用。
    public func bindTransport() {
        core.bindTransportListener { [weak self] messageJson in
            guard let self else { return }
            let responses = self.processIncomingResponses(messageJson: messageJson)
            for response in responses {
                _ = self.core.sendViaTransport(response)
            }
        }
    }

    public var sendFailureCount: Int { core.sendFailureCount }

    // MARK: - Handler Registration（委托 CoreBridge）

    public func registerHandler(method: String, handler: @escaping NativeRequestHandler) {
        core.registerHandler(method: method, handler: handler)
    }

    public func registerHandlerWithContext(method: String, handler: @escaping NativeRequestHandlerWithContext) {
        core.registerHandlerWithContext(method: method, handler: handler)
    }

    public func registerStreamingHandler(method: String, handler: @escaping NativeStreamingHandler) {
        core.registerStreamingHandler(method: method, handler: handler)
    }

    public func registerStreamingHandlerWithContext(method: String, handler: @escaping NativeStreamingHandlerWithContext) {
        core.registerStreamingHandlerWithContext(method: method, handler: handler)
    }

    // MARK: - State

    public func isReady() -> Bool { ready }

    public func addReadyListener(_ listener: @escaping () -> Void) {
        precondition(
            readyListeners.count < kernelConfig.maxReadyListeners,
            "JsBridge: ready listener limit reached"
        )
        readyListeners.append(listener)
    }

    public func postEvent(method: String, payload: JSONValue?) -> Bool {
        guard ready else { return false }
        return core.postEvent(method: method, payload: payload)
    }

    // MARK: - Page Lifecycle

    public func resetForNewPage() {
        ready = !securityConfig.requireHandshake
        sessionService.clear(pageInstanceId: pageInstanceId)
        pageInstanceId = UUID().uuidString
    }

    public func destroy() {
        sessionService.clearAll()
        core.destroy()
    }

    // MARK: - Message Processing

    public func processIncoming(messageJson: String) -> String? {
        guard let provider = pageContextProvider else {
            preconditionFailure("processIncoming(messageJson:) requires a PageContextProvider; inject one via init(pageContextProvider:) or attachPageContextProvider(_:).")
        }
        guard let request = BridgeMessage.fromJsonString(messageJson) else { return nil }
        let context = provider.createContext(for: request, pageInstanceId: pageInstanceId)
        return processIncomingResponses(messageJson: messageJson, context: context).first
    }

    public func processIncomingResponses(messageJson: String) -> [String] {
        guard let provider = pageContextProvider else {
            preconditionFailure("processIncomingResponses(messageJson:) requires a PageContextProvider; inject one via init(pageContextProvider:) or attachPageContextProvider(_:).")
        }
        guard let request = BridgeMessage.fromJsonString(messageJson) else { return [] }
        let context = provider.createContext(for: request, pageInstanceId: pageInstanceId)
        return processIncomingResponses(messageJson: messageJson, context: context)
    }

    public func processIncoming(messageJson: String, origin: String) -> String? {
        let context = TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId)
        return processIncomingResponses(messageJson: messageJson, context: context).first
    }

    public func processIncomingResponses(messageJson: String, origin: String) -> [String] {
        let context = TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId)
        return processIncomingResponses(messageJson: messageJson, context: context)
    }

    public func processIncomingResponses(messageJson: String, context: TrustedPageContext) -> [String] {
        guard let request = BridgeMessage.fromJsonString(messageJson) else { return [] }
        let session = sessionService.find(sessionId: request.sessionId)
        let decision = policyEngine.evaluate(PolicyInput(
            message: request,
            trustedPageContext: context,
            ready: ready,
            sessionRecord: session
        ))
        if !decision.allowed, let error = decision.error {
            return [core.failResponse(for: request, error: error).toJsonString()].compactMap { $0 }
        }

        if request.method == BridgeApiContract.methodHandshake {
            let record = sessionService.issue(
                context: context,
                capabilities: securityConfig.defaultCapabilities,
                ttlMs: securityConfig.sessionTtlMs
            )
            ready = true
            for listener in readyListeners {
                listener()
            }
            let payload: JSONValue = .object([
                "sessionId": .string(record.sessionId),
                "capabilities": .array(record.capabilities.sorted().map { .string($0) }),
                "sessionTtlMs": .number(Double(securityConfig.sessionTtlMs)),
                "policyVersion": .string(securityConfig.policyVersion),
                "origin": .string(context.origin),
                "accepted": .bool(true)
            ])
            return [core.successResponse(for: request, payload: payload, done: true).toJsonString()].compactMap { $0 }
        }

        if request.method == BridgeApiContract.methodCancelScope {
            let payload: JSONValue = .object([
                "scopeId": request.scopeId.map { .string($0) } ?? .null,
                "accepted": .bool(true)
            ])
            return [core.successResponse(for: request, payload: payload, done: true).toJsonString()].compactMap { $0 }
        }

        return core.dispatch(request: request, context: context)
    }
}
