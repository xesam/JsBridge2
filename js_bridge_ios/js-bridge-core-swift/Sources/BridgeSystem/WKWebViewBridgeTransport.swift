import Foundation
import WebKit
import BridgeCore

/// WKWebView 传输适配器。
///
/// 封装入站（`WKScriptMessageHandler`）与出站（`evaluateJavaScript`），
/// 自动处理 bootstrap script 注入、消息体类型转换、字符串转义。
/// 消费者只需创建实例并传给 `JsBridge`，无需手写任何 JS 或 WebView 管道代码。
///
/// 线程安全：`BridgeTransport` 方法标记为 `nonisolated` 以满足协议的非隔离要求。
/// 属性使用 `nonisolated(unsafe)`——WKWebView 的所有操作（init、send、close、
/// WKScriptMessageHandler 回调）在实践中均在主线程执行。`send()` 和 `close()`
/// 对 WebKit API 的调用通过 `DispatchQueue.main.async` 保证主线程安全。
///
/// 使用示例：
/// ```swift
/// let transport = WKWebViewBridgeTransport(webView: webView)
/// let bridge = JsBridge(securityConfig: config, pageContextProvider: provider, transport: transport)
/// bridge.bindTransport()
/// bridge.resetForNewPage()
/// ```
public final class WKWebViewBridgeTransport: NSObject, BridgeTransport, WKScriptMessageHandler {

    /// JS 侧 `postMessage` 的 handler 名称。
    /// 默认 `"NativeBridge"`，与 `native-transport.ts` 的检测路径一致。
    public let messageName: String

    private nonisolated(unsafe) weak var webView: WKWebView?
    private nonisolated(unsafe) var listener: ((String) -> Void)?
    private nonisolated(unsafe) var isRegistered = false

    /// 创建并注册到指定 WebView。
    /// - Parameters:
    ///   - webView: 目标 `WKWebView`；须在页面加载前调用。
    ///   - messageName: `WKScriptMessageHandler` 注册名。
    public init(webView: WKWebView, messageName: String = "NativeBridge") {
        self.webView = webView
        self.messageName = messageName
        super.init()
        registerHandler()
        injectBootstrap()
    }

    deinit {
        // Best-effort：必须在主线程操作 WKUserContentController。
        // 不调 close()——close() 依赖 isRegistered 状态，deinit 时状态可能不一致。
        let wv = webView
        let name = messageName
        DispatchQueue.main.async {
            wv?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: - BridgeTransport

    nonisolated public func bind(listener: @escaping (String) -> Void) {
        self.listener = listener
    }

    @discardableResult
    nonisolated public func send(_ messageJson: String) -> Bool {
        guard isRegistered, let webView else { return false }
        let escaped = jsonStringLiteral(messageJson)
        let js = "window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative(\"\(escaped)\")"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        return true
    }

    nonisolated public func close() {
        guard isRegistered, let webView else { return }
        let name = messageName
        DispatchQueue.main.async {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: name)
        }
        isRegistered = false
        listener = nil
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == messageName else { return }
        guard let body = normalizeBody(message.body) else { return }
        listener?(body)
    }

    // MARK: - Private

    private func registerHandler() {
        guard let webView else { return }
        webView.configuration.userContentController.add(self, name: messageName)
        isRegistered = true
    }

    private func injectBootstrap() {
        guard let webView else { return }
        let source = """
        (function() {
            if (!window.$__native__) { window.$__native__ = {}; }
            window.$__native__.callNativeApi = function(messageJson) {
                window.webkit.messageHandlers.\(messageName).postMessage(String(messageJson));
            };
        })();
        """
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(script)
        // 不存储 script 引用——removeUserScript(_:) 是 iOS 14+ API，
        // 而项目支持 iOS 13。user script 是纯 JS 字符串，不产生强引用，
        // 随 WKUserContentController 生命周期自然释放。
    }

    // 仅处理 String 和 [String: Any]——JS 侧始终调用 postMessage(String(json))，
    // dictionary 分支是 WKWebView 自动解析 JSON body 的防御性 fallback。
    private func normalizeBody(_ body: Any) -> String? {
        if let s = body as? String { return s }
        if let dict = body as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
        return nil
    }

    nonisolated private func jsonStringLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
