import XCTest
import WebKit
import BridgeCore
import BridgeSystem

/// 验证 WKWebViewBridgeTransport 的基本行为。
///
/// 注意：WKWebView 在测试环境中无法加载真实页面，因此入站消息路径
/// 通过验证 handler 注册和 UCC 状态间接测试。
/// bindTransport 闭环测试见 BridgeCoreTests/BindTransportTests。
final class WKWebViewBridgeTransportTests: XCTestCase {

    // MARK: - messageName

    func test_messageName_default_isNativeBridge() {
        let webView = makeWebView()
        let transport = WKWebViewBridgeTransport(webView: webView)
        XCTAssertEqual(transport.messageName, "NativeBridge")
        transport.close()
    }

    func test_messageName_custom() {
        let webView = makeWebView()
        let transport = WKWebViewBridgeTransport(webView: webView, messageName: "customBridge")
        XCTAssertEqual(transport.messageName, "customBridge")
        transport.close()
    }

    // MARK: - send

    func test_send_returnsTrue_whenWebViewAlive() {
        let webView = makeWebView()
        let transport = WKWebViewBridgeTransport(webView: webView)
        let result = transport.send("{\"id\":\"test\"}")
        XCTAssertTrue(result)
        transport.close()
    }

    func test_send_returnsFalse_afterClose() {
        let webView = makeWebView()
        let transport = WKWebViewBridgeTransport(webView: webView)
        transport.close()
        let result = transport.send("{\"id\":\"test\"}")
        XCTAssertFalse(result)
    }

    // MARK: - close idempotency

    func test_close_isIdempotent() {
        let webView = makeWebView()
        let transport = WKWebViewBridgeTransport(webView: webView)
        transport.close()
        // 第二次调用不应崩溃
        transport.close()
    }

    // MARK: - handler registration

    func test_init_withDistinctNames_injectsIndependentBootstrapScripts() {
        let webView = makeWebView()
        // WKUserContentController 无公开接口可查询已注册 handler，handler 注册因此
        // 间接由「每个 transport 各注入自身 bootstrap script」验证（同一 webview 可
        // 并存多个 transport）。不同 handler 名亦避免 async close 的竞态。
        let ucc = webView.configuration.userContentController
        let initialScriptCount = ucc.userScripts.count
        let transport1 = WKWebViewBridgeTransport(webView: webView, messageName: "handlerA")
        let transport2 = WKWebViewBridgeTransport(webView: webView, messageName: "handlerB")
        XCTAssertEqual(ucc.userScripts.count, initialScriptCount + 2)
        XCTAssertEqual(transport1.messageName, "handlerA")
        XCTAssertEqual(transport2.messageName, "handlerB")
        transport1.close()
        transport2.close()
    }

    // MARK: - bind

    func test_bind_acceptsListener_andTransportStaysUsable() {
        let webView = makeWebView()
        let transport = WKWebViewBridgeTransport(webView: webView)
        var received: String?
        transport.bind { json in received = json }
        // 测试环境无法构造 WKScriptMessage，存储后的投递行为不可直接观测；
        // 至少验证 bind 后不自发投递、且 transport 仍可发送
        XCTAssertNil(received)
        XCTAssertTrue(transport.send("{\"id\":\"after-bind\"}"))
        transport.close()
    }

    // MARK: - bootstrap script injection

    func test_init_injectsBootstrapScript() {
        let webView = makeWebView()
        let ucc = webView.configuration.userContentController
        let initialScriptCount = ucc.userScripts.count
        let transport = WKWebViewBridgeTransport(webView: webView)
        // 验证 bootstrap script 被注入
        XCTAssertEqual(ucc.userScripts.count, initialScriptCount + 1)
        transport.close()
    }

    // MARK: - Helpers

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        return WKWebView(frame: .zero, configuration: config)
    }
}
