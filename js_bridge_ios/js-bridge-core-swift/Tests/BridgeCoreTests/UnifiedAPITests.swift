import XCTest
@testable import BridgeCore

/// 测试统一 Handler API：Simple / Async 两态，页面上下文为 handler 第一个形参
final class UnifiedAPITests: XCTestCase {

    // MARK: - Simple Handler Tests

    func testSimpleHandler_success() throws {
        let transport = FakeBridgeTransport()
        let bridge = CoreBridge(transport: transport)

        // 使用 SimpleHandler API：ctx 为第一个形参，单帧响应 done 恒为 true
        bridge.registerSimpleHandler(method: "echo") { _, payload in
            return .success(payload)
        }

        let request = BridgeMessage(
            id: "req1",
            sessionId: "s1",
            kind: .request,
            method: "echo",
            payload: .string("hello")
        )

        let responses = bridge.dispatch(request: request, context: TrustedPageContext.dummy())

        XCTAssertEqual(responses.count, 1)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: responses[0].data(using: .utf8)!)
        XCTAssertEqual(decoded.ok, true)
        XCTAssertEqual(decoded.payload, .string("hello"))
        XCTAssertEqual(decoded.done, true)
    }

    // MARK: - Async Handler Tests

    func testAsyncHandler_immediateReturn() throws {
        let transport = FakeBridgeTransport()
        let bridge = CoreBridge(transport: transport)
        bridge.attachTransport(transport)

        // 使用 AsyncHandler API - 显式类型标注
        let asyncHandler: AsyncHandler = { _, _, emit in
            // Handler 不使用 emit，仅用于测试立即返回
        }
        bridge.registerAsyncHandler(method: "test", handler: asyncHandler)

        let request = BridgeMessage(
            id: "req1",
            sessionId: "s1",
            kind: .request,
            method: "test",
            payload: nil
        )

        // dispatch 应该立即返回空数组
        let responses = bridge.dispatch(request: request, context: TrustedPageContext.dummy())
        XCTAssertEqual(responses.count, 0, "Async handler dispatch should return empty array immediately")
    }

    // MARK: - AsyncHandler transport-level verification

    func testAsyncHandler_framesArriveAtTransport_withCorrectReqId() async throws {
        let transport = FakeBridgeTransport()
        let bridge = CoreBridge(transport: transport)
        bridge.attachTransport(transport)

        let asyncHandler: AsyncHandler = { _, _, emit in
            guard let emit else { return }
            await emit(.success(.object(["n": .number(1)])), false)
            await emit(.success(.object(["n": .number(2)])), true)
        }
        bridge.registerAsyncHandler(method: "multi", handler: asyncHandler)

        let request = BridgeMessage(
            id: "r123",
            sessionId: "s1",
            kind: .request,
            method: "multi",
            payload: nil
        )

        _ = bridge.dispatch(request: request, context: TrustedPageContext.dummy())

        // 等待异步帧到达
        try await Task.sleep(nanoseconds: 20_000_000)

        let frames = transport.framesForReqId("r123")
        XCTAssertEqual(frames.count, 2, "Should receive 2 frames")

        // 验证每帧的 reqId 和 kind
        for frame in frames {
            XCTAssertEqual(frame.reqId, "r123")
            XCTAssertEqual(frame.kind, .response)
        }

        // 验证 done 状态序列
        XCTAssertEqual(frames[0].done, false)
        XCTAssertEqual(frames[1].done, true)
    }

    func testAsyncHandler_emitError_sendsFailureFrame() async throws {
        let transport = FakeBridgeTransport()
        let bridge = CoreBridge(transport: transport)
        bridge.attachTransport(transport)

        let asyncHandler: AsyncHandler = { _, _, emit in
            guard let emit else { return }
            await emit(.failure(BridgeError(code: "E_TEST", message: "test error")), true)
        }
        bridge.registerAsyncHandler(method: "failing", handler: asyncHandler)

        let request = BridgeMessage(
            id: "r1",
            sessionId: "s1",
            kind: .request,
            method: "failing",
            payload: nil
        )

        _ = bridge.dispatch(request: request, context: TrustedPageContext.dummy())
        try await Task.sleep(nanoseconds: 10_000_000)

        let frames = transport.framesForReqId("r1")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].ok, false)
        XCTAssertEqual(frames[0].error?.code, "E_TEST")
        XCTAssertEqual(frames[0].done, true)
    }

    func testAsyncHandler_throwsException_normalizedToInternal() async throws {
        let transport = FakeBridgeTransport()
        let bridge = CoreBridge(transport: transport)
        bridge.attachTransport(transport)

        let asyncHandler: AsyncHandler = { _, _, emit in
            throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        bridge.registerAsyncHandler(method: "throws", handler: asyncHandler)

        let request = BridgeMessage(
            id: "r1",
            sessionId: "s1",
            kind: .request,
            method: "throws",
            payload: nil
        )

        _ = bridge.dispatch(request: request, context: TrustedPageContext.dummy())
        try await Task.sleep(nanoseconds: 10_000_000)

        let frames = transport.framesForReqId("r1")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].ok, false)
        XCTAssertEqual(frames[0].error?.code, BridgeApiContract.errorInternal)
    }
}

// MARK: - TrustedPageContext Extension

private extension TrustedPageContext {
    static func dummy() -> TrustedPageContext {
        TrustedPageContext(
            origin: "file://",
            pageInstanceId: "test-page"
        )
    }
}
