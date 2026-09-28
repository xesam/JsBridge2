# 01 设计原则与验证

> 更新日期：2026-09  
> 适用平台：Android · iOS · Flutter · HarmonyOS

本文档说明 JsBridge2 的核心设计原则及其在实际架构中的体现。

---

## 1. 五条设计原则

原则正本为 [04-cross-platform.md §1.2](04-cross-platform.md#12-五条设计原则)（Protocol-first / 行为一致 / 分层内核 / 累加演进 / 渐进增强），命名与排序以该节为准，本文不复述清单。各原则在架构中的实际体现见下文各节；本文历史叙述中曾出现的「平台无关」「与 Page 实现解耦」等措辞，分别对应正本「分层内核」（core 层零平台导入）与 Layer 3 scope 能力面，不构成独立原则。

---

## 2. 渐进增强的实际体现

> 本章代码块的角色是**论证证据**——以四端真实 API 形态证明渐进增强落到实处，不是集成教程；完整的集成步骤与可拷贝代码见各平台项目 README（[README.md](README.md)"快速开始"）。

### 2.1 基础 API：二态安全配置

四端 `securityConfig` 参数二选一，没有中间态——`null`（无安全检查）或完整 `SecurityConfig`（握手 + 访问控制）：

```java
// Android
JsBridge bridge = new JsBridge(transport, provider, null);               // 无安全检查
JsBridge secure = new JsBridge(transport, provider,
        new SecurityConfig().allowedOrigins(...).methodWhitelist(...));     // 完整安全配置
```

> Android 端 `SecurityConfig` 为嵌套类 `JsBridge.SecurityConfig`（本文其余示例简写为 `SecurityConfig`，下同）。

```swift
// iOS
let bridge = JsBridge(securityConfig: nil, ...)               // 无安全检查
let secure = JsBridge(securityConfig: config, ...)            // 完整安全配置
```

```dart
// Flutter
final bridge = JsBridge(securityConfig: null);                // 无安全检查
final secure = JsBridge(securityConfig: config);              // 完整安全配置
```

```typescript
// HarmonyOS
const bridge = new JsBridge({ securityConfig: null, ... });   // 无安全检查
const secure = new JsBridge({ securityConfig: config, ... }); // 完整安全配置
```

**配置内的两个白名单维度**（传入 `SecurityConfig` 时必填，不可为 `null`）：

| 字段 | 类型 | 作用 |
|------|------|------|
| `allowedOrigins` | Set\<String\> | origin 白名单；`{"*"}` 显式表示不限制（`OriginPolicy` 不进链） |
| `methodWhitelist` | Set\<String\> | 业务方法白名单；协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架装配期自动并入放行集，无需显式列入；`{"*"}` 显式表示不限制（`MethodGatePolicy` 不进链） |

> 缺配在构造期报错而非静默降级：传入 `SecurityConfig` 却漏配任一字段，四端均在构造期抛错——"忘记配置"没有存活的路径。

### 2.2 策略链装配规则

所有安全策略按条件装配，不使用时不进链（行序即固定求值顺序，另见 [04-cross-platform.md §3.1](04-cross-platform.md)）：

| 策略 | 装配条件 | 职责 |
|------|---------|------|
| `RequestShapePolicy` | 无条件加入 | 验证消息格式 |
| `HandshakeGatePolicy` | `SecurityConfig` 非 null | 握手门控 |
| `OriginPolicy` | `allowedOrigins` 非含 `*` 集合 | origin 白名单 |
| `MethodGatePolicy` | `methodWhitelist` 非含 `*` 集合 | 业务方法白名单（协议方法自动并入放行集） |
| `SessionPolicy` | `SecurityConfig` 非 null | 会话校验 |
| `extraPolicies` | 宿主传入 | 自定义策略追加末尾 |

### 2.3 就绪标志一致性

`securityConfig == null` 时，`resetPageInstance()` 调用后立即就绪（四端一致）。该方法语义固定为两步，四端实现语义对齐：

1. 生成新的 `pageInstanceId`（轮换页面实例）；
2. 就绪标志按配置二态解析——`null` 配置直接置 ready；非 `null` 配置保持未就绪，等待 `bridge.handshake`。

由 conformance C23（JS 客户端裸用 null 配置、无需握手即可收发——[09-conformance.md §3](09-conformance.md) 登记）覆盖其端到端表现；Native 侧缺省值解析路径另由 C38 锚定。

### 2.4 推荐配置模式

以下是常见场景的配置组合，供参考。用户可在自己的代码库中封装这些配置为便利方法。

**开发模式**（本地调试，信任页面）：`securityConfig` 传 `null`
- 不需要握手，页面加载后立即可用
- 无访问控制
- 适用于离线包、受控模板、本地开发

**生产模式**（远程页面，严格校验）：传入完整 `SecurityConfig`，两个维度均配置具体值——`allowedOrigins` 传宿主允许的 origin 集合，`methodWhitelist` 传宿主开放的业务方法集合
- 需要握手，握手成功后才能调用方法
- 显式白名单限制 origin 和方法
- 适用于远程 H5、第三方页面

**混合模式**（需要握手，但不限制来源）：传入 `SecurityConfig`，两个维度均显式传 `{"*"}` 集合
- 需要握手建立会话
- 显式声明不限制 origin 和方法（`{"*"}` 而非缺配）
- 适用于信任页面但需要会话隔离的场景

### 2.5 安全分级（Level 0 / 1 / 2，正本定义）

根 README 与 CONTRIBUTING 使用 Level 0/1/2 词汇指代安全强度分级，其正本定义在此——与 §2.1 二态配置、§2.4 推荐配置模式一一对应；各级别的策略链组成由 C46 断言（安全配置改变策略链组成）：

| Level | 配置形态 | 策略链组成 | 对应推荐模式 | 适用 |
|-------|---------|-----------|--------------|------|
| **Level 0** | `securityConfig = null` | 仅 `RequestShapePolicy` | 开发模式 | 可信本地页面、离线包、单元测试 |
| **Level 1** | `SecurityConfig` + 两维度均为 `{"*"}` | `RequestShape` + `HandshakeGate` + `Session`（Origin / MethodGate 不进链；可选 extraPolicies） | 混合模式 | 需要会话隔离但不限制来源/方法 |
| **Level 2** | `SecurityConfig` + 具体白名单值 | 五策略全链（可选 extraPolicies） | 生产模式 | 远程 H5、第三方页面 |

> 三级之间的差异即 C46 断言的「配置决定链路成员」：Level 间迁移只增删链成员，不改变固定求值顺序（§2.2）。

---

## 3. 平台无关性验证

### 3.1 导入审计结果

四端 core 层均无平台类型泄漏：

| 平台 | 审计结论 |
|------|---------|
| Android | `api/core/security/transport` 四层零 `android.*` / `androidx.*` 导入（平台导入仅存在于 `extensions`——`system` / `registry` 子模块均含） |
| iOS | 17 个源文件：15 个仅 `import Foundation`，其余零 import——零 `WebKit` / `UIKit` 出现 |
| Flutter | core 为纯 Dart 包，唯一外部导入为纯 Dart 注解包 `meta`（`@visibleForTesting` 等），零 Flutter 依赖，可在无 Flutter 环境下跑测试 |
| HarmonyOS | 12 个文件全部相对导入，零 `@ohos.*` / `@kit.*` |

> 文件数量为 2026-09 审计时点值，随重构自然增减；审计结论项（零平台导入）以每次审计实际复核为准，不因文件数变化而失效。

### 3.2 Transport 抽象边界

传输抽象收敛到字符串边界，签名中无平台类型：

```java
// Android
interface BridgeTransport {
    void bind(Listener listener);
    boolean send(String messageJson);
    void close();
}
```

```swift
// iOS
protocol BridgeTransport: AnyObject {
    func bind(listener: @escaping (String) -> Void)
    func send(_ messageJson: String) -> Bool
    func close()
}
```

```dart
// Flutter
typedef BridgeTransport = FutureOr<bool> Function(String messageJson);
```

```typescript
// HarmonyOS
type BridgeTransport = (messageJson: string) => boolean | Promise<boolean>;
```

---

## 4. 关键设计决策

### 4.1 信道建立：为什么采用 pull 模型

**背景问题**  
旧 push 模型（Native 在 `onPageFinished` 一次性投递 `bridge:init` + port）存在竞态：
- Native 投递 `bridge:init` 是一次性边沿事件
- JS 侧在 `createNativeTransport()` 执行时才挂载 `message` 监听
- 若投递早于监听挂载 → 端口永久丢失 → 页面方无检测无恢复

**pull 模型方案**  
JS 主动请求 → Native 响应投递，建立因果链：

```
JS 挂监听（message listener）→causes→ JS 发起 requestBridgeChannel(reqId)
                                  →causes→ Native 建通道并投递 bridge:channel
```

**核心收益**  
竞态从"跨进程时序约定"降级为"JS 单线程内语句顺序保证"，可单测断言。

详见 [06-channel-establishment.md](06-channel-establishment.md)（pull 模型与 reqId 相关性）。

### 4.2 生命周期：为什么分三层

**背景问题**  
SPA 应用中：
- 路由切换（`/dashboard` → `/settings`）不触发页面加载
- JS 上下文不销毁，session 不应失效
- 但旧逻辑页面的待处理回调和事件监听器需要清理

**三层模型方案**  

```
Layer 1: Native 能力（WebView 生命周期）
  ↓ 绑定方法注册表、安全配置
Layer 2: Session（页面加载生命周期）
  ↓ 绑定 sessionId、origin
Layer 3: Scope（逻辑页面生命周期）
  ↓ 绑定待处理回调、事件监听器
```

| 场景 | Session : Scope | Scope 管理方式 |
|------|----------------|--------------|
| 传统网页 | 1 : 1 | 天然（JS 上下文销毁） |
| SPA | 1 : N | 显式（AbortSignal） |

**使用方关注点**  
仅需在逻辑页面销毁时传入 `AbortSignal`：

```typescript
const controller = new AbortController();

// 请求绑定 scope
bridge.callNativeApi('getUserInfo', payload, {
  signal: controller.signal  // 页面销毁时自动取消
});

// 事件监听器绑定 scope
bridge.registerEventHandler('userUpdate', handler, controller.signal);

// 页面销毁时
controller.abort();  // 所有关联回调被拒绝（E_CANCELED），监听器被注销
```

详见 [05-lifecycle-layers.md](05-lifecycle-layers.md)。

### 4.3 错误码：单一事实源

协议错误码定义在 `BridgeApiContract`，四端统一引用常量（不使用内联字符串字面量）：

```java
// Android: BridgeApiContract.java（常量命名各端风格不同：Android/HarmonyOS 为 ERR_*，
// iOS/Flutter 为 errorXxx；值为统一的 E_*）
public static final String ERR_INVALID_MESSAGE = "E_INVALID_MESSAGE";
public static final String ERR_NOT_READY = "E_NOT_READY";
public static final String ERR_SESSION_INVALID = "E_SESSION_INVALID";
// ...

// 策略链中引用（iOS 对应写法为 BridgeApiContract.errorNotReady，Flutter/HarmonyOS 同理）
return new BridgeError(BridgeApiContract.ERR_NOT_READY, "Bridge not ready");
```

防止 typo 导致的跨端行为不一致。

### 4.4 PageContextProvider：安全强度对齐

四端均提供 `PageContextProvider` 接口，让 origin 由内核从 WebView 派生：

```java
// Android：三参构造（transport, provider, securityConfig）
PageContextProvider provider = new AndroidWebViewPageContextProvider(webView);
JsBridge bridge = new JsBridge(transport, provider, null);
```

```swift
// iOS：宿主实现 PageContextProvider 协议（示例实现 WebViewPageContextProvider 见 js_bridge_ios/README.md）
let bridge = JsBridge(securityConfig: config,
                      pageContextProvider: WebViewPageContextProvider(webView: webView),
                      transport: transport)
```

**可信度**：

| 方式 | origin 来源 | 可信度 |
|------|-----------|-------|
| Provider（四端生产路径） | 内核从 WebView 提取 | 内核派生，宿主不可伪造 |
| 宿主直传 origin 字符串 | — | 不存在该生产形态：四端生产入站路径一律经 Provider 派生 origin。带 origin/context 形参的入口仅为测试注入面——iOS（`processIncoming(messageJson:origin:)` 等）与 Flutter（`processIncomingResponsesWithOrigin`）由 `internal` / `@visibleForTesting` 限定访问；HarmonyOS 的同类入口（`processIncomingResponses(messageJson, origin)` / `processIncomingResponsesForContext(messageJson, context)`）以 public 形态存在（`Index.ets` 导出整个 `JsBridge` 类），但仅供测试注入使用，生产宿主仍走 `bindTransport()` 闭环（信任边界见 [03-protocol.md §9 细则 5](03-protocol.md)） |

传入 `SecurityConfig` 时，四端使用 Provider 路径可获得等强的 origin 校验。

---

## 5. 使用方关注要点

### 5.1 默认够用的场景

- **离线包 + 模板受控**：HTML 模板由宿主控制，SDK script 同步加载
- **`securityConfig == null`**：页面重置后立即可用，无会话校验
- **单模块应用**：一个页面只初始化一次 bridge

这些场景下使用默认配置即可，无需额外机制。

### 5.2 需要显式配置的场景

**SPA 应用**  
逻辑页面销毁时传入 `AbortSignal`（详见 §4.2）。

**需要严格安全控制的场景**  
传入完整 `SecurityConfig`（两个白名单字段必填）：

```java
JsBridge bridge = new JsBridge(
    transport, provider,
    new SecurityConfig()
        .allowedOrigins(new HashSet<>(Arrays.asList("https://example.com")))
        .methodWhitelist(new HashSet<>(Arrays.asList("getUserInfo", "upload")))
);
```

**异步加载 SDK**  
使用官方 `getBridge()` 装载器（单例防重、按需注入 SDK、建立信道、完成握手）：

```javascript
// 官方装载器（推荐）；BridgeReadyResult 结构正本见 sdk README
const { client } = await getBridge();  // client = 已握手的 JsBridgeClient
```

手动编排（`createNativeTransport` / `createJsBridgeClient` / `createReadyExtension` / `registerWebEntry`）与装载选项（`handshakeTimeoutMs` / `channelTimeoutMs` 等）见 [web-assets/packages/sdk/README.md](../web-assets/packages/sdk/README.md)。

---

## 6. 验收断言

设计原则的落地情况由 conformance 用例覆盖：

| 原则 | 覆盖用例 |
|------|---------|
| 渐进增强 | C23（JS 客户端裸用 null 配置无需握手）、C28–C30（lifecycle 语义对齐） |
| 行为一致 | 全员已登记用例（C01–C65，编号正本见 [09-conformance.md §3](09-conformance.md)）四端等价 |
| 平台无关 | 四端 core 导入审计（§3.1） |
| 分层清晰 | C64（Tier-1 standalone：绕过 security/extensions 的内核分发形态） |
| Page 解耦 | C24–C27（AbortSignal scope 管理） |

> 本表左列为历史简称，原则命名与排序以 [04 §1.2](04-cross-platform.md#12-五条设计原则) 正本为准（见 §1 说明）；「Page 解耦」一行覆盖的是 Layer 3 scope 能力面，非独立原则。

详见 [09-conformance.md](09-conformance.md)。

---

## 7. 与其他文档的关系

- **协议定义**：[03-protocol.md](03-protocol.md) — 消息格式、会话模型、错误码
- **架构说明**：[02-architecture.md](02-architecture.md) — 分层结构、策略链、安全配置
- **跨平台契约**：[04-cross-platform.md](04-cross-platform.md) — 四端必须对齐的内容
- **生命周期模型**：[05-lifecycle-layers.md](05-lifecycle-layers.md) — 三层模型详细说明
- **信道建立机制**：[06-channel-establishment.md](06-channel-establishment.md) — pull 模型与 reqId 往返
