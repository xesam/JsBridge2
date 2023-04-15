import XCTest
@testable import BridgeCore

/// 验证 JsBridge.bindTransport() 闭环：入站消息 → 策略检查 → 分发 → 响应通过 transport 自动发回。
final class BindTransportTests: XCTestCase {

    func test_bindTransport_handshakeRoundtrip_responseSentViaTransport() {
        let mock = MockTransport()
        let bridge = makeBridge(transport: mock)
        bridge.bindTransport()
        bridge.resetForNewPage()

        // 模拟 JS 发来 handshake 消息
        let handshakeJson = requestJson(
            id: "h1",
            method: BridgeApiContract.methodHandshake,
            sessionId: "",
            payload: [:]
        )
        mock.simulateIncoming(handshakeJson)

        // 验证 transport.send 被调用
        XCTAssertEqual(mock.sentMessages.count, 1)

        let response = parseJson(mock.sentMessages[0])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["method"] as? String, BridgeApiContract.methodHandshake)
        let payload = response["payload"] as? [String: Any]
        XCTAssertNotNil(payload?["sessionId"] as? String)
        XCTAssertEqual(payload?["accepted"] as? Bool, true)
    }

    func test_bindTransport_handlerDispatch_responseAutoSent() {
        let mock = MockTransport()
        let bridge = makeBridge(transport: mock)
        bridge.registerHandler(method: "echo") { payload in
            .success(payload)
        }
        bridge.bindTransport()
        bridge.resetForNewPage()

        // handshake 先建立 session
        let sessionId = handshakeViaTransport(bridge: bridge, mock: mock, origin: "file://")

        // 发送 echo 请求
        let echoJson = requestJson(
            id: "r1",
            method: "echo",
            sessionId: sessionId,
            payload: ["msg": "hello"]
        )
        mock.clearSentMessages()
        mock.simulateIncoming(echoJson)

        XCTAssertEqual(mock.sentMessages.count, 1)
        let response = parseJson(mock.sentMessages[0])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["method"] as? String, "echo")
        let payload = response["payload"] as? [String: Any]
        XCTAssertEqual(payload?["msg"] as? String, "hello")
    }

    func test_bindTransport_policyDeny_responseAutoSent() {
        let mock = MockTransport()
        let bridge = makeBridge(transport: mock)
        bridge.bindTransport()
        bridge.resetForNewPage()

        // 在未握手时发送非握手请求 → 策略拒绝
        let requestJson = requestJson(
            id: "r1",
            method: "echo",
            sessionId: "",
            payload: [:]
        )
        mock.simulateIncoming(requestJson)

        XCTAssertEqual(mock.sentMessages.count, 1)
        let response = parseJson(mock.sentMessages[0])
        XCTAssertEqual(response["ok"] as? Bool, false)
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "E_POLICY_DENY")
    }

    func test_bindTransport_multipleResponses_allSent() {
        let mock = MockTransport()
        let bridge = makeBridge(transport: mock)
        bridge.registerStreamingHandler(method: "multi") { payload in
            return [
                .success(.object(["seq": .number(1)]), done: false),
                .success(.object(["seq": .number(2)]), done: false),
                .success(.object(["seq": .number(3)]), done: true),
            ]
        }
        bridge.bindTransport()
        bridge.resetForNewPage()
        let sessionId = handshakeViaTransport(bridge: bridge, mock: mock, origin: "file://")

        let multiJson = requestJson(
            id: "m1",
            method: "multi",
            sessionId: sessionId,
            payload: [:]
        )
        mock.clearSentMessages()
        mock.simulateIncoming(multiJson)

        XCTAssertEqual(mock.sentMessages.count, 3)
        for (index, msg) in mock.sentMessages.enumerated() {
            let resp = parseJson(msg)
            XCTAssertEqual(resp["ok"] as? Bool, true)
            let payload = resp["payload"] as? [String: Any]
            XCTAssertEqual(payload?["seq"] as? Int, index + 1)
        }
    }

    func test_bindTransport_idempotent_repeatedCallUpdatesCallback() {
        let mock = MockTransport()
        let bridge = makeBridge(transport: mock)
        bridge.bindTransport()
        bridge.resetForNewPage()

        // 再次调用 bindTransport（幂等）
        bridge.bindTransport()

        // 仍然能正常处理消息
        let handshakeJson = requestJson(
            id: "h1",
            method: BridgeApiContract.methodHandshake,
            sessionId: "",
            payload: [:]
        )
        mock.simulateIncoming(handshakeJson)
        XCTAssertEqual(mock.sentMessages.count, 1)
    }

    // MARK: - Helpers

    private func makeBridge(transport: BridgeTransport) -> JsBridge {
        var config = JsBridge.SecurityConfig.secure()
        config.allowedOrigins = ["file://"]
        config.methodWhitelist = [
            BridgeApiContract.methodHandshake, "echo", "multi"
        ]
        config.defaultCapabilities = ["echo", "multi"]
        return JsBridge(
            securityConfig: config,
            pageContextProvider: StaticPageContextProvider(origin: "file://"),
            transport: transport
        )
    }

    private func handshakeViaTransport(bridge: JsBridge, mock: MockTransport, origin: String) -> String {
        let handshakeJson = requestJson(
            id: "h1",
            method: BridgeApiContract.methodHandshake,
            sessionId: "",
            payload: [:]
        )
        mock.clearSentMessages()
        mock.simulateIncoming(handshakeJson)
        let response = parseJson(mock.sentMessages[0])
        let payload = response["payload"] as? [String: Any]
        return payload?["sessionId"] as? String ?? ""
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

    private func parseJson(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Failed to parse JSON: \(json)")
            return [:]
        }
        return dict
    }
}

// MARK: - Mock Transport

private final class MockTransport: BridgeTransport {
    private var bindHandler: ((String) -> Void)?
    var sentMessages: [String] = []

    func bind(listener: @escaping (String) -> Void) {
        bindHandler = listener
    }

    @discardableResult
    func send(_ messageJson: String) -> Bool {
        sentMessages.append(messageJson)
        return true
    }

    func close() {
        bindHandler = nil
    }

    func simulateIncoming(_ messageJson: String) {
        bindHandler?(messageJson)
    }

    func clearSentMessages() {
        sentMessages.removeAll()
    }
}

// MARK: - Static PageContextProvider

private final class StaticPageContextProvider: PageContextProvider {
    private let origin: String

    init(origin: String) {
        self.origin = origin
    }

    func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext {
        TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId)
    }
}
