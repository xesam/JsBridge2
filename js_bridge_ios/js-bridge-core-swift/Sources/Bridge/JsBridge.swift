import Foundation

/// Tier 2 — 会话/策略/握手层，叠加在 CoreBridge 之上。
/// 拦截消息入口，插入策略链，策略通过后委托 CoreBridge 分发。
public final class JsBridge {
    /// ready listener 数量上限（上限 32，超限 precondition 失败）
    private static let maxReadyListeners = 32

    public struct SecurityConfig {
        public static let defaultSessionTtlMs: Int64 = 15 * 60 * 1000
        public static let defaultPolicyVersion = "v1"

        // ["*"] = 显式不限制，对应节点不进策略链；具体值 = 启用白名单校验；
        // nil = 未配置（SecurityConfig 存在时两个维度必须在 init 阶段显式声明）
        // methodWhitelist 语义详见 BridgeApiContract.protocolMethods 文档
        public var allowedOrigins: Set<String>? = nil
        public var methodWhitelist: Set<String>? = nil
        public var extraPolicies: [PolicyRule] = []
        public var sessionTtlMs: Int64 = SecurityConfig.defaultSessionTtlMs
        public var policyVersion: String = SecurityConfig.defaultPolicyVersion

        public init() {}
    }

    private let core: CoreBridge
    private let securityConfig: SecurityConfig? // nil = 无安全检查，无需握手
    private var pageContextProvider: PageContextProvider?
    private let policyEngine: PolicyEngine
    private let sessionService = SessionService()
    private let sessionTtlMs: Int64
    private let policyVersion: String
    private var ready: Bool = false
    private var pageInstanceId: String = UUID().uuidString
    private var readyListeners: [() -> Void] = []
    private var readyNotificationPending: Bool = false

    public init(
        securityConfig: SecurityConfig?,
        pageContextProvider: PageContextProvider? = nil,
        transport: BridgeTransport? = nil
    ) {
        // init 阶段校验 + 策略链装配：SecurityConfig 存在时两个字段均不可为 nil
        var rules: [PolicyRule] = [RequestShapePolicy()]
        if let config = securityConfig {
            precondition(
                config.allowedOrigins != nil,
                "JsBridge: allowedOrigins is required. "
                + "Use [\"*\"] to allow all origins, "
                + "or supply specific origins."
            )
            precondition(
                config.methodWhitelist != nil,
                "JsBridge: methodWhitelist is required. "
                + "Use [\"*\"] to allow all methods, "
                + "or supply specific methods."
            )
            rules.append(HandshakeGatePolicy())
            if let origins = config.allowedOrigins, !origins.contains("*") {
                rules.append(OriginPolicy(allowedOrigins: origins))
            }
            // methodWhitelist 非 ["*"] 时才进链；协议方法由框架自动并入放行集
            // （语义详见 BridgeApiContract.protocolMethods 文档）
            if let methods = config.methodWhitelist, !methods.contains("*") {
                var effectiveWhitelist = methods
                effectiveWhitelist.formUnion(BridgeApiContract.protocolMethods)
                rules.append(MethodGatePolicy(methodWhitelist: effectiveWhitelist))
            }
            rules.append(SessionPolicy())
            rules.append(contentsOf: config.extraPolicies)
        }
        self.core = CoreBridge(transport: transport)
        self.securityConfig = securityConfig
        self.pageContextProvider = pageContextProvider
        self.sessionTtlMs = securityConfig?.sessionTtlMs ?? SecurityConfig.defaultSessionTtlMs
        self.policyVersion = securityConfig?.policyVersion ?? SecurityConfig.defaultPolicyVersion
        self.policyEngine = PolicyEngine(rules: rules)
    }

    // MARK: - Transport

    public func attachTransport(_ transport: BridgeTransport?) {
        core.attachTransport(transport)
    }

