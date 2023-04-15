# 第 7 章：抽象传输层 BridgeTransport

## 本章目标
让核心桥接不关心“消息是如何在容器里传输的”。

## 为什么必须抽象传输层
如果 core 直接依赖 `android.webkit.WebView`，会有两个问题：
1. 用户自定义 WebView 容器时难接入。
2. 架构无法保持跨端一致（iOS/Flutter/HarmonyOS 只能重写一套完全不同结构）。

本仓库的约束是：transport 与 security 不得互相引用，transport 只做 I/O，不做策略判断。

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
- API ≥ M：`WebView.createWebMessageChannel()` 创建 `WebMessagePort` 对，向页面 `postWebMessage("bridge:init", port)` 注入 JS 端口，Native 持有另一端（`WebMessagePortMessageChannel`）。
- API < M：回退到 `LegacyJavascriptChannel`——即第 2 章的 `addJavascriptInterface`（代理对象 `$__native__`）+ `evaluateJavascript`（JS 入口 `window.__bridgeReceiveFromNative`）。

注意一个生命周期事实：每次页面导航都会销毁 MessageChannel，所以宿主要在 `onPageFinished` 重新 `bind()`（本仓库通过 `JsBridge.resetTransport()` 完成闭环，见第 9、15 章）。

## 验收清单
1. core 中不出现 `WebView` 类型。
2. 替换 transport 实现不影响 handler 业务代码。
3. `bind/close` 生命周期行为一致（`close` 释放旧 listener，避免重复回调）。

## 常见坑
1. 在 transport 层混入策略判断。
2. transport 直接依赖 core 内部类。
3. `close` 未释放旧 listener，导致重复回调。
4. 忘记页面导航后 MessageChannel 已失效，不重新 bind 就发消息。

## 小结
抽象传输层后，核心和宿主容器正式解耦。第 8 章继续抽象“可信上下文”。
