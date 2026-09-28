# 从 0 到 1 写一个 JsBridge

本教程适合第一次实现 JS-Native 通信框架的工程师。我们会一起完成一个可用、可扩展、可测试的 JsBridge 库，路径为"先打通，再抽象，再工程化"。

教程中出现的类名、API、错误码、协议字段与构建命令均与仓库实际实现对齐：Android 参考实现在 `js_bridge_android/js-bridge-core`，协议规范见 `docs/03-protocol.md`，iOS/Flutter/HarmonyOS 遵循同一协议。

## 我们将完成什么
- 打通 WebView 中 JS 与 Native 的双向通信
- 定义稳定的消息协议（request/response/event）
- 实现分层架构：协议分发核心 + 会话策略层 + 可选扩展
- 理解跨端一致性的实现路径

## 教程定位

**我们会学到**：JS-Native 双向通信如何建立、消息协议如何设计、安全策略如何嵌入。

**我们不会涉及**：生产级性能优化、完整测试覆盖、CI/CD 集成——这些属于工程化实践，超出"从 0 到 1"的范围。跨端一致性验收、可观测性等工程实践参考项目 `docs/` 目录下的深度文档。

## 学习路径

| 阶段 | 章节 |
|------|------|
| 最小互调 | 第 1-2 章 |
| 最小协议 | 第 3 章 |
| 可复用桥接核心 | 第 4-7 章 |
| 安全与会话 | 第 8-10 章 |
| 事件推送与集成 | 第 11-12 章 |
| 实现回顾 | 第 13 章 |

---

## [第 1 章：定义目标与边界](01-goals-and-scope.md)

JsBridge 是 JS 与 Native 之间的"协议化通信层"：定义调用、响应、错误的统一格式，不承载业务本身。

## [第 2 章：直接用框架能力打通](02-framework-direct-interop.md)

零抽象打通第一条链路：使用 WebView 框架原生能力实现 JS→Native 和 Native→JS 双向通信。

## [第 3 章：定义最小消息协议](03-minimal-protocol.md)

从字符串传输升级为结构化消息协议，定义请求/响应/事件三种消息类型，解决并发请求匹配和错误统一问题。

## [第 4 章：实现最小分发器](04-handler-dispatcher.md)

用 handler 注册替代 if-else 分发，让业务方法可动态扩展。

## [第 5 章：补齐异步回调语义](05-async-callback.md)

完善异步回调机制，支持单次响应和流式多帧响应。

## [第 6 章：提炼桥接内核 CoreBridge](06-core-bridge-extraction.md)

把桥接逻辑从 Activity 抽离为可复用内核，零 security 依赖，专注协议分发。

## [第 7 章：抽象传输层 BridgeTransport](07-transport-abstraction.md)

避免核心直接依赖具体 WebView 实现，transport 只做 I/O，解决跨平台适配问题。

## [第 8 章：引入最小可信上下文](08-trusted-context-minimal.md)

引入框架必须信任的最小信息：页面来源与实例标识，为后续安全校验提供基础。

## [第 9 章：握手与会话](09-handshake-session.md)

从"谁都能调"升级为"可控调用"，通过握手建立可信会话，引入 Tier 2 安全策略层。

## [第 10 章：策略引擎（渐进增强）](10-policy-engine.md)

实现可组合策略链，固定求值顺序和短路语义，支持二态安全配置（null / 完整 SecurityConfig）的渐进增强。

## [第 11 章：生命周期事件扩展](11-lifecycle-event-extension.md)

实现 Native 主动通知 JS 的事件通道，支持页面状态同步。

## [第 12 章：组装示例应用](12-example-app-integration.md)

给出完整的接入模板：初始化 bridge、注册 handler、页面生命周期管理。

## [第 13 章：实现回顾](13-implementation-review.md)

复盘分层架构、职责划分与语义一致性，明确后续演进方向。

---

## 附录 A：实际目录结构

```text
js_bridge_android/js-bridge-core/src/main/java/io/github/xesam/android/bridge/
  api/            # BridgeMessage、BridgeError、BridgeApiContract、TrustedPageContext
  core/           # CoreBridge + handler 接口
    transport/    # BridgeTransport SPI
  security/       # context / policy / session（Tier 2 组件）
  JsBridge.java   # Tier 2 入口
  extensions/     # lifecycle / registry / system（Tier 3，可选）
js_bridge_android/js-bridge-example/
```

iOS / Flutter / HarmonyOS 端为同构分层（Swift Package / Dart package / HAR），目录语义一致。

## 附录 B：每章实践方式

每章按同一流程执行：新增或修改 1~3 个类 → 补 1~2 个针对性测试 → 运行一次最小构建命令 → 在示例页面手动验证一个场景。

## 每章验证命令

```bash
cd js_bridge_android
./gradlew :js-bridge-core:test :js-bridge-example:assembleDebug
```

涉及 JS 侧行为时运行共享 conformance 用例：

```bash
node js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js
```