    /// 绑定 transport 入站回调，形成闭环：
    /// transport 收到 JS 消息 → 策略检查 → 分发 → 响应自动通过 transport 发回。
    ///
    /// 前置条件：已注入 PageContextProvider（未注入时 precondition 失败）。
    /// transport 缺失不做强制检查，发送失败将计入 sendFailureCount。
    ///
    /// 幂等：重复调用仅更新回调引用。
    /// 次序保证：握手响应先于 ready listener 副作用（如 lifecycle 补发）写入 transport。
    /// provider 缺失在绑定期即 fail-fast（对齐 Flutter/Harmony 的装配期暴露语义），
    /// 不等首条消息才发现（消息级兜底仍保留在 processIncomingViaProvider）。
    public func bindTransport() {
        precondition(pageContextProvider != nil,
                     "bindTransport() requires a PageContextProvider; inject one via init(pageContextProvider:)")
        core.bindTransportListener { [weak self] messageJson in
            guard let self else { return }
            let responses = self.processIncomingViaProvider(messageJson)
            for response in responses {
                _ = self.core.sendViaTransport(response)
            }
            self.flushReadyNotification()
        }
    }

    /// 触发已就绪但尚未通知的 ready listeners（幂等；每轮握手只通知一次）。
    private func flushReadyNotification() {
        guard readyNotificationPending else { return }
        readyNotificationPending = false
        for listener in readyListeners {
            listener()
        }
    }

    /// 经 PageContextProvider 派生上下文处理入站消息；不触发 ready 通知（由调用方决定时机）。
    private func processIncomingViaProvider(_ messageJson: String) -> [String] {
        guard let provider = pageContextProvider else {
            preconditionFailure("bindTransport() requires a PageContextProvider; inject one via init(pageContextProvider:)")
        }
        guard let request = BridgeMessage.fromJsonString(messageJson) else { return [] }
        let context = provider.createContext(for: request, pageInstanceId: pageInstanceId)
        return processIncomingResponsesCore(messageJson: messageJson, context: context)
    }

    // MARK: - Handler Registration（委托 CoreBridge）

    /// Register a Simple Handler: single-response, communication ends when handler returns.
    /// 页面上下文由内核注入，作为 handler 的第一个形参。
    /// 同一 method 重复注册时**后者覆盖前者**（last wins）。
    public func registerSimpleHandler(method: String, handler: @escaping SimpleHandler) {
        core.registerSimpleHandler(method: method, handler: handler)
    }

    /// Register an Async Handler: multi-response with ResponseEmitter, can push frames after return.
    /// 页面上下文由内核注入，作为 handler 的第一个形参；多帧响应的唯一表达方式。
    /// 同一 method 重复注册时**后者覆盖前者**（last wins）。
    public func registerAsyncHandler(method: String, handler: @escaping AsyncHandler) {
        core.registerAsyncHandler(method: method, handler: handler)
    }

    // MARK: - State

    public func isReady() -> Bool { ready }

    public func addReadyListener(_ listener: @escaping () -> Void) {
        precondition(
            readyListeners.count < Self.maxReadyListeners,
            "JsBridge: ready listener limit reached"
        )
        readyListeners.append(listener)
    }

    public func postEvent(method: String, payload: JSONValue?) -> Bool {
        guard ready else { return false }
        return core.postEvent(method: method, payload: payload)
    }

    // MARK: - Page Lifecycle

    public func resetPageInstance() {
        ready = (securityConfig == nil)  // nil = 立即 ready；非 nil = 等待握手
        readyNotificationPending = false
        sessionService.clear(pageInstanceId: pageInstanceId)
        pageInstanceId = UUID().uuidString
    }

    public func destroy() {
        sessionService.clearAll()
        core.destroy()
        // 复用防泄漏：宿主复用同一实例重新 bind()/resetPageInstance() 时，
        // 旧 listener 不得再被回调（四端同步语义）
        readyListeners.removeAll()
    }

    // MARK: - Message Processing

    // MARK: - 手动处理入口（宿主自带分发管道时使用）
    //
    // 次序语义（与 Flutter/HarmonyOS 同名入口一致，跨端契约）：这些入口在本轮处理
    // 完成时**立即** flush ready listeners（可能同步产生 lifecycle 事件帧），此时握手
    // 响应串刚要返回给调用方——事件帧可能先于握手响应帧抵达 JS。严格的"握手响应先于
    // ready 副作用"次序只在 bindTransport() 闭环内保证；JS 侧 lifecycle 扩展按
    // docs/03 §7.2 对未 ready 事件排队补发，故此乱序在端到端语义上被掩盖。
    // 需要严格次序的宿主应使用 bindTransport()。

