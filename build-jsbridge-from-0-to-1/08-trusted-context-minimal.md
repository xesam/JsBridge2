# 第 8 章：最小可信上下文

## 本章目标
定义“框架应该信任什么”，并且只保留必要信息。

## 设计原则
框架层只输出可信事实，不替业务做策略决策。

推荐最小上下文：
- `origin`：来源标识（如 `file://`、`https://example.com`）。
- `pageInstanceId`：页面实例唯一 ID。

## 为什么不做复杂解析
把 URL、证书、业务账号等复杂判定都写进框架，会导致：
1. 核心职责膨胀。
2. 调用方失去策略自主权。
3. 跨端难统一语义。

## SPI 设计
```java
public interface PageContextProvider {
    TrustedPageContext createContext(BridgeMessage bridgeMessage, String pageInstanceId);
}
```

归属层级：`PageContextProvider` 位于 `security` 包（Tier 2），由 `JsBridge` 在收到消息后调用，产物 `TrustedPageContext` 有三个消费者——策略链（校验）、带上下文的 handler（`NativeMessageHandler` 参数）、extensions（WebView 适配）。Tier 1 的 `CoreBridge` 完全不感知它。

## Android 端实现
`extensions/system/AndroidWebViewPageContextProvider`：
- 从 WebView 当前状态提取最小可信信息（内部委托 `AndroidWebViewTrustedContextFactory`）。
- 返回 `TrustedPageContext(origin, pageInstanceId)`，null 字段归一化为空串。

## 验收清单
1. `JsBridge` 只依赖 `PageContextProvider` 抽象，不依赖具体 WebView。
2. `TrustedPageContext` 字段保持最小且稳定（只有 `origin` + `pageInstanceId`）。
3. 调用方可在策略层自行增加校验规则。

## 常见坑
1. 上下文字段过多，成为“万能上下文对象”。
2. 框架直接做业务风控判定。
3. 页面重绑后 `pageInstanceId` 未更新（见第 9 章 `resetForNewPage` 的轮换语义）。

## 小结
到这一步，Bridge 的关键注入点已经明确：`BridgeTransport` 和 `PageContextProvider`。第 9 章开始引入握手和会话能力，把它们组织成 `JsBridge`。
