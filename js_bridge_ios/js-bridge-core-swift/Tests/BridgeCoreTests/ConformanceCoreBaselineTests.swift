import XCTest
@testable import BridgeCore

final class ConformanceCoreBaselineTests: XCTestCase {
    func testC01_requestBeforeHandshake_deniedByGate() {
        let bridge = makeBridge()
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r1", method: "echo", sessionId: "", payload: ["k": "v"]),
            origin: "file://"
        )
        XCTAssertNotNil(response)
        XCTAssertEqual(errorCode(from: response), "E_NOT_READY") // v1: 握手门禁从 E_POLICY_DENY 分立
    }

    func testC02_handshake_returnsSessionPayload() {
        let bridge = makeBridge()
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: "file://"
        )
        let json = object(from: response)
        let payload = json?["payload"] as? [String: Any]

        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertNotNil(payload?["sessionId"] as? String)
        XCTAssertNotNil(payload?["sessionTtlMs"])
        XCTAssertEqual(payload?["policyVersion"] as? String, "v1")
        XCTAssertEqual(payload?["origin"] as? String, "file://")
        XCTAssertEqual(payload?["accepted"] as? Bool, true)
    }

    func testC03_methodWhitelist_denied() {
        let bridge = makeBridge()
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r2", method: "notAllowed", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_METHOD_NOT_ALLOWED")
    }

    func testC04_originDenied() {
        let bridge = makeBridge()
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: "https://evil.example"
        )
        XCTAssertEqual(errorCode(from: response), "E_ORIGIN_DENY")
    }

    func testC04b_originPrefixButNotExact_denied() {
        let bridge = makeBridge(allowedOrigins: ["https://trusted.example"])
        bridge.resetPageInstance()

        // origin 是白名单条目的前缀延伸，不是精确匹配 → 拒绝
        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: "https://trusted.example.evil"
        )
        XCTAssertEqual(errorCode(from: response), "E_ORIGIN_DENY")
    }

    func testC05_handshakeThenValidRequest_success() {
        let bridge = makeBridge()
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r3", method: "echo", sessionId: sessionId, payload: ["ok": 1]),
            origin: "file://"
        )
        let json = object(from: response)

        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["method"] as? String, "echo")
    }

    func testC06_requestMissingSessionAfterReady_denied() {
        let bridge = makeBridge()
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        _ = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r6", method: "echo", sessionId: "", payload: ["k": "v"]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    func testC07_requestMismatchedOrigin_denied() {
        let bridge = makeBridge(allowedOrigins: ["file://", "https://example.com"])
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r7", method: "echo", sessionId: sessionId, payload: ["k": "v"]),
            origin: "https://example.com"
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    func testC08_requestMismatchedPageInstance_denied() {
        let bridge = makeBridge(allowedOrigins: ["file://"])
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        _ = bridge.processIncoming(
            messageJson: requestJson(id: "r8", method: "echo", sessionId: sessionId, payload: ["k": "v"]),
            origin: "file://"
        )
        let mismatchResponse = bridge.processIncomingResponses(
            messageJson: requestJson(id: "r8b", method: "echo", sessionId: sessionId, payload: ["k": "v"]),
            context: TrustedPageContext(origin: "file://", pageInstanceId: "other-page")
        ).first
        XCTAssertEqual(errorCode(from: mismatchResponse), "E_SESSION_INVALID")
    }

    func testC10_handlerNotFound_returnsMethodNotFound() {
        let bridge = makeBridge(
            allowedOrigins: ["file://"],
            methodWhitelist: [BridgeApiContract.methodHandshake, "echo", "ghost"]
        )
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r10", method: "ghost", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_METHOD_NOT_FOUND")
    }

    func testC11_handlerThrows_normalizedToInternal() {
        let bridge = makeBridge()
        let handler: SimpleHandler = { _, _ in
            throw NSError(domain: "BridgeCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        bridge.registerSimpleHandler(method: "echo", handler: handler)
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r11", method: "echo", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_INTERNAL")
    }

    func testC12_extraPolicyDeny_takesEffect() {
        struct ExtraDenyPolicy: PolicyRule {
            func evaluate(_ input: PolicyInput) -> PolicyDecision {
                if input.message.method == "echo" {
                    return .deny(BridgeError(code: "E_TEST_DENY", message: "blocked"))
                }
                return .allow()
            }
        }

        let bridge = makeBridge(
            allowedOrigins: ["file://"],
            methodWhitelist: [BridgeApiContract.methodHandshake, "echo"],
            extraPolicies: [ExtraDenyPolicy()]
        )
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r12", method: "echo", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_TEST_DENY")
    }

    func testC13_streamingResponse_emitsDoneFalseThenDoneTrue() async {
        let transport = FakeBridgeTransport()
        let bridge = makeBridge(
            methodWhitelist: [BridgeApiContract.methodHandshake, "stream"],
            transport: transport
        )
        // 流式多帧只能经 AsyncHandler + ResponseEmitter 表达
        let asyncHandler: AsyncHandler = { _, _, emitter in
            guard let emitter else { return }
            await emitter(.success(.object(["tick": .number(1)])), false)
            await emitter(.success(.object(["tick": .number(2)])), true)
        }
        bridge.registerAsyncHandler(method: "stream", handler: asyncHandler)
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        _ = bridge.processIncoming(
            messageJson: requestJson(id: "r13", method: "stream", sessionId: sessionId, payload: [:], keep: true),
            origin: "file://"
        )
        // 异步帧经 sendViaTransport 旁路推送，等待其到达
        try? await Task.sleep(nanoseconds: 50_000_000)

        let frames = transport.sentMessages.compactMap { json -> [String: Any]? in
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["reqId"] as? String == "r13"
            else { return nil }
            return object
        }
        XCTAssertEqual(frames.count, 2)

        // 帧序契约：首帧 done=false，末帧 done=true
        XCTAssertEqual(frames[0]["done"] as? Bool, false)
        XCTAssertEqual(frames[1]["done"] as? Bool, true)
        XCTAssertEqual(frames[0]["ok"] as? Bool, true)
        XCTAssertEqual(frames[1]["ok"] as? Bool, true)
        // keep=true 请求的帧必须保持 keep=true
        XCTAssertEqual(frames[0]["keep"] as? Bool, true)
        XCTAssertEqual(frames[1]["keep"] as? Bool, true)

        let firstPayload = frames[0]["payload"] as? [String: Any]
        let secondPayload = frames[1]["payload"] as? [String: Any]
        XCTAssertEqual(firstPayload?["tick"] as? Double, 1.0)
        XCTAssertEqual(secondPayload?["tick"] as? Double, 2.0)
    }

    func testC17_sendFailure_observableAndPostEventReturnsFalse() {
        let transport = FakeBridgeTransport()
        transport.sendEnabled = false
        let bridge = makeBridge(transport: transport)
        bridge.resetPageInstance()
        _ = handshake(bridge: bridge, origin: "file://")

        XCTAssertTrue(bridge.isReady())
        let sent = bridge.postEvent(method: BridgeApiContract.methodLifecycle, payload: .object(["state": .string("ready")]))
        XCTAssertFalse(sent)
    }

    func testC18_resetPageInstanceRotatesContextAndOldSessionInvalid() {
        let bridge = makeBridge()
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let oldSessionId = handshake(bridge: bridge, origin: "file://")

        bridge.resetPageInstance()
        _ = handshake(bridge: bridge, origin: "file://")
        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r18", method: "echo", sessionId: oldSessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    // MARK: - PageContextProvider tests (P1: kernel-derived origin)

    private final class FixedOriginProvider: PageContextProvider {
        let origin: String
        init(origin: String) { self.origin = origin }
        func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext {
            TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId)
        }
    }

    private final class MutableOriginProvider: PageContextProvider {
        var origin: String
        init(origin: String) { self.origin = origin }
        func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext {
            TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId)
        }
    }

    func testPageContextProvider_handshakeUsesKernelDerivedOrigin() {
        let provider = FixedOriginProvider(origin: "file://")
        let bridge = makeBridge(allowedOrigins: ["file://"], pageContextProvider: provider)
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h-pp", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:])
        )
        let json = object(from: response)
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual((json?["payload"] as? [String: Any])?["origin"] as? String, "file://")
    }

    func testPageContextProvider_originNotAllowed_denied() {
        let provider = FixedOriginProvider(origin: "https://evil.example")
        let bridge = makeBridge(allowedOrigins: ["file://"], pageContextProvider: provider)
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h-pp2", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:])
        )
        XCTAssertEqual(errorCode(from: response), "E_ORIGIN_DENY")
    }

    func testPageContextProvider_mismatchedOriginOnRequest_sessionInvalid() {
        let provider = MutableOriginProvider(origin: "file://")
        let bridge = makeBridge(allowedOrigins: ["file://", "https://example.com"], pageContextProvider: provider)
        bridge.registerSimpleHandler(method: "echo") { _, payload in .success(payload) }
        bridge.resetPageInstance()

        let handshakeResponse = bridge.processIncoming(
            messageJson: requestJson(id: "h-pp3", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:])
        )
        let sessionId = (object(from: handshakeResponse)?["payload"] as? [String: Any])?["sessionId"] as? String ?? ""
        XCTAssertFalse(sessionId.isEmpty)

        provider.origin = "https://example.com"
        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r-pp3", method: "echo", sessionId: sessionId, payload: [:])
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    // MARK: - 无配置场景 tests (securityConfig == nil, no handshake required)

    func testDefaultConfig_isReadyImmediatelyAfterBindPage() {
        let bridge = JsBridge(securityConfig: nil)
        XCTAssertFalse(bridge.isReady(), "bridge should not be ready before resetPageInstance")
        bridge.resetPageInstance()
        XCTAssertTrue(bridge.isReady())
    }

    func testDefaultConfig_handlerDispatchedWithoutHandshake() {
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: nil, transport: transport)
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r-l0-1", method: "echo", sessionId: "", payload: ["k": "v"]),
            origin: "file://"
        )
        let json = object(from: response)
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["method"] as? String, "echo")
        XCTAssertEqual(json?["reqId"] as? String, "r-l0-1")
    }

    func testDefaultConfig_postEventImmediatelyAvailable() {
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: nil, transport: transport)
        bridge.resetPageInstance()

        let sent = bridge.postEvent(method: "runtime.state", payload: nil)
        XCTAssertTrue(sent)

        let eventJson = transport.sentMessages.first
        let json = object(from: eventJson)
        XCTAssertEqual(json?["kind"] as? String, "event")
        XCTAssertEqual(json?["method"] as? String, "runtime.state")
    }

    func testC28_lifecycleEventsBeforeReady_queuedAndFlushedInOrder() {
        let transport = FakeBridgeTransport()
        let bridge = makeBridge(transport: transport)
        let lifecycle = LifecycleExtension(bridge: bridge)
        bridge.resetPageInstance()

        lifecycle.onHostEvent(state: "created")
        lifecycle.onHostEvent(state: "started")
        lifecycle.onHostEvent(state: "resumed")
        XCTAssertTrue(lifecycleEvents(from: transport).isEmpty)

        _ = handshake(bridge: bridge)

        let events = lifecycleEvents(from: transport)
        XCTAssertEqual(events.map { $0.state }, ["created", "started", "resumed"])
        XCTAssertEqual(events.map { $0.seq }, [1, 2, 3])
    }

    func testC29_lifecycleQueueOverflow_dropsOldestKeepsSeq() {
        let transport = FakeBridgeTransport()
        let bridge = makeBridge(transport: transport)
        let lifecycle = LifecycleExtension(bridge: bridge, maxPendingEvents: 2)
        bridge.resetPageInstance()

        lifecycle.onHostEvent(state: "created")
        lifecycle.onHostEvent(state: "started")
        lifecycle.onHostEvent(state: "resumed")

        _ = handshake(bridge: bridge)

        let events = lifecycleEvents(from: transport)
        XCTAssertEqual(events.map { $0.state }, ["started", "resumed"])
        XCTAssertEqual(events.map { $0.seq }, [2, 3])
    }

    func testC30_lifecycleAfterReady_sentImmediatelyWithExactPayload() {
        let transport = FakeBridgeTransport()
        let bridge = makeBridge(transport: transport)
        let lifecycle = LifecycleExtension(bridge: bridge)
        bridge.resetPageInstance()
        _ = handshake(bridge: bridge)

        lifecycle.onHostEvent(state: "resumed")

        let events = lifecycleEvents(from: transport)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].state, "resumed")
        XCTAssertEqual(events[0].seq, 1)
        XCTAssertEqual(events[0].payloadKeyCount, 2)
    }

    func testC33_emptyMethod_deniedAsInvalidMessage() {
        let bridge = makeBridge()
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r1", method: "", sessionId: "", payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_INVALID_MESSAGE")
    }

    func testC34_missingKind_silentlyDropped() {
        let bridge = makeBridge()
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: "{\"id\":\"r1\",\"sessionId\":\"\",\"method\":\"echo\",\"payload\":{}}",
            origin: "file://"
        )
        XCTAssertNil(response)
    }

    func testC35_handshakeNotInWhitelist_autoAllowed() {
        let bridge = makeBridge(methodWhitelist: ["echo"])
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: "file://"
        )
        // 协议方法由框架装配期自动并入放行集，白名单未含 bridge.handshake 时握手仍成功
        let json = object(from: response)
        XCTAssertEqual(json?["ok"] as? Bool, true)
        let payload = json?["payload"] as? [String: Any]
        XCTAssertFalse((payload?["sessionId"] as? String ?? "").isEmpty)
    }

    func testC36_unknownSessionId_denied() {
        let bridge = makeBridge()
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        _ = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r1", method: "echo", sessionId: "bogus-session", payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    func testC37_cancelScope_echoesPayloadScopeIdWithAccepted() {
        let bridge = makeBridge(
            methodWhitelist: [BridgeApiContract.methodHandshake, BridgeApiContract.methodCancelScope]
        )
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(
                id: "c1",
                method: BridgeApiContract.methodCancelScope,
                sessionId: sessionId,
                payload: ["scopeId": "s-1"]
            ),
            origin: "file://"
        )
        let json = object(from: response)
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(payload?["scopeId"] as? String, "s-1")
        XCTAssertEqual(payload?["accepted"] as? Bool, true)
    }

    func testC38_missingOptionalFields_defaultsApplied() {
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: nil, transport: transport)
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()

        let response = bridge.processIncoming(
            messageJson: "{\"id\":\"r38\",\"kind\":\"request\",\"method\":\"echo\"}",
            origin: "file://"
        )
        let json = object(from: response)
        XCTAssertEqual(json?["ok"] as? Bool, true)
    }

    private func makeBridge(
        allowedOrigins: Set<String> = ["file://"],
        methodWhitelist: Set<String> = [BridgeApiContract.methodHandshake, "echo"],
        extraPolicies: [PolicyRule] = [],
        transport: BridgeTransport? = nil,
        pageContextProvider: PageContextProvider? = nil
    ) -> JsBridge {
        var config = JsBridge.SecurityConfig()
        config.allowedOrigins = allowedOrigins
        config.methodWhitelist = methodWhitelist
        config.extraPolicies = extraPolicies
        return JsBridge(securityConfig: config, pageContextProvider: pageContextProvider, transport: transport)
    }

    private func handshake(bridge: JsBridge, origin: String = "file://") -> String {
        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: origin
        )
        let json = object(from: response)
        let payload = json?["payload"] as? [String: Any]
        return (payload?["sessionId"] as? String) ?? ""
    }

    private func lifecycleEvents(from transport: FakeBridgeTransport)
        -> [(state: String, seq: Int, payloadKeyCount: Int)] {
        return transport.sentMessages.compactMap { json in
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["kind"] as? String == "event",
                  object["method"] as? String == BridgeApiContract.methodLifecycle,
                  let payload = object["payload"] as? [String: Any],
                  let state = payload["state"] as? String,
                  let seq = payload["seq"] as? Int ?? (payload["seq"] as? Double).map(Int.init)
            else { return nil }
            return (state, seq, payload.count)
        }
    }

    // MARK: - C43: Async Multi-Response Conformance

    func testC43_asyncHandler_multipleResponsesViaEmitter() async {
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: nil, transport: transport)

        // 注册异步 handler，使用显式类型注解避免重载歧义
        let asyncHandler: AsyncHandler = { _, _, emitter in
            guard let emitter else { return }

            // 发送第一帧：done=false
            await emitter(.success(.object(["frame": .number(1)])), false)

            // 模拟异步工作
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms

            // 发送第二帧：done=false
            await emitter(.success(.object(["frame": .number(2)])), false)

            // 发送最终帧：done=true
            await emitter(.success(.object(["frame": .number(3)])), true)
        }
        bridge.registerAsyncHandler(method: "asyncTest", handler: asyncHandler)

        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge)

        // 发起请求
        _ = bridge.processIncoming(
            messageJson: requestJson(id: "r43", method: "asyncTest", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )

        // 等待异步响应完成
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // 验证 transport 收到的消息
        let responses = transport.sentMessages.compactMap { json -> [String: Any]? in
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["reqId"] as? String == "r43"
            else { return nil }
            return object
        }

        // 应该收到 3 帧响应
        XCTAssertEqual(responses.count, 3, "Should receive 3 async responses")

        // 验证第一帧
        if responses.count >= 1 {
            XCTAssertEqual(responses[0]["done"] as? Bool, false)
            XCTAssertEqual(responses[0]["ok"] as? Bool, true)
            let payload1 = responses[0]["payload"] as? [String: Any]
            XCTAssertEqual(payload1?["frame"] as? Double, 1.0)
        }

        // 验证第二帧
        if responses.count >= 2 {
            XCTAssertEqual(responses[1]["done"] as? Bool, false)
            XCTAssertEqual(responses[1]["ok"] as? Bool, true)
            let payload2 = responses[1]["payload"] as? [String: Any]
            XCTAssertEqual(payload2?["frame"] as? Double, 2.0)
        }

        // 验证最终帧
        if responses.count >= 3 {
            XCTAssertEqual(responses[2]["done"] as? Bool, true)
            XCTAssertEqual(responses[2]["ok"] as? Bool, true)
            let payload3 = responses[2]["payload"] as? [String: Any]
            XCTAssertEqual(payload3?["frame"] as? Double, 3.0)
        }
    }

    func testC48_protocolMethods_autoMergedIntoWhitelist() {
        let bridge = makeBridge(methodWhitelist: ["echo"]) // 不含任何协议方法
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge)
        XCTAssertFalse(sessionId.isEmpty)

        // 协议方法 bridge.cancelScope 自动放行并回显 scopeId
        let cancelResponse = bridge.processIncoming(
            messageJson: requestJson(
                id: "c1",
                method: BridgeApiContract.methodCancelScope,
                sessionId: sessionId,
                payload: ["scopeId": "s-1"]
            ),
            origin: "file://"
        )
        let cancelJson = object(from: cancelResponse)
        XCTAssertEqual(cancelJson?["ok"] as? Bool, true)
        let cancelPayload = cancelJson?["payload"] as? [String: Any]
        XCTAssertEqual(cancelPayload?["scopeId"] as? String, "s-1")

        // 白名单外业务方法仍被拒绝
        let forbiddenResponse = bridge.processIncoming(
            messageJson: requestJson(id: "r1", method: "forbidden", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: forbiddenResponse), "E_METHOD_NOT_ALLOWED")

        // 白名单内业务方法正常成功
        let echoResponse = bridge.processIncoming(
            messageJson: requestJson(id: "r2", method: "echo", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        let echoJson = object(from: echoResponse)
        XCTAssertEqual(echoJson?["ok"] as? Bool, true)
    }

    // MARK: - C49: 重复注册同 method 后者覆盖

    func testC49_duplicateRegistration_lastWins() {
        // 前置条件：无安全配置（nil）→ 单一注册表，无隐式优先级
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: nil, transport: transport)

        var h1Invoked = false
        bridge.registerSimpleHandler(method: "dup") { _, _ in
            h1Invoked = true
            return .success(.object(["from": .string("h1")]))
        }
        bridge.registerSimpleHandler(method: "dup") { _, _ in
            .success(.object(["from": .string("h2")]))
        }
        bridge.resetPageInstance()

        let responses = bridge.processIncomingResponses(
            messageJson: requestJson(id: "r49", method: "dup", sessionId: "", payload: [:]),
            origin: "file://"
        )

        // 仅一帧响应，且 payload 来自后注册的 h2
        XCTAssertEqual(responses.count, 1)
        let json = object(from: responses[0])
        XCTAssertEqual(json?["ok"] as? Bool, true)
        let payload = json?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["from"] as? String, "h2")
        // 先注册的 h1 从未被调用
        XCTAssertFalse(h1Invoked)
    }

    // MARK: - C51: 必填字段类型非法静默丢弃

    func testC51_requiredFieldTypeIllegal_silentlyDroppedNoResponse() {
        let bridge = makeBridge()
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        // 依次发送 id / kind / method / sessionId 为非字符串值的请求：
        // 必填字段类型非法 → 静默丢弃（禁止宽容转换），均不得产生任何响应（docs/03 §3.4）
        let malformedMessages = [
            // id 为数字
            "{\"id\":123,\"sessionId\":\"\(sessionId)\",\"kind\":\"request\",\"method\":\"echo\",\"payload\":{}}",
            // sessionId 为数字
            "{\"id\":\"r51-a\",\"sessionId\":123,\"kind\":\"request\",\"method\":\"echo\",\"payload\":{}}",
            // kind 为数字
            "{\"id\":\"r51-b\",\"sessionId\":\"\(sessionId)\",\"kind\":123,\"method\":\"echo\",\"payload\":{}}",
            // method 为数字
            "{\"id\":\"r51-c\",\"sessionId\":\"\(sessionId)\",\"kind\":\"request\",\"method\":123,\"payload\":{}}"
        ]
        for messageJson in malformedMessages {
            XCTAssertNil(
                bridge.processIncoming(messageJson: messageJson, origin: "file://"),
                "必填字段类型非法的消息必须被静默丢弃：\(messageJson)"
            )
        }

        // 后续正常请求不受影响
        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r51-ok", method: "echo", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(object(from: response)?["ok"] as? Bool, true)
    }

    // MARK: - C52: handler 无数据成功必发终止帧

    func testC52_simpleHandlerSuccessNullPayload_singleDoneFrame() {
        let bridge = makeBridge(
            allowedOrigins: ["file://"],
            methodWhitelist: [BridgeApiContract.methodHandshake, "noop"]
        )
        // Simple handler 返回 success(null)：无数据成功也必须发出恰好一帧终止响应，不得静默吞帧
        bridge.registerSimpleHandler(method: "noop") { _, _ in
            .success(.null)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let responses = bridge.processIncomingResponses(
            messageJson: requestJson(id: "r52", method: "noop", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )

        XCTAssertEqual(responses.count, 1, "success(null) 必须产生恰好 1 帧响应")
        let json = object(from: responses.first)
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["done"] as? Bool, true, "终止帧 done 必须为 true")
        XCTAssertEqual(json?["reqId"] as? String, "r52")
        // payload 必须为 JSON null（而非省略字段后无法区分于编码失败）
        XCTAssertTrue(json?["payload"] is NSNull, "payload 必须为 null")
    }

    // MARK: - C53: 策略拒绝无 error 时 fail-closed

    func testC53_policyDenyWithoutError_failsClosedWithPolicyDeny() {
        // deny 但不携带 error 的自定义策略：不得静默放行到 dispatch
        struct DenyNoErrorPolicy: PolicyRule {
            func evaluate(_ input: PolicyInput) -> PolicyDecision {
                if input.message.method == "echo" {
                    return PolicyDecision(allowed: false, error: nil)
                }
                return .allow()
            }
        }

        let bridge = makeBridge(extraPolicies: [DenyNoErrorPolicy()])
        var echoInvoked = false
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            echoInvoked = true
            return .success(payload)
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r53", method: "echo", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )

        // deny 但缺 error → 以 E_POLICY_DENY 兜底返回失败响应，禁止静默放行
        XCTAssertEqual(errorCode(from: response), BridgeApiContract.errorPolicyDeny)
        XCTAssertEqual(object(from: response)?["ok"] as? Bool, false)
        // 消息未放行到 dispatch：handler 从未被调用
        XCTAssertFalse(echoInvoked)
    }

    // MARK: - C54: origin 序列化归一化契约

    func testC54_originNormalizer_defaultPortOmittedNonDefaultKept() {
        // 默认端口省略
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "https://host:443"), "https://host")
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "http://host:80"), "http://host")
        // 非默认端口保留
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "https://host:8443"), "https://host:8443")
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "http://host:8080"), "http://host:8080")
        // 无 URL → ""（fail-closed，不用 "about:blank" 等占位值）
        XCTAssertEqual(OriginNormalizer.normalize(nil as URL?), "")
        XCTAssertEqual(OriginNormalizer.normalize(urlString: nil), "")
        // scheme 与 host 小写
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "HTTPS://HOST:8443"), "https://host:8443")
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "https://EXAMPLE.com"), "https://example.com")
        // 本地内容协议保留 scheme 语义
        XCTAssertEqual(OriginNormalizer.normalize(urlString: "file:///var/mobile/page.html"), "file://")
    }

    func testC54_originNormalizer_vectorSuite() {
        // C54：四端共享的 origin 归一化全量向量，正本为 docs/origin-normalizer-vectors.json，
        // 由 scripts/check_origin_vectors.sh 强制四端 C54 测试内嵌同一向量集——修改必须四端同改
        // ORIGIN_VECTORS:BEGIN
        v("", "")
        v("   ", "")
        v("host/path", "")
        v("::::", "")
        v("123://host", "")
        v("a b://host", "")
        v("ab+cd-.://host", "ab+cd-.://host")
        v("about:blank", "")
        v("data:text/html,x", "")
        v("mailto:a@b", "")
        v("javascript:alert(1)", "")
        v("file:///sdcard/index.html", "file://")
        v("file://media/path", "file://")
        v("FILE:///x.html", "file://")
        v("content:///settings", "content://")
        v("flutter-asset:///assets/web/index.html", "flutter-asset://")
        v("asset://", "asset://")
        v("https://", "https://")
        v("https://example.com", "https://example.com")
        v("HTTPS://EXAMPLE.com/Path?x=1#f", "https://example.com")
        v("https://host:443", "https://host")
        v("http://host:80", "http://host")
        v("https://host:0443", "https://host")
        v("http://host:080", "http://host")
        v("https://host:8443", "https://host:8443")
        v("http://host:8080/a/b?c#d", "http://host:8080")
        v("http://u:p@host:8080", "http://host:8080")
        v("http://host:65535", "http://host:65535")
        v("http://host:99999", "")
        v("custom://host:8080", "custom://host:8080")
        v("custom://host", "custom://host")
        v("ftp://host:21", "ftp://host:21")
        v("https://:8080", "")
        v("http://host:abc", "")
        v("http://host:0", "")
        v("http://host:00", "")
        v("http://host:-80", "")
        v("http://host:", "")
        v("http://::", "")
        v("http://[::1]", "http://[::1]")
        v("http://[::1]:8443", "http://[::1]:8443")
        v("http://[2001:DB8::1]:443", "http://[2001:db8::1]:443")
        v("http://[::1]:0", "")
        // ORIGIN_VECTORS:END
    }

    /// C54 向量套件的单条断言（带上失败信息）。
    private func v(_ input: String, _ expected: String) {
        XCTAssertEqual(OriginNormalizer.normalize(urlString: input), expected, "normalize(\(input))")
    }

    // MARK: - C55: postEvent 默认空串 sessionId 广播

    func testC55_postEventWithoutSessionId_broadcastsEmptySessionId() {
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: nil, transport: transport)
        bridge.resetPageInstance()

        // postEvent(method, payload) 无 sessionId 参数——默认值必须与其他三端一致为空串（广播）
        let sent = bridge.postEvent(method: "runtime.state", payload: .object(["state": .string("ready")]))
        XCTAssertTrue(sent)

        XCTAssertEqual(transport.sentMessages.count, 1)
        let json = object(from: transport.sentMessages.first)
        XCTAssertEqual(json?["kind"] as? String, "event")
        // 空串 sessionId = 广播语义（C22）：JS 客户端无条件派发（v1 唯一形态，无定向投送入口）
        XCTAssertEqual(json?["sessionId"] as? String, "")
    }

    // MARK: - C56: session 签发时清扫过期记录

    func testC56_sessionIssueSweepsExpired_expiredEntriesRemovedAtIssueTime() {
        // 注入假时钟：确定性推进 TTL，无需真实等待
        var nowMs: Int64 = 1_000_000
        let service = SessionService(clock: { nowMs })

        let context = TrustedPageContext(origin: "https://example.com", pageInstanceId: "page-c56")
        // 签发 session A（TTL 短）
        let sessionA = service.issue(context: context, ttlMs: 1_000)
        XCTAssertEqual(service.sessionCount, 1)

        // 推进时钟超过 A 的 TTL → 再次签发 session B
        nowMs += 2_000
        let sessionB = service.issue(context: context, ttlMs: 60_000)

        // 过期记录在签发 B 时被顺带清扫（若仅 find 惰性移除，此处计数将为 2）
        XCTAssertEqual(service.sessionCount, 1, "签发时必须顺带清扫全表过期记录")

        // 查询 A 失败（E_SESSION_INVALID 语义），B 正常有效
        XCTAssertNil(service.find(sessionId: sessionA.sessionId), "过期 session 的 find 必须失败")
        XCTAssertNotNil(service.find(sessionId: sessionB.sessionId))
        XCTAssertEqual(service.find(sessionId: sessionB.sessionId)?.sessionId, sessionB.sessionId)
    }

    // MARK: - C60: sessionTtlMs=0 永不过期

    func testC60_sessionTtlZero_neverExpires() {
        // docs/03 §10 三态：ttl=0 → -1 哨兵（此前误实现为立即过期）
        var nowMs: Int64 = 2_000_000
        let service = SessionService(clock: { nowMs })

        let sessionA = service.issue(
            context: TrustedPageContext(origin: "https://example.com", pageInstanceId: "page-c60a"),
            ttlMs: 0)
        nowMs += 86_400_000 // 推进一天
        XCTAssertNotNil(service.find(sessionId: sessionA.sessionId), "ttl=0 的 session 永不失效")

        // 不同 pageInstanceId 签发 B，A 不受刷新语义影响（C61 只刷新同页）
        let sessionB = service.issue(
            context: TrustedPageContext(origin: "https://example.com", pageInstanceId: "page-c60b"),
            ttlMs: 0)
        XCTAssertEqual(service.sessionCount, 2, "签发清扫不得移除永不过期记录")
        XCTAssertNotNil(service.find(sessionId: sessionA.sessionId))
        XCTAssertNotNil(service.find(sessionId: sessionB.sessionId))
    }

    // MARK: - C61: 重复握手刷新旧 session

    func testC61_repeatedHandshakeRefreshes_priorSessionInvalidated() {
        // docs/03 §7.1 幂等性：同 pageInstanceId 重复握手应"刷新"而非并存
        let nowMs: Int64 = 2_000_000
        let service = SessionService(clock: { nowMs })
        let context = TrustedPageContext(origin: "https://example.com", pageInstanceId: "page-c61")

        let sessionA = service.issue(context: context, ttlMs: 60_000)
        XCTAssertNotNil(service.find(sessionId: sessionA.sessionId))

        let sessionB = service.issue(context: context, ttlMs: 60_000)

        XCTAssertNil(service.find(sessionId: sessionA.sessionId), "旧 session 应被刷新失效")
        XCTAssertNotNil(service.find(sessionId: sessionB.sessionId))
        XCTAssertEqual(service.sessionCount, 1, "同页至多存活 1 条")
    }

    // MARK: - C62: async handler 启动即返，不阻塞入站管线

    func testC62_dispatchLaunchesAsyncWithoutBlocking_pipelineKeepsProcessing() async {
        // docs/09 C62：dispatch 对 Async handler 启动即返——busy handler 发射首帧后挂起，
        // 期间 ping（Simple）请求仍可被完整处理（busy 挂起不得阻塞入站管线）
        let transport = FakeBridgeTransport()
        let bridge = makeBridge(
            methodWhitelist: [BridgeApiContract.methodHandshake, "busy", "ping"],
            transport: transport
        )
        let gate = BusyGate()
        bridge.registerAsyncHandler(method: "busy") { _, _, emitter in
            guard let emitter else { return }
            await emitter(.success(.object(["tick": .number(1)])), false)
            await gate.wait() // 挂起不收尾
            await emitter(.success(.object(["tick": .number(2)])), true)
        }
        bridge.registerSimpleHandler(method: "ping") { _, _ in
            .success(.object(["pong": .bool(true)]))
        }
        bridge.resetPageInstance()
        let sessionId = handshake(bridge: bridge)

        _ = bridge.processIncoming(
            messageJson: requestJson(id: "r62a", method: "busy", sessionId: sessionId, payload: [:], keep: true),
            origin: "file://"
        )
        // busy 首帧经 sendViaTransport 旁路推送
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentMessages.count, 1)
        let busyFrame = object(from: transport.sentMessages.first)
        XCTAssertEqual(busyFrame?["reqId"] as? String, "r62a")
        XCTAssertEqual(busyFrame?["done"] as? Bool, false) // busy 仅有首帧，无终帧逃逸

        // busy 仍挂起时发起 ping：dispatch 不得被未完成的流式 handler 阻塞
        let ping = bridge.processIncoming(
            messageJson: requestJson(id: "r62b", method: "ping", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        let pingJson = object(from: ping)
        XCTAssertEqual(pingJson?["reqId"] as? String, "r62b")
        XCTAssertEqual(pingJson?["done"] as? Bool, true) // ping 已完整落定
        XCTAssertEqual((pingJson?["payload"] as? [String: Any])?["pong"] as? Bool, true)

        // busy 依旧只有首帧（终帧不因 ping 而提前逃逸）
        XCTAssertEqual(transport.sentMessages.count, 1)

        await gate.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.sentMessages.count, 2)
        XCTAssertEqual(object(from: transport.sentMessages.last)?["done"] as? Bool, true)
    }

    func testC64_dispatchIgnoresNonRequestEnvelopes_tier1kindGuard() {
        // docs/09 C64：Tier-1 kind 路由守卫——standalone CoreBridge 对非 request 信封
        // （response/event 是 Native→JS 方向）不派发：同名 handler 不得被误命中、
        // 不产生任何响应帧。Tier-2 路径由 RequestShapePolicy 先行拒绝（既有用例覆盖）。
        let transport = FakeBridgeTransport()
        let core = CoreBridge(transport: transport)
        final class Flag { var value = false }
        let invoked = Flag()
        core.registerSimpleHandler(method: "leak.test") { _, _ in
            invoked.value = true
            return .success(.object(["leaked": .bool(true)]))
        }
        let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-64")

        // kind=response / kind=event 信封：命中注册表同名 method 也不得派发
        let responseKind = BridgeMessage.fromJsonString(
            "{\"id\":\"r64a\",\"sessionId\":\"\",\"kind\":\"response\",\"method\":\"leak.test\",\"reqId\":\"x\",\"done\":true,\"ok\":false}")
        let eventKind = BridgeMessage.fromJsonString(
            "{\"id\":\"r64b\",\"sessionId\":\"\",\"kind\":\"event\",\"method\":\"leak.test\",\"payload\":{}}")
        XCTAssertNotNil(responseKind)
        XCTAssertNotNil(eventKind)

        let droppedA = core.dispatch(request: responseKind!, context: context)
        let droppedB = core.dispatch(request: eventKind!, context: context)
        XCTAssertTrue(droppedA.isEmpty)
        XCTAssertTrue(droppedB.isEmpty)
        XCTAssertFalse(invoked.value)
        XCTAssertEqual(transport.sentMessages.count, 0)

        // 对照组：kind=request 正常派发（守卫不得误伤正常路径）
        let requestKind = BridgeMessage.fromJsonString(
            "{\"id\":\"r64c\",\"sessionId\":\"\",\"kind\":\"request\",\"method\":\"leak.test\",\"payload\":{}}")
        XCTAssertNotNil(requestKind)
        let served = core.dispatch(request: requestKind!, context: context)
        XCTAssertTrue(invoked.value)
        XCTAssertEqual(served.count, 1)
    }

    // MARK: - C65: 通配 {"*"} 是"策略节点不进链"而非"装配后放行一切"

    func testC65_wildcardSets_skipOriginAndMethodGate_realAssembly() {
        // C65：docs/09 —— 通配 {"*"} 是"对应策略节点不进链"而非"装配后放行一切"：
        // 以真实 JsBridge 装配验证（Origin/MethodGate 的通配排除分支若仅由策略链单测
        // 手拼链覆盖，无法拦截装配层回归）。白名单外方法 + 未白名单 origin 的请求
        // 仍能到达 handler；SessionPolicy 仍在链，换 origin 复用 session 必被拒。
        let provider = MutableOriginProvider(origin: "https://arbitrary.example")
        let bridge = makeBridge(
            allowedOrigins: ["*"],
            methodWhitelist: ["*"],
            pageContextProvider: provider
        )
        bridge.registerSimpleHandler(method: "not.in.whitelist") { _, payload in
            .success(payload)
        }
        bridge.resetPageInstance()

        // 握手：origin 由 provider 派生（任意 origin 皆可，OriginGate 未进链）
        let handshakeResponse = bridge.processIncoming(
            messageJson: requestJson(id: "h65", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:])
        )
        let sessionId = (object(from: handshakeResponse)?["payload"] as? [String: Any])?["sessionId"] as? String ?? ""
        XCTAssertFalse(sessionId.isEmpty)

        // 同 origin：Origin/MethodGate 均未进链 → 白名单外业务方法 ok=true 且 reqId 回显
        // （非通配配置下同输入为 E_ORIGIN_DENY / E_METHOD_NOT_ALLOWED，见 C04/C03）
        let allowed = bridge.processIncoming(
            messageJson: requestJson(id: "r65a", method: "not.in.whitelist", sessionId: sessionId, payload: [:])
        )
        let allowedJson = object(from: allowed)
        XCTAssertEqual(allowedJson?["ok"] as? Bool, true)
        XCTAssertEqual(allowedJson?["reqId"] as? String, "r65a")

        // 换 origin 复用 session：SessionPolicy 仍在链 → E_SESSION_INVALID
        // （通配只豁免对应维度，不影响 session origin 匹配语义）
        provider.origin = "https://other.example"
        let denied = bridge.processIncoming(
            messageJson: requestJson(id: "r65b", method: "not.in.whitelist", sessionId: sessionId, payload: [:])
        )
        XCTAssertEqual(errorCode(from: denied), "E_SESSION_INVALID")
    }

    // MARK: - SecurityConfig nil 字段构造校验（init precondition，子进程探针）

    func testSecurityConfig_withoutAllowedOrigins_preconditionTraps() {
        // SecurityConfig 存在即必须显式声明 allowedOrigins（nil = 未配置，构造期报错，
        // 对齐 Android IllegalArgumentException 分支）。precondition 为进程级 trap，
        // 经子进程探针断言（见 BridgeTestSupport.PreconditionProbe）。
        assertNilFieldTraps(probe: "allowedOrigins") { config in
            config.methodWhitelist = ["*"]
        }
    }

    func testSecurityConfig_withoutMethodWhitelist_preconditionTraps() {
        // 构造校验的对称半边：allowedOrigins 已有值、methodWhitelist 为 nil 同样构造期报错
        assertNilFieldTraps(probe: "methodWhitelist") { config in
            config.allowedOrigins = ["file://"]
        }
    }

    /// 探针测试共享骨架：探针子进程分支 + 父进程 expectTrap。
    /// `testCase` 默认参数由 Swift 在调用点求值为调用者的方法名，与类名拼出子进程选择器，
    /// 消除手抄字面量（方法重命名后探针会静默失效）。
    private func assertNilFieldTraps(
        probe: String,
        testCase: String = #function,
        configure: (inout JsBridge.SecurityConfig) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let active = PreconditionProbe.currentProbe() {
            // 子进程模式：仅本探针对应的分支执行触发构造
            guard active == probe else { return }
            var config = JsBridge.SecurityConfig()
            configure(&config)
            _ = JsBridge(securityConfig: config) // 对应字段 nil → 必须在此 trap
            PreconditionProbe.probeSurvived()
        }
        PreconditionProbe.expectTrap(
            probe: probe,
            testCase: "\(Self.self)/\(testCase)",
            bundle: Bundle(for: ConformanceCoreBaselineTests.self),
            file: file,
            line: line
        )
    }
}

/// C62 用例的挂起闸门：busy async handler 首帧发出后挂起，测试侧决定何时放行终帧。
private actor BusyGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in waiters {
            continuation.resume()
        }
        waiters = []
    }
}
