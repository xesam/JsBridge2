import XCTest
@testable import BridgeCore

final class ConformanceCoreBaselineTests: XCTestCase {
    func testC01_requestBeforeHandshake_deniedByGate() {
        let bridge = makeBridge()
        bridge.resetForNewPage()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r1", method: "echo", sessionId: "", payload: ["k": "v"]),
            origin: "file://"
        )
        XCTAssertNotNil(response)
        XCTAssertEqual(errorCode(from: response), "E_POLICY_DENY")
    }

    func testC02_handshake_returnsSessionPayload() {
        let bridge = makeBridge()
        bridge.resetForNewPage()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: "file://"
        )
        let json = object(from: response)
        let payload = json?["payload"] as? [String: Any]

        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertNotNil(payload?["sessionId"] as? String)
        XCTAssertNotNil(payload?["capabilities"] as? [Any])
        XCTAssertNotNil(payload?["sessionTtlMs"])
        XCTAssertEqual(payload?["policyVersion"] as? String, "1")
        XCTAssertEqual(payload?["origin"] as? String, "file://")
        XCTAssertEqual(payload?["accepted"] as? Bool, true)
    }

    func testC03_methodWhitelist_denied() {
        let bridge = makeBridge()
        bridge.resetForNewPage()
        let sessionId = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r2", method: "notAllowed", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_METHOD_NOT_ALLOWED")
    }

    func testC04_originDenied() {
        let bridge = makeBridge()
        bridge.resetForNewPage()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h1", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:]),
            origin: "https://evil.example"
        )
        XCTAssertEqual(errorCode(from: response), "E_ORIGIN_DENY")
    }

    func testC05_handshakeThenValidRequest_success() {
        let bridge = makeBridge()
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
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
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
        _ = handshake(bridge: bridge)

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r6", method: "echo", sessionId: "", payload: ["k": "v"]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    func testC07_requestMismatchedOrigin_denied() {
        let bridge = makeBridge(allowedOrigins: ["file://", "https://example.com"])
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r7", method: "echo", sessionId: sessionId, payload: ["k": "v"]),
            origin: "https://example.com"
        )
        XCTAssertEqual(errorCode(from: response), "E_SESSION_INVALID")
    }

    func testC08_requestMismatchedPageInstance_denied() {
        let bridge = makeBridge(allowedOrigins: ["file://"])
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
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

    func testC09_methodNotInSessionCapability_denied() {
        let bridge = makeBridge(
            allowedOrigins: ["file://"],
            methodWhitelist: [BridgeApiContract.methodHandshake, "echo", "noCap"],
            defaultCapabilities: ["echo"]
        )
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.registerHandler(method: "noCap") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r9", method: "noCap", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_CAPABILITY_DENY")
    }

    func testC10_handlerNotFound_returnsMethodNotFound() {
        let bridge = makeBridge(
            allowedOrigins: ["file://"],
            methodWhitelist: [BridgeApiContract.methodHandshake, "echo", "ghost"],
            defaultCapabilities: ["echo", "ghost"]
        )
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r10", method: "ghost", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_METHOD_NOT_FOUND")
    }

    func testC11_handlerThrows_normalizedToInternal() {
        let bridge = makeBridge()
        bridge.registerHandler(method: "echo") { _ in
            throw NSError(domain: "BridgeCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        bridge.resetForNewPage()
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
            defaultCapabilities: ["echo"],
            extraPolicies: [ExtraDenyPolicy()]
        )
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "r12", method: "echo", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(errorCode(from: response), "E_TEST_DENY")
    }

    func testC13_streamingResponse_emitsDoneFalseThenDoneTrue() {
        let bridge = makeBridge(
            allowedOrigins: ["file://"],
            methodWhitelist: [BridgeApiContract.methodHandshake, "stream"],
            defaultCapabilities: ["stream"]
        )
        bridge.registerStreamingHandler(method: "stream") { _ in
            [
                .success(.object(["tick": .number(1)]), done: false),
                .success(.object(["tick": .number(2)]), done: true)
            ]
        }
        bridge.resetForNewPage()
        let sessionId = handshake(bridge: bridge, origin: "file://")

        let responses = bridge.processIncomingResponses(
            messageJson: requestJson(id: "r13", method: "stream", sessionId: sessionId, payload: [:]),
            origin: "file://"
        )
        XCTAssertEqual(responses.count, 2)

        let first = object(from: responses[0])
        let second = object(from: responses[1])
        XCTAssertEqual(first?["done"] as? Bool, false)
        XCTAssertEqual(second?["done"] as? Bool, true)
    }

    func testC17_sendFailure_observableAndPostEventReturnsFalse() {
        let transport = FakeBridgeTransport()
        transport.sendEnabled = false
        let bridge = makeBridge(transport: transport)
        bridge.resetForNewPage()
        _ = handshake(bridge: bridge, origin: "file://")

        XCTAssertTrue(bridge.isReady())
        let sent = bridge.postEvent(method: BridgeApiContract.methodLifecycle, payload: .object(["state": .string("ready")]))
        XCTAssertFalse(sent)
        XCTAssertEqual(bridge.sendFailureCount, 1)
    }

    func testC18_resetForNewPageRotatesContextAndOldSessionInvalid() {
        let bridge = makeBridge()
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()
        let oldSessionId = handshake(bridge: bridge, origin: "file://")

        bridge.resetForNewPage()
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
        bridge.resetForNewPage()

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
        bridge.resetForNewPage()

        let response = bridge.processIncoming(
            messageJson: requestJson(id: "h-pp2", method: BridgeApiContract.methodHandshake, sessionId: "", payload: [:])
        )
        XCTAssertEqual(errorCode(from: response), "E_ORIGIN_DENY")
    }

    func testPageContextProvider_mismatchedOriginOnRequest_sessionInvalid() {
        let provider = MutableOriginProvider(origin: "file://")
        let bridge = makeBridge(allowedOrigins: ["file://", "https://example.com"], pageContextProvider: provider)
        bridge.registerHandler(method: "echo") { payload in .success(payload) }
        bridge.resetForNewPage()

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

    // MARK: - Level 0 tests (default SecurityConfig, no handshake required)

    func testDefaultConfig_isReadyImmediatelyAfterBindPage() {
        let bridge = JsBridge(securityConfig: JsBridge.SecurityConfig())
        XCTAssertFalse(bridge.isReady(), "bridge should not be ready before resetForNewPage")
        bridge.resetForNewPage()
        XCTAssertTrue(bridge.isReady())
    }

    func testDefaultConfig_handlerDispatchedWithoutHandshake() {
        let transport = FakeBridgeTransport()
        let bridge = JsBridge(securityConfig: JsBridge.SecurityConfig(), transport: transport)
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.resetForNewPage()

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
        let bridge = JsBridge(securityConfig: JsBridge.SecurityConfig(), transport: transport)
        bridge.resetForNewPage()

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
        bridge.resetForNewPage()

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
        bridge.resetForNewPage()

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
        bridge.resetForNewPage()
        _ = handshake(bridge: bridge)

        lifecycle.onHostEvent(state: "resumed")

        let events = lifecycleEvents(from: transport)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].state, "resumed")
        XCTAssertEqual(events[0].seq, 1)
        XCTAssertEqual(events[0].payloadKeyCount, 2)
    }

    private func makeBridge(
        allowedOrigins: Set<String> = ["file://"],
        methodWhitelist: Set<String> = [BridgeApiContract.methodHandshake, "echo"],
        defaultCapabilities: Set<String> = ["echo"],
        extraPolicies: [PolicyRule] = [],
        transport: BridgeTransport? = nil,
        pageContextProvider: PageContextProvider? = nil
    ) -> JsBridge {
        var config = JsBridge.SecurityConfig.secure()
        config.allowedOrigins = allowedOrigins
        config.methodWhitelist = methodWhitelist
        config.defaultCapabilities = defaultCapabilities
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

    private func errorCode(from jsonString: String?) -> String {
        let json = object(from: jsonString)
        let error = json?["error"] as? [String: Any]
        return (error?["code"] as? String) ?? ""
    }

    private func object(from jsonString: String?) -> [String: Any]? {
        guard
            let jsonString,
            let data = jsonString.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dict = object as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private func requestJson(id: String, method: String, sessionId: String, payload: [String: Any]) -> String {
        let request: [String: Any] = [
            "id": id,
            "sessionId": sessionId,
            "kind": "request",
            "method": method,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "timeoutMs": 10000,
            "keep": false,
            "payload": payload,
            "reqId": NSNull(),
            "done": NSNull(),
            "ok": NSNull(),
            "error": NSNull()
        ]
        let data = try! JSONSerialization.data(withJSONObject: request, options: [])
        return String(data: data, encoding: .utf8)!
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
}

private final class FakeBridgeTransport: BridgeTransport {
    var sendEnabled: Bool = true
    private(set) var sentMessages: [String] = []

    func bind(listener: @escaping (String) -> Void) {}

    @discardableResult
    func send(_ messageJson: String) -> Bool {
        sentMessages.append(messageJson)
        return sendEnabled
    }

    func close() {}
}
