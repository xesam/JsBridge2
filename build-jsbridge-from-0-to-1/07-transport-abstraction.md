# 第 7 章：抽象传输层 BridgeTransport

## 目标
让核心桥接不依赖具体 WebView 实现。core 直接依赖 `android.webkit.WebView` 有两个问题：用户自定义 WebView 容器时难接入；架构无法保持跨端一致。本仓库的约束是：transport 只做 I/O，不做策略判断，与 security 互不引用。

## SPI 设计
```java
public interface BridgeTransport {
    interface Listener { void onMessage(String messageJson); }
    void bind(Listener listener);
    boolean send(String messageJson);
    void close();
}
```

## 角色分工
- `BridgeTransport`：只关心 I/O（收发字符串消息）。
- `CoreBridge`：只关心协议、分发、回包。
- 第 9 章的 `JsBridge`：拦截 transport 入口，在分发前插入策略链。

## Android 适配器
`extensions/system/AndroidWebViewBridgeTransport` 实现了 `BridgeTransport`，内部通过 `WebMessageChannelBootstrapper` 建立具体通道：
- API ≥ M：**pull 模型（v1）**——页面经 `__jsbridge2__.requestBridgeChannel({reqId})` 哑入口拉取信道，Native `createWebMessageChannel()` 建 `WebMessagePort` 对，以 `bridge:channel` 信封 `{"type":"bridge:channel","reqId":...}` 投递 JS 端口（reqId 配对采纳），Native 持有另一端（`WebMessagePortMessageChannel`）。详见 docs/06（信道建立）与 docs/04 §3.1 通道建立入口契约。
- API < M：回退到 `LegacyJavascriptChannel`——即第 2 章的 `addJavascriptInterface`（代理对象 `__jsbridge2__`）+ `evaluateJavascript`（JS 入口 `window.__jsbridge2__.receive`）。

还有一个容易被忽略的生命周期事实：每次页面导航都会使既有通道失效，所以宿主要在 `onPageFinished` 重新 `bind()`——v1 pull 模型下 bind 的职责是 **invalidate/轮换**（关闭旧通道、轮换绑定周期），新通道由页面拉取时重建（本仓库通过 `JsBridge.resetTransport()` 完成闭环，见第 9、12 章）。

## 验收清单
1. core 中不出现 `WebView` 类型。
2. 替换 transport 实现不影响 handler 业务代码。
3. `bind/close` 生命周期行为一致（`close` 释放旧 listener，避免重复回调）。

## 常见坑
1. 在 transport 层混入策略判断。
2. transport 直接依赖 core 内部类。
3. `close` 未释放旧 listener，导致重复回调。
4. 忘记页面导航后 MessageChannel 已失效，不重新 bind 就发消息。
