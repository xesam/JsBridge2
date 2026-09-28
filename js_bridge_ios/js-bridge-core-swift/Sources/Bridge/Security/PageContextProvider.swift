import Foundation

/// 由内核派生 TrustedPageContext 的注入点。
///
/// 当宿主向桥注入 PageContextProvider 时，origin 由内核从可信来源（如 WKWebView 实例）
/// 派生，宿主无法逐条伪造。这是四端一致的 origin 信任边界抽象：与 Android 的
/// `PageContextProvider` 等价。
///
/// 未注入 provider 时，**不存在**"宿主逐条传入 origin"的生产路径：
/// `processIncoming(messageJson:origin:)` 等带 origin / context 形参的入口
/// 仅为测试注入面（由 internal 限定访问，宿主不可达；见 docs/01-design-principles.md §4.4），
/// 且该入口的 origin 注入统一经 `OriginNormalizer` 归一化以保持信任边界一致
/// （见 docs/04-cross-platform.md §3.1）。生产宿主一律注入 provider 并通过
/// `bindTransport()` 闭环入场；provider 缺失时装配/处理期 fail-fast（preconditionFailure）。
public protocol PageContextProvider: AnyObject {
    func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext
}
