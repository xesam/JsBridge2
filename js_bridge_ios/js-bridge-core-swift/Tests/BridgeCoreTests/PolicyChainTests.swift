import XCTest
@testable import BridgeCore

final class PolicyChainTests: XCTestCase {

    // MARK: - C45: 策略链固定求值顺序与短路行为

    func testC45_policyChain_evaluatesInFixedOrder_requestShapeFirst() {
        // 第一层 RequestShapePolicy 拒绝 -> 短路，后续策略不执行
        let message = createMessage(kind: "event", method: "timerLog", sessionId: "")
        let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-a")
        let input = PolicyInput(message: message, trustedPageContext: context, ready: false, sessionRecord: nil)

        let policy = RequestShapePolicy()
        let decision = policy.evaluate(input)

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.error?.code, "E_INVALID_MESSAGE")
    }

    func testC45_policyChain_shortCircuitsOnFirstDenial() {
        // 构造一个策略链：RequestShapePolicy -> HandshakeGatePolicy -> OriginPolicy
        // 预期：HandshakeGatePolicy 拒绝后短路，OriginPolicy 不执行
        let rules: [PolicyRule] = [
            RequestShapePolicy(),
            HandshakeGatePolicy(),
            OriginPolicy(allowedOrigins: Set(["https://trusted.example"]))
        ]
        let engine = PolicyEngine(rules: rules)

        let message = createMessage(kind: "request", method: "getUser", sessionId: "s1")
        let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-a")
        let input = PolicyInput(message: message, trustedPageContext: context, ready: false, sessionRecord: nil)

        let decision = engine.evaluate(input)

        XCTAssertFalse(decision.allowed)
        // 断言：短路在 HandshakeGatePolicy，错误码是 E_NOT_READY，而不是 OriginPolicy 的 E_ORIGIN_DENY
        XCTAssertEqual(decision.error?.code, "E_NOT_READY")
    }

    func testC45_policyChain_continuesWhenAllAllow() {
        // 所有策略都通过 -> 返回 allow
        let rules: [PolicyRule] = [RequestShapePolicy()]
        let engine = PolicyEngine(rules: rules)

        let message = createMessage(kind: "request", method: "bridge.handshake", sessionId: "")
        let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-a")
        let input = PolicyInput(message: message, trustedPageContext: context, ready: false, sessionRecord: nil)

        let decision = engine.evaluate(input)

        XCTAssertTrue(decision.allowed)
    }

    // MARK: - C46: 安全级别切换 - 不同配置下的策略链组成

    func testC46_nullConfig_onlyRequestShapePolicy() {
        // 无配置（securityConfig == nil）：只有 RequestShapePolicy 激活
        let rules: [PolicyRule] = [RequestShapePolicy()]
        let engine = PolicyEngine(rules: rules)

        // 非 request 消息会被拒绝
        let invalidMessage = createMessage(kind: "event", method: "timerLog", sessionId: "")
        let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-a")
        let invalidInput = PolicyInput(message: invalidMessage, trustedPageContext: context, ready: false, sessionRecord: nil)

        var decision = engine.evaluate(invalidInput)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.error?.code, "E_INVALID_MESSAGE")

        // 有效的 request 消息会通过（因为没有其他策略）
        let validMessage = createMessage(kind: "request", method: "getUser", sessionId: "")
        let validInput = PolicyInput(message: validMessage, trustedPageContext: context, ready: false, sessionRecord: nil)

        decision = engine.evaluate(validInput)
        XCTAssertTrue(decision.allowed)
    }

    func testC46_wildcardConfig_requiresHandshakeButNoOriginMethodCheck() {
        // 有配置但 allowedOrigins={"*"} 和 methodWhitelist={"*"}
        // 策略链：RequestShapePolicy + HandshakeGatePolicy + SessionPolicy
        let rules: [PolicyRule] = [
            RequestShapePolicy(),
            HandshakeGatePolicy(),
            SessionPolicy()
        ]
        let engine = PolicyEngine(rules: rules)

        let message = createMessage(kind: "request", method: "anyMethod", sessionId: "s1")
        let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-a")

        // 未 ready 时，非握手调用被 HandshakeGatePolicy 拒绝
        let beforeHandshake = PolicyInput(message: message, trustedPageContext: context, ready: false, sessionRecord: nil)
        var decision = engine.evaluate(beforeHandshake)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.error?.code, "E_NOT_READY")

        // ready 后，但 session 不存在，被 SessionPolicy 拒绝
        let afterHandshakeNoSession = PolicyInput(message: message, trustedPageContext: context, ready: true, sessionRecord: nil)
        decision = engine.evaluate(afterHandshakeNoSession)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.error?.code, "E_SESSION_INVALID")
    }

    func testC46_fullConfig_fullPolicyChainWithOriginAndMethodCheck() {
        // 完整配置：完整策略链，包括 OriginPolicy 和 MethodGatePolicy
        let rules: [PolicyRule] = [
            RequestShapePolicy(),
            HandshakeGatePolicy(),
            OriginPolicy(allowedOrigins: Set(["https://trusted.example"])),
            MethodGatePolicy(methodWhitelist: Set(["bridge.handshake", "getUser"])),
            SessionPolicy()
        ]
        let engine = PolicyEngine(rules: rules)

        let validSession = SessionRecord(
            sessionId: "s1",
            origin: "https://trusted.example",
            pageInstanceId: "page-a",
            expiresAtMs: Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        )

        // origin 不在白名单 -> OriginPolicy 拒绝
        let untrustedMessage = createMessage(kind: "request", method: "getUser", sessionId: "s1")
        let untrustedContext = TrustedPageContext(origin: "https://untrusted.com", pageInstanceId: "page-a")
        let untrustedInput = PolicyInput(message: untrustedMessage, trustedPageContext: untrustedContext, ready: true, sessionRecord: validSession)

        var decision = engine.evaluate(untrustedInput)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.error?.code, "E_ORIGIN_DENY")

        // method 不在白名单 -> MethodGatePolicy 拒绝
        let unauthorizedMessage = createMessage(kind: "request", method: "deleteUser", sessionId: "s1")
        let trustedContext = TrustedPageContext(origin: "https://trusted.example", pageInstanceId: "page-a")
        let unauthorizedInput = PolicyInput(message: unauthorizedMessage, trustedPageContext: trustedContext, ready: true, sessionRecord: validSession)

        decision = engine.evaluate(unauthorizedInput)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.error?.code, "E_METHOD_NOT_ALLOWED")

        // 所有条件都满足 -> 通过
        let validMessage = createMessage(kind: "request", method: "getUser", sessionId: "s1")
        let validInput = PolicyInput(message: validMessage, trustedPageContext: trustedContext, ready: true, sessionRecord: validSession)

        decision = engine.evaluate(validInput)
        XCTAssertTrue(decision.allowed)
    }

    // MARK: - Helper Methods

    private func createMessage(kind: String, method: String, sessionId: String) -> BridgeMessage {
        let messageKind: BridgeMessageKind = kind == "request" ? .request : .event
        return BridgeMessage(
            id: "r1",
            sessionId: sessionId,
            kind: messageKind,
            method: method,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            timeoutMs: 10000,
            keep: false,
            payload: nil,
            reqId: nil,
            done: nil,
            ok: nil,
            error: nil
        )
    }
}
