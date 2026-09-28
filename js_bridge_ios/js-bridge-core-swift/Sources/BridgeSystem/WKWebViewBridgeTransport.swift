import Foundation
import WebKit
import BridgeCore

/// WKWebView 传输适配器。
///
/// 封装入站（`WKScriptMessageHandler`）与出站（`evaluateJavaScript`），
/// 自动处理 bootstrap script 注入、消息体类型转换、字符串转义。
/// 消费者只需创建实例并传给 `JsBridge`，无需手写任何 JS 或 WebView 管道代码。
///
/// 线程安全（docs/07 §4）：`BridgeTransport` 方法为 `nonisolated`——`send()` 可能
/// 来自 CoreBridge 的 async handler `Task`（任意执行器），`bind()`/`close()` 来自
/// 宿主任意线程，`WKScriptMessageHandler` 回调在主线程。所有可变状态
/// （`listener` / `isRegistered`）由 `stateLock` 保护；对 WebKit API 的调用一律
/// hop 到主线程。
///
/// 注册与反注册：`WKUserContentController` 会**强持有** `WKScriptMessageHandler`，
/// 若直接注册 `self` 会形成 "UCC → transport" 强持有环，transport 永不 deinit
/// （其 deinit 清理成为死代码）。故经 `WeakScriptMessageHandler` 转发箱注册——
/// UCC 只强持有轻量转发箱，transport 释放可达。注意 `removeScriptMessageHandler`
/// 是**按 name** 移除：同一 `WKWebView` 上以同一 `messageName` 构造多个实例属宿主
/// 配置错误，任一实例 `close()` 将摘除该 name 下的当前注册者。
///
/// 使用示例：
/// ```swift
/// let transport = WKWebViewBridgeTransport(webView: webView)
/// let bridge = JsBridge(securityConfig: config, pageContextProvider: provider, transport: transport)
/// bridge.bindTransport()
/// bridge.resetPageInstance()
/// ```
public final class WKWebViewBridgeTransport: NSObject, BridgeTransport, @unchecked Sendable {

    /// JS 侧 `postMessage` 的 handler 名称。
    /// 默认 `"NativeBridge"`，与 `native-transport.ts` 的检测路径一致。
    public let messageName: String

    // nonisolated(unsafe) + stateLock：所有可变属性仅经 withState 访问；
    // webView 仅在 init 赋值后只读（weak 属性读取本身线程安全）。
    private nonisolated(unsafe) weak var webView: WKWebView?
    private nonisolated(unsafe) var listener: ((String) -> Void)?
    private nonisolated(unsafe) var isRegistered = false
    private nonisolated(unsafe) var forwarder: WeakScriptMessageHandler?
    private let stateLock = NSLock()

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
        // WeakScriptMessageHandler 打破 UCC 强持有环，本 deinit 可达（原实现的
        // WKScriptMessageHandler 强持有使此处为死代码）。主线程操作 UCC，best-effort。
        let wv = webView
        let name = messageName
        DispatchQueue.main.async {
            wv?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: - BridgeTransport

    nonisolated public func bind(listener: @escaping (String) -> Void) {
        withState {
            self.listener = listener
        }
    }

    /// 异步发送失败的说明见 docs/07 §4.4：`evaluateJavaScript` 的延迟错误回调
    /// 在本 v1 观测面收敛后不对外暴露（四端发送链失败观测口径以该节为准），
    /// 「receive 未挂载」因短路形态与成功不可区分，为已知边界。
    @discardableResult
    nonisolated public func send(_ messageJson: String) -> Bool {
        guard withState({ isRegistered }), let webView else { return false }
        let escaped = jsonStringLiteral(messageJson)
        let js = "window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive(\"\(escaped)\")"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        return true
    }

    nonisolated public func close() {
        guard withState({ isRegistered }), let webView else { return }
        let name = messageName
        DispatchQueue.main.async {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: name)
        }
        withState {
            isRegistered = false
            listener = nil
        }
    }

    // MARK: - 状态锁

    /// iOS 13 基线无 `NSLock.withLock`，手写对应物：简单重入一律禁止（调用方不得在锁内回调宿主代码）。
    nonisolated private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // MARK: - 入站回调（经 WeakScriptMessageHandler 转发，WebKit 保证主线程）

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // 转发箱以 transport 的 messageName 注册（registerHandler），UCC 只会为该
        // name 回调本实例——无需再按 name 二次分发。同名多次注册属宿主配置错误，
        // 由 close() 的按 name 移除语义承担（见类注释）。
        // 建链信任边界（docs/03 §9 细则 5）：仅主 frame 可作为消息来源。
        // 跨域 iframe 可通过 window.webkit.messageHandlers 冒充主 frame 伪造 bridge 信封，
        // frameInfo 门控将此类消息直接拒收——不响应、不触发握手（验收锚点 C58）。
        guard message.frameInfo.isMainFrame else { return }
        guard let body = normalizeBody(message.body) else { return }
        let listener = withState { self.listener }
        listener?(body)
    }

    // MARK: - Private

    /// 经弱转发箱注册：UCC 只强持有转发箱，打破 "UCC → transport" 持有环。
    private func registerHandler() {
        guard let webView else { return }
        let forwarder = WeakScriptMessageHandler(delegate: self)
        self.forwarder = forwarder
        webView.configuration.userContentController.add(forwarder, name: messageName)
        isRegistered = true
    }

    private func injectBootstrap() {
        guard let webView else { return }
        let source = """
        (function() {
            if (!window.__jsbridge2__) { window.__jsbridge2__ = {}; }
            window.__jsbridge2__.callNativeApi = function(messageJson) {
                window.webkit.messageHandlers.\(messageName).postMessage(String(messageJson));
            };
        })();
        """
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            // bootstrap 仅注入主 frame：bridge 信封只该在主 frame 生效，
            // iframe 中不应存在 callNativeApi 通道（验收锚点 C58）
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(script)
        // 不存储 script 引用——removeUserScript(_:) 是 iOS 14+ API，
        // 而项目支持 iOS 13。user script 是纯 JS 字符串，不产生强引用，
        // 随 WKUserContentController 生命周期自然释放。
    }

    // 仅处理 String 和 [String: Any]。SDK bootstrap 恒 postMessage(String(json))，
    // 故 String 为正常路径；dictionary 分支覆盖页面任意 JS 绕过 bootstrap 直接以
    // object 调 postMessage 的输入（WebKit 不自动解析 String body）——统一转 JSON
    // 后交由解析层按信封规则处理（不构成合法信封时静默丢弃）。
    private func normalizeBody(_ body: Any) -> String? {
        if let s = body as? String { return s }
        if let dict = body as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
        return nil
    }

    /// 嵌入 evaluateJavaScript 字符串字面量的转义。除常规转义外必须覆盖
    /// U+2028 / U+2029（行/段分隔符）：ES2019 前的 JS 引擎视为裸换行，
    /// 出现在响应 payload 中会令整段 evaluate 语法错——响应整体黑洞，
    /// JS 悬挂至超时（E_TIMEOUT 伪装真实故障类别）。
    nonisolated private func jsonStringLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// WKScriptMessageHandler 弱转发箱：`WKUserContentController` 强持有本箱，
/// 本箱弱持有 transport——打破 "UCC → transport" 强持有环（transport 可正常 deinit，
/// 其 deinit 中的清理因此可达）。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    private weak var delegate: WKWebViewBridgeTransport?

    init(delegate: WKWebViewBridgeTransport) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
