import XCTest
@testable import BridgeCore

/// 验证 JsBridge.bindTransport() 闭环：入站消息 → 策略检查 → 分发 → 响应通过 transport 自动发回。
final class BindTransportTests: XCTestCase {

    func test_bindTransport_handshakeRoundtrip_responseSentViaTransport() {
        let mock = FakeBridgeTransport()
        let bridge = makeBridge(transport: mock)
        bridge.bindTransport()
        bridge.resetPageInstance()

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

        let response = object(from: mock.sentMessages[0])
        XCTAssertEqual(response?["ok"] as? Bool, true)
        XCTAssertEqual(response?["method"] as? String, BridgeApiContract.methodHandshake)
        let payload = response?["payload"] as? [String: Any]
        XCTAssertNotNil(payload?["sessionId"] as? String)
        XCTAssertEqual(payload?["accepted"] as? Bool, true)
    }

    func test_bindTransport_handlerDispatch_responseAutoSent() {
        let mock = FakeBridgeTransport()
        let bridge = makeBridge(transport: mock)
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            .success(payload)
        }
        bridge.bindTransport()
        bridge.resetPageInstance()

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
        let response = object(from: mock.sentMessages[0])
        XCTAssertEqual(response?["ok"] as? Bool, true)
        XCTAssertEqual(response?["method"] as? String, "echo")
        let payload = response?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["msg"] as? String, "hello")
    }

    func test_bindTransport_policyDeny_responseAutoSent() {
        let mock = FakeBridgeTransport()
        let bridge = makeBridge(transport: mock)
        bridge.bindTransport()
        bridge.resetPageInstance()

        // 在未握手时发送非握手请求 → 策略拒绝
        let denyJson = requestJson(
            id: "r1",
            method: "echo",
            sessionId: "",
            payload: [:]
        )
        mock.simulateIncoming(denyJson)

        XCTAssertEqual(mock.sentMessages.count, 1)
        let response = object(from: mock.sentMessages[0])
        XCTAssertEqual(response?["ok"] as? Bool, false)
        XCTAssertEqual(errorCode(from: mock.sentMessages[0]), "E_NOT_READY") // v1: 握手门禁从 E_POLICY_DENY 分立
    }

    func test_bindTransport_multipleResponses_allSent() async {
        let mock = FakeBridgeTransport()
        let bridge = makeBridge(transport: mock)
        // 多帧响应只能经 AsyncHandler + ResponseEmitter 表达
        let asyncHandler: AsyncHandler = { _, _, emitter in
            guard let emitter else { return }
            await emitter(.success(.object(["seq": .number(1)])), false)
            await emitter(.success(.object(["seq": .number(2)])), false)
            await emitter(.success(.object(["seq": .number(3)])), true)
        }
        bridge.registerAsyncHandler(method: "multi", handler: asyncHandler)
        bridge.bindTransport()
        bridge.resetPageInstance()
        let sessionId = handshakeViaTransport(bridge: bridge, mock: mock, origin: "file://")

        let multiJson = requestJson(
            id: "m1",
            method: "multi",
            sessionId: sessionId,
            payload: [:]
        )
        mock.clearSentMessages()
        mock.simulateIncoming(multiJson)

        // 异步帧经 transport 旁路推送，等待其到达
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mock.sentMessages.count, 3)
        for (index, msg) in mock.sentMessages.enumerated() {
            let resp = object(from: msg)
            XCTAssertEqual(resp?["ok"] as? Bool, true)
            let payload = resp?["payload"] as? [String: Any]
            XCTAssertEqual(payload?["seq"] as? Int, index + 1)
        }
    }

    func test_bindTransport_idempotent_repeatedCallUpdatesCallback() {
        let mock = FakeBridgeTransport()
        let bridge = makeBridge(transport: mock)
        bridge.bindTransport()
        bridge.resetPageInstance()

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
        var config = JsBridge.SecurityConfig()
        config.allowedOrigins = ["file://"]
        config.methodWhitelist = [
            BridgeApiContract.methodHandshake, "echo", "multi"
        ]
        return JsBridge(
            securityConfig: config,
            pageContextProvider: StaticPageContextProvider(origin: "file://"),
            transport: transport
        )
    }

    private func handshakeViaTransport(bridge: JsBridge, mock: FakeBridgeTransport, origin: String) -> String {
        let handshakeJson = requestJson(
            id: "h1",
            method: BridgeApiContract.methodHandshake,
            sessionId: "",
            payload: [:]
        )
        mock.clearSentMessages()
        mock.simulateIncoming(handshakeJson)
        let response = object(from: mock.sentMessages[0])
        let payload = response?["payload"] as? [String: Any]
        return payload?["sessionId"] as? String ?? ""
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