    public func processIncoming(messageJson: String) -> String? {
        let responses = processIncomingViaProvider(messageJson)
        flushReadyNotification()
        return responses.first
    }

    public func processIncomingResponses(messageJson: String) -> [String] {
        let responses = processIncomingViaProvider(messageJson)
        flushReadyNotification()
        return responses
    }

    /// 测试注入面：显式 origin 构造 context。origin 在入口经 OriginNormalizer 归一化
    /// （与 provider 路径同一约束——fail-closed）。生产宿主走 bindTransport() 闭环。
    func processIncoming(messageJson: String, origin: String) -> String? {
        let context = TrustedPageContext(origin: OriginNormalizer.normalize(urlString: origin), pageInstanceId: pageInstanceId)
        let responses = processIncomingResponses(messageJson: messageJson, context: context)
        flushReadyNotification()
        return responses.first
    }

    /// 测试注入面：同 processIncoming(messageJson:origin:)，返回全部响应帧。
    func processIncomingResponses(messageJson: String, origin: String) -> [String] {
        let context = TrustedPageContext(origin: OriginNormalizer.normalize(urlString: origin), pageInstanceId: pageInstanceId)
        let responses = processIncomingResponses(messageJson: messageJson, context: context)
        flushReadyNotification()
        return responses
    }

    /// 测试注入面：以显式 TrustedPageContext 驱动策略链（生产宿主走 bindTransport() 闭环）。
    func processIncomingResponses(messageJson: String, context: TrustedPageContext) -> [String] {
        let responses = processIncomingResponsesCore(messageJson: messageJson, context: context)
        flushReadyNotification()
        return responses
    }

    private func processIncomingResponsesCore(messageJson: String, context: TrustedPageContext) -> [String] {
        guard let request = BridgeMessage.fromJsonString(messageJson) else { return [] }
        let session = sessionService.find(sessionId: request.sessionId)
        let decision = policyEngine.evaluate(PolicyInput(
            message: request,
            trustedPageContext: context,
            ready: ready,
            sessionRecord: session
        ))
        if !decision.allowed {
            // fail-closed（docs/03 §9 细则 3）：任何策略拒绝都必须返回错误响应；
            // 策略结果未携带 error 时以 E_POLICY_DENY 兜底，禁止静默放行继续 dispatch（对齐 Android，验收锚点 C53）
            let error = decision.error ?? BridgeError(
                code: BridgeApiContract.errorPolicyDeny,
                message: "denied (missing error)"
            )
            // 拒绝审计日志：非信任来源的调用尝试应可观测
            print("[JsBridge] policy denied: method=\(request.method) origin=\(context.origin) code=\(error.code)")
            return core.serializeResponses([core.failResponse(for: request, error: error)])
        }

        if request.method == BridgeApiContract.methodHandshake {
            let record = sessionService.issue(
                context: context,
                ttlMs: sessionTtlMs
            )
            ready = true
            readyNotificationPending = true
            let payload: JSONValue = .object([
                "sessionId": .string(record.sessionId),
                "sessionTtlMs": .number(Double(sessionTtlMs)),
                "policyVersion": .string(policyVersion),
                "origin": .string(context.origin),
                "accepted": .bool(true)
            ])
            return core.serializeResponses([core.successResponse(for: request, payload: payload, done: true)])
        }

        if request.method == BridgeApiContract.methodCancelScope {
            var scopeId = ""
            if case .object(let obj)? = request.payload,
               case .string(let s)? = obj["scopeId"] {
                scopeId = s
            }
            let payload: JSONValue = .object([
                "scopeId": .string(scopeId),
                "accepted": .bool(true)
            ])
            return core.serializeResponses([core.successResponse(for: request, payload: payload, done: true)])
        }

        return core.dispatch(request: request, context: context)
    }
}
