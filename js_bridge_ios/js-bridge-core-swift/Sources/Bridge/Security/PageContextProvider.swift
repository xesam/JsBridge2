import Foundation

/// 由内核派生 TrustedPageContext 的注入点。
///
/// 当宿主向桥注入 PageContextProvider 时，origin 由内核从可信来源（如 WKWebView 实例）
/// 派生，宿主无法逐条伪造。这是四端一致的 origin 信任边界抽象：与 Android 的
/// `PageContextProvider` 等价。未注入时，宿主仍可通过 `processIncoming(messageJson:origin:)`
/// 逐条传入 origin，但该路径的 origin 可信度依赖宿主自律（见 docs/03-cross-platform.md §3.2）。
public protocol PageContextProvider: AnyObject {
    func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext
}
