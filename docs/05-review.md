# 05 架构评审：原则落地情况

本文以项目自述的设计原则为标尺，核查架构与 API 设计的实际落地情况。评审时间：2026-07。

标尺来自 [03-cross-platform.md §1.2](03-cross-platform.md#12-五条设计原则) 的五条原则，重点考察三个问题：

1. **渐进增强**是否真的做到"除核心协议外全部可插拔"
2. core 层是否**平台无关**
3. API 是否**与 Page（WebView 页面）实现解耦**

结论摘要：分层与依赖方向兑现彻底；渐进增强四端一致落地；平台无关性在 core 层成立；**"与 Page 实现无关"只做到一半**，且跨端 API 形态存在影响可迁移性的差异。

> **v1 修复落地（2026-07）**：本文原列出的 P0–P3 问题已在 v1 全部修复（v1 不考虑 API 兼容，破坏性改动已落地）。下文各节保留原评审内容作为历史记录，§5 改进表标注最终处置。
>
> - **P0 错误码单一事实源**：四端 `BridgeApiContract` 新增 8 个协议错误码常量（`E_INVALID_MESSAGE` / `E_POLICY_DENY` / `E_ORIGIN_DENY` / `E_METHOD_NOT_ALLOWED` / `E_SESSION_INVALID` / `E_CAPABILITY_DENY` / `E_METHOD_NOT_FOUND` / `E_INTERNAL`），策略链与 handler 中的内联字面量全部替换为常量引用。
> - **P1 PageContextProvider 等价抽象**：iOS / Flutter / HM 新增 `PageContextProvider` 注入点，与 Android 对齐；示例改用 provider 路径由内核从 WebView 派生 origin，四端 Level 2 安全强度等强。未注入 provider 时退化为 `processIncomingResponses(messageJson, origin)` 宿主声明路径，可信度依赖宿主自律（§3.2 已显式声明）。
> - **P1 allowedOrigins 通配警示**：四端在构造期拒绝 `requireAccessControl && allowedOrigins 含 "*"` 的组合（Android 抛 `IllegalArgumentException`、iOS 触发 `preconditionFailure`、Flutter / HM 抛 `ArgumentError` / `Error`），消除"升级却未获防护"的反直觉组合。
> - **P2 Flutter SecurityConfig**：Flutter 引入 `SecurityConfig` 类型与 `secure()` 工厂，与其余三端对齐，分级模型在该端有了类型载体。
> - **P3 bindPage 改名 + handler 上下文可选**：`bindPage()` 更名为 `resetForNewPage()`（真实语义为会话代次轮换）；业务 handler 默认改为 payload-only（`registerHandler` / `registerNativeHandler`），需要上下文时改用 `registerHandlerWithContext` / `registerNativeHandlerWithContext`，不再强制每个 handler 感知 Page。
> - 一致性用例补全：四端新增 `PageContextProvider` 内核派生路径与 `allowedOrigins` 通配拒绝的用例；JS 客户端一致性脚本（C14–C23）改为加载 `jsbridge-sdk.js` bundle，随 WebAssets 散文件→bundle 的布局变更一并修复。

---

## 1 渐进增强：已兑现

四端默认状态一致，策略链均按开关条件装配——`RequestShapePolicy` 无条件加入，握手门控与访问控制 opt-in，`extraPolicies` 追加末尾。

| 平台 | 默认值位置 | 策略链装配位置 |
|------|-----------|--------------|
| Android | `requireHandshake=false` / `requireAccessControl=false`（`JsBridge.java + CoreBridge.java:60-61`） | 同文件 `:135-144` |
| iOS | `SecurityConfig`（`JsBridge.swift + CoreBridge.swift:19-20`） | 同文件 `:54-64` |
| Flutter | 构造函数参数（`js_bridge.dart:66-67`） | `_buildPolicyEngine()` `:91-106` |
| HarmonyOS | `?? false`（`JsBridge.ets + CoreBridge.ets:109-110`） | 同文件 `:112-122` |

`bindPage()` 中 `ready = !requireHandshake` 四端一致（`JsBridge.java + CoreBridge.java:198`、`.swift:124`、`.dart:138`、`.ets:162`），Level 0 下调用后立即就绪，由 conformance C23 覆盖。

extensions 可选性同样成立：Android core 的 `api` / `core` / `security` / `transport` 四层**零** `android.*` / `androidx.*` 导入，全部 12 个含平台导入的文件均位于 `extensions/` 下。四端 core 均具备 extensions 层的 lifecycle 等价物（`LifecycleExtension`），语义对齐 Android 参考实现并由 C28–C30 锚定。

### 1.1 待修正：`allowedOrigins` 默认通配

`allowedOrigins` 默认值为 `["*"]`（`JsBridge.java + CoreBridge.java:55`、`.swift:13`），四端一致。Level 0 下 `AccessControlPolicy` 不装配，该默认值无实际效果；但**只调用 `withAccessControl()` 而不显式设置 `allowedOrigins` 时，origin 校验会静默放行所有来源**。

这是渐进增强的一个反直觉组合：升了级别，却没有获得预期的防护。建议在 §4.2 安全分级模型处补充警示，或让 `withAccessControl()` 在 `allowedOrigins` 仍为通配时拒绝构造。

---

## 2 平台无关性：core 层成立

四端 core 均无平台类型泄漏，实测结果：

| 平台 | 审计结论 |
|------|---------|
| iOS | `Sources/` 下 13 个文件仅 `import Foundation`（9 处），4 个文件零导入；无 `WebKit` / `UIKit` / `WKWebView` 任何出现；`Package.swift` 声明无依赖 |
| Flutter | `lib/` 全量导入仅 `dart:async` / `dart:math` / `dart:convert` + 相对导入，**零 `package:` 导入**；`pubspec.yaml` **无 `dependencies:` 块**，不依赖 flutter SDK 或 `webview_flutter` |
| HarmonyOS | `ets/` 下 8 个文件全部相对导入，无 `@ohos.*` / `@kit.*` / webview |
| Android | 平台类型全部收敛在 `extensions/`，四个内层为零 |

Flutter core 是纯 Dart 包这一点值得强调：它可在无 Flutter 环境下直接跑测试，验证了分层不是形式上的目录划分。

transport 抽象也都收敛到字符串边界，无平台类型出现在签名中：

| 平台 | 声明形式 |
|------|---------|
| Android | `interface BridgeTransport { bind(Listener) / send(String):boolean / close() }` |
| iOS | `protocol BridgeTransport: AnyObject`（同三方法） |
| Flutter | `typedef BridgeTransport = FutureOr<bool> Function(String)` |
| HarmonyOS | `type BridgeTransport = (messageJson: string) => boolean \| Promise<boolean>` |

---

## 3 与 Page 实现解耦：只做到一半

`TrustedPageContext` 本身是干净的数据类（四端均只含 `origin` + `pageInstanceId` 两个字符串字段），但它出现在 core 的对外契约中，且各端注入方式不一致。

### 3.1 origin 以裸字符串跨越信任边界（三端）

| 平台 | origin 来源 | 可信度 |
|------|-----------|-------|
| Android | `PageContextProvider` 接口，`AndroidWebViewPageContextProvider` 从 WebView 实例提取（`AndroidWebViewPageContextProvider.java:19-22`） | 内核派生，宿主不可伪造 |
| iOS | `processIncoming(messageJson:origin:)`（`.swift:130`），宿主逐条传字符串 | 宿主声明即事实 |
| Flutter | `processIncomingResponses({messageJson, origin})`（`.dart:158-161`） | 宿主声明即事实 |
| HarmonyOS | `processIncomingResponses(messageJson, origin)`（`.ets:178`），宿主传硬编码常量 `PAGE_ORIGIN = 'file://'`（`Index.ets:16`，调用处 `:230`） | 宿主声明即事实 |

**只有 Android 存在 `PageContextProvider` 抽象**，其余三端没有等价物。

后果：同一份 Level 2 配置，`AccessControlPolicy` 的 origin 白名单在 Android 上校验的是内核从 WebView 取得的真实 origin，在其余三端校验的是宿主自己填的字符串。**四端安全强度不等价**，与 Behavior-consistent 原则存在张力。

§3.2 "允许各端自定义"中写有"origin 来源各端自行派生，只要结果语义一致即可"，但硬编码常量派生不出真实 origin，语义并不一致。该条目需要收紧措辞，或明确标注三端的 origin 可信度依赖宿主自律。

### 3.2 TrustedPageContext 进入 handler 签名

四端业务 handler 的第一个参数均为 `TrustedPageContext`：

- HarmonyOS：`BridgeHandler = (context: TrustedPageContext, payload) => ...`（`.ets:18`）
- iOS：`NativeRequestHandler = (TrustedPageContext, JSONValue?) throws -> ...`（`.swift:3`）
- Flutter / Android 同构

即**每个业务 handler 都被迫感知 Page 概念**，即便它只关心 payload。若要彻底解耦，该上下文应当是可选入参而非强制。

### 3.3 `bindPage()` 的命名把页面模型固化进内核

`bindPage()` 的实际语义是"轮换页面实例 ID 并使旧会话失效"（`JsBridge.java + CoreBridge.java:191-205`）——它绑定的是**会话代次**，不是 Page。名字把 WebView 页面模型带进了平台无关的 core 层。

---

## 4 跨端 API 形态差异

协议一致不等于 API 一致，但以下差异已影响可迁移性与文档可读性。

| 维度 | Android | iOS | Flutter | HarmonyOS |
|------|---------|-----|---------|-----------|
| 安全配置载体 | `SecurityConfig` 内部类 | `SecurityConfig` struct | **无此类型**，8 个参数摊平在构造函数（`.dart:58-68`） | `JsBridgeOptions` interface |
| 上下文注入 | `PageContextProvider` 接口 | 无，传 String | 无，传 String | 无，传 String |
| 分级 API | `withHandshakeGate()` / `withAccessControl()` / `secure()` | 同 Android | 仅 `.secure()` 工厂 + 两个 bool 参数 | 仅 `secure()` 静态工厂 + 两个可选字段 |
| 错误码常量 | 内联字面量 | 内联字面量 | 内联字面量 | 内联字面量 |

Flutter 把安全配置摊平进构造函数，导致"Level 0/1/2"心智模型在该端**没有对应的类型载体**——[02-architecture.md §4.2](02-architecture.md) 用 `new SecurityConfig()` 描述分级，Flutter 读者找不到该类型。

### 4.1 错误码缺少单一事实源（优先修复项）

错误码基线是 [§3.1](03-cross-platform.md#31-必须跨端统一的内容) 明确要求跨端统一的协议内容，但**四端全部使用内联字符串字面量**：

- Android：`new BridgeError("E_POLICY_DENY", ...)`
- iOS：`RequestShapePolicy.swift:8,11`、`AccessControlPolicy.swift:17,20,26,29,32` 等
- Flutter：`policy_engine.dart:49,67,91,102,110,117,123` 等
- HarmonyOS：`PolicyEngine.ets:54,65,86,90,95,98,101,104` 等

`BridgeApiContract` 只固化了方法名（`METHOD_HANDSHAKE` / `METHOD_LIFECYCLE`），未固化错误码。**协议中最需要防漂移的一组常量，恰恰没有单一事实源**——一个 typo 即造成跨端行为不一致，且 conformance 未必能捕获（用例本身也可能复制同一个 typo）。

---

## 5 改进建议（按性价比排序）

| 优先级 | 项 | 说明 | 是否破坏性 | v1 处置 |
|-------|----|------|-----------|--------|
| P0 | 错误码收进 `BridgeApiContract` | 四端各建一份常量，替换全部内联字面量。改动小、风险低，直接堵住协议漂移 | 否 | **已修复** |
| P1 | 补齐 iOS / Flutter / HM 的 `PageContextProvider` 等价抽象 | 让 origin 由内核派生。若短期不做，须在 §3.2 显式声明三端 origin 可信度依赖宿主自律，不使 Level 2 看起来四端等强 | 否（新增可选注入点） | **已修复**（四端均提供 provider，示例改用内核派生路径；§3.2 已声明宿主声明路径的自律边界） |
| P1 | `allowedOrigins` 通配警示 | 在 §4.2 补充说明，或让 `withAccessControl()` 校验 | 否 | **已修复**（构造期拒绝通配 + §4.2 警示） |
| P2 | Flutter 引入 `SecurityConfig` 类型 | 与其余三端对齐，让分级模型有载体 | 否（可保留旧构造函数） | **已修复**（引入 `SecurityConfig`，旧摊平构造函数移除） |
| P3 | `bindPage()` 改名、handler 的 `TrustedPageContext` 改为可选 | 彻底兑现"与 Page 无关"，原与 Additive evolution 冲突建议留到 v2；v1 不考虑 API 兼容，已落地 | **是** | **已修复**（`resetForNewPage()` + handler 默认 payload-only，`registerHandlerWithContext` 为可选上下文路径） |
| P4 | iOS / Flutter / HM 缺少入站 transport 闭环 | Android 有 `AndroidWebViewBridgeTransport` + `resetTransport()` 完成双向闭环，其余三端 transport 仅出站，消费者须手写 50+ 行管道代码（bootstrap script、消息路由、`evaluateJavaScript`）。新增 `WKWebViewBridgeTransport`（iOS）+ `JsBridge.bindTransport()`（iOS/Flutter/HM），消费者代码降至 ~4 行 | 否（新增 API） | **已修复**（iOS 新增 `BridgeSystem` target 含 `WKWebViewBridgeTransport`；四端 `JsBridge` 新增 `bindTransport()`） |

P3 原与 Additive evolution 原则冲突，v1 在"不考虑 API 兼容"前提下已实施；P4 为后续补充，均不破坏现有 API。本文记录的设计债已清偿。
