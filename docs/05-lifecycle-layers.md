# 05 生命周期三层模型

> 更新日期：2026-09  
> 适用平台：Android · iOS · Flutter · HarmonyOS

---

## 0. 使用方关注要点

### 0.1 什么时候需要关心这份文档

**传统多页应用（默认场景）**  
无需关心本文档。页面导航时 JS 上下文销毁，三层自动清理。

**SPA 单页应用**  
需要在逻辑页面销毁时传入 `AbortSignal`：

```typescript
// React 示例（bridge 为 CoreBridgeClient 层实例；registerEventHandler 属
// CoreBridgeClient，不在会话门控封装 createJsBridgeClient 的公开面上）
function DashboardPage() {
  const [controller] = useState(() => new AbortController());
  
  useEffect(() => {
    // 请求绑定 scope（signal 是 CallOptions 的属性，作为第二实参传入）
    bridge.callNativeApi('loadData', { signal: controller.signal });
    
    // 事件监听器绑定 scope（第三形参即 signal）
    bridge.registerEventHandler('dataUpdate', handler, controller.signal);
    
    // 页面卸载时自动清理
    return () => controller.abort();
  }, []);
}
```

### 0.2 症状自查

| 症状 | 可能原因 | 是否需要 Scope 管理 |
|------|---------|-------------------|
| 路由切换后旧页面回调仍在执行 | SPA 未销毁 scope | ✅ 是 |
| 旧页面的事件监听器触发报错（DOM 已销毁） | SPA 未注销监听器 | ✅ 是 |
| 页面刷新后握手失败 | session 轮换问题 | ❌ 否（见 Layer 2） |
| 不同 URL 导航后请求失败 | 信道重建问题 | ❌ 否（见 Layer 1） |

---

## 1 问题背景

WebView 中的页面有两种形态，两者的 URL 变化所代表的意义完全不同：

| | 传统多页网页 | SPA（单页应用） |
|---|---|---|
| **URL 变化方式** | 浏览器级导航（`location.href`、链接点击） | `history.pushState` / `replaceState` / `hashchange` |
| **JS 执行上下文** | **销毁并重建**——变量、闭包、事件监听全部消失 | **完全保留**——同一个 JS runtime |
| **WebView 原生回调** | 页面加载回调正常触发 | **不触发** |
| **Bridge 通道** | 被销毁，需重建 | 保持活跃 |
| **Session 语义** | 理应失效——JS 上下文已不存在 | 理应保留——JS 上下文未中断 |

当前的页面重置操作将"信道重建"和"会话轮换"捆绑在一起，在传统网页场景下两者总是同时发生（因为 JS 上下文销毁），所以没有问题。但在 SPA 场景下，逻辑页面切换时 JS 上下文不变，信道不需要重建、会话不需要轮换，却有一类状态需要清理——旧逻辑页面的待处理回调和事件监听器。

本文档定义一个三层生命周期模型，将 WebView 内的状态按生命周期粒度分层，明确各层的标识键、状态归属和管理方。

---

## 2 三层模型

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Native 能力                                             │
│  生命周期 = WebView                                               │
│  标识键: CoreBridge 实例                                        │
│  状态: 方法注册表, 安全配置                                       │
│  管理方: Native                                                   │
│  跨三场景: 全程持久                                                │
├──────────────────────────────────────────────────────────────────┤
│  Layer 2: Session                                                 │
│  生命周期 = WebView × 一次页面加载                                │
│  标识键: 页面实例标识 + origin                                    │
│  状态: 会话 ID, 能力集, 过期时间                                   │
│  管理方: Native                                                   │
│  场景①: 每次导航 → 轮换页面实例标识 → 旧 session 失效             │
│  场景②: 初始加载 → 一个 session，持续整个 SPA                     │
│  场景③: 不触发轮换 → session 持续有效                             │
├──────────────────────────────────────────────────────────────────┤
│  Layer 3: Scope                                                   │
│  生命周期 = WebView × 一个逻辑页面                                │
│  标识键: scopeId（协议字段）+ AbortSignal（JS 侧生命周期管理）✅    │
│  状态: 待处理回调, 事件监听器                                      │
│  管理方: JS                                                       │
│  场景①: JS 上下文销毁 → 天然清理（scope ≡ session，1:1）         │
│  场景②: 首个 Page 的 scope，随 Page 建立                          │
│  场景③: 旧 Page scope 需显式销毁，新 Page scope 独立建立 (1:N)   │
└──────────────────────────────────────────────────────────────────┘
```

> 注：Layer 3 的 `scopeId` 为协议预留字段，JS 侧当前未实现发送与消费（见 [03-protocol.md §7.3](03-protocol.md) 与下文 §7）；实际生效的 Scope 管理键是 `AbortSignal`。

### 各层定义

**Layer 1 — Native 能力（WebView 层面）**

Bridge 核心实例（`CoreBridge`）及其管理的方法注册表和安全配置。这些状态绑定到 WebView 实例，跨所有页面加载和 SPA 路由切换持久存在。页面重置操作不触碰方法注册表和安全配置。

**Layer 2 — Session（页面加载层面）**

通过握手建立的可信会话，绑定到 origin 与页面实例标识。页面实例标识在每次页面加载（WebView 原生回调触发）时轮换。Session 的生命周期对应"一次页面加载"——传统网页每次 URL 导航都是一次加载，SPA 只有初始加载算一次。

> **精化**：Session 绑定的不是 URL 字符串本身，而是**一次页面加载事件**。同一个 URL 刷新一次会生成新的页面实例标识，得到新的 session。概念上"WebView + URL"表示的是"在这个 WebView 中加载该 URL 的这一次事件"。

**Layer 3 — Scope（逻辑页面层面）**

一个逻辑页面内的待处理请求回调和事件监听器。当逻辑页面销毁时，这些回调应被拒绝（`E_CANCELED`），监听器应被注销。Scope 是三层中粒度最细的——在 SPA 中，一个 session 生命周期内可以有多个 scope 交替存在。

---

## 3 三种场景下的层次变化

### 场景 ①：同一 WebView 加载不同普通 URL

```
WebView 加载 https://a.com/page1 → 导航到 https://b.com/page2

  WebView ──────────────────────────────────────────── 持久
  Session ──── a.com / 实例-A ──×── b.com / 实例-B ────
  Scope   ──── [Page 1] ────×── [Page 2] ────
                                ↑ 页面加载回调触发 → 页面重置
                                  JS 上下文销毁 → scope 天然清理
                                  信道重建 → session 轮换
```

三件事同时发生：信道重建（Layer 1 的传输部分）、会话轮换（Layer 2）、scope 清理（Layer 3，天然）。页面重置操作一步完成前两件，第三件由 JS 上下文销毁隐式完成。

### 场景 ②：同一 WebView 加载 SPA 应用 URL

```
WebView 加载 https://app.com/ → SPA 初始化

  WebView ──────────────────────────────────────────── 持久
  Session ──── app.com / 实例-C ────────────────────────────────────
  Scope   ──── [SPA Page 1: /dashboard] ────────────────────────────
```

页面加载回调触发一次 → 页面重置调用一次 → 一个 session 建立。SPA 的所有后续路由切换都在这个 session 生命周期内。

### 场景 ③：SPA 内部切换逻辑页面

```
SPA 路由 /dashboard → /settings（pushState）

  WebView ──────────────────────────────────────────── 持久
  Session ──── app.com / 实例-C ──────────────────────────────────── 持续
  Scope   ──── [/dashboard] ──×── [/settings] ────
                             ↑ 需要 scope 销毁
                               不触发页面加载回调
                               不调用页面重置
                               JS 上下文不变
                               信道 / session 不动
```

只有 Layer 3 发生变化：旧页面的 scope 需要显式清理，新页面建立独立 scope。Layer 1 和 Layer 2 不受影响。

---

## 4 Session 与 Scope 的基数关系

| | 普通网页 | SPA |
|---|---|---|
| Session : Scope | **1 : 1** | **1 : N** |
| 原因 | 一次加载 = 一个页面 = 一个 JS 上下文 | 一次加载 = 整个 SPA = N 个逻辑页面交替 |
| Scope 管理方式 | 天然（JS 上下文销毁） | 需显式（scope 销毁操作） |

在只有传统网页的场景下，session 和 scope 是同一件事——页面重置一刀切就够了。SPA 将两者拆开：session 仍 1:1 绑定页面加载，但 scope 变成 1:N，需要在 session 之内做更细粒度的管理。

---

## 5 各层的标识键与状态归属

### Layer 1: Native 能力

| 状态类别 | 归属 | 生命周期 |
|---------|------|---------|
| 方法注册表（method → handler） | Native | WebView 创建到销毁 |
| 安全配置（安全级别、origin 白名单、能力集等） | Native | 构造时确定，不可变 |

页面重置操作重建传输通道，但不触碰方法注册表和安全配置。

### Layer 2: Session

| 状态类别 | 归属 | 生命周期 |
|---------|------|---------|
| 页面实例标识 | Native | 每次页面重置时轮换 |
| origin（scheme + host + port） | Native | 每次页面加载时从 WebView 当前 URL 提取 |
| 会话记录（会话 ID、能力集、过期时间） | Native | 握手建立到失效（TTL / 轮换 / 销毁） |
| 就绪标志 | Native | securityConfig == null：页面重置后立即可用；传入 SecurityConfig：握手后可用 |

会话校验要求会话绑定的 origin 与页面实例标识均与当前请求上下文匹配。

### Layer 3: Scope

| 状态类别 | 归属 | 生命周期 |
|---------|------|---------|
| 待处理回调（请求 ID → 成功/失败回调） | JS | 请求发出到响应/超时/scope 销毁 |
| 事件监听器（方法名 → 处理函数） | JS | 注册到注销/scope 销毁 |
| 已完成请求幂等记录 | JS | 请求完成到 TTL 过期 |

这些状态的 scope 管理经由 JS 侧 `AbortSignal` 实现（见 §7「JS 侧生命周期管理」，验收锚点 C24–C27）：传入 signal 的待处理回调与事件监听器随逻辑页面销毁统一清理（`E_CANCELED` / 自动注销）；未传 signal 的请求则维持基线行为——待处理回调靠超时自然过期，事件监听器靠手动注销（渐进增强：不传 signal 行为不变）。

---

## 6 页面重置的关注点拆分

页面重置操作原先混合了两个不同层面的关注点：

| 关注点 | 所属层面 | 何时需要 | SPA 场景 |
|--------|---------|---------|---------|
| A. 信道重建 | Layer 1 传输 | JS 上下文销毁（真实导航） | 不需要 |
| B. 会话轮换 | Layer 2 | 信任边界变化（新页面加载） | 不需要 |

### 已实现的拆分

四端已将页面重置拆分为两个可独立调用的操作：

| 平台 | 信道重建 | 会话轮换 | 真实导航时的调用方式 |
|------|---------|---------|-------------------|
| Android | `resetTransport()` | `resetPageInstance()` | 先 `resetTransport()` 再 `resetPageInstance()` |
| iOS | 无需单独操作（`WKScriptMessageHandler` 不随页面销毁） | `resetPageInstance()` | 仅 `resetPageInstance()` |
| Flutter | 无需单独操作（传输为函数指针） | `resetPageInstance()` | 仅 `resetPageInstance()` |
| HarmonyOS | 无需单独操作（传输为函数指针） | `resetPageInstance()` | 仅 `resetPageInstance()` |

Android 的 `WebMessageChannel` 随页面销毁，需要 `resetTransport()` 重建。iOS / Flutter / HarmonyOS 的传输机制不随页面加载销毁，无需重建。拆分后 `resetPageInstance()` 仅做 Layer 2（会话轮换），四端行为一致。

---

## 7 Scope 管理

### 协议层支持（已实现）

四端已在协议层为 scope 提供基础设施：

- **消息信封新增可选字段 `scopeId`**（string，request 方向）：用于标识请求所属的逻辑页面 scope。遵循 v1 增量演进约定，旧版本忽略此字段。
- **保留方法 `bridge.cancelScope`**（JS → Native）：通知 Native 侧某个 scope 已销毁。当前 Native 实现为空壳 ack——返回 `{ scopeId, accepted: true }`，不执行实际取消逻辑。这是为未来 Native 侧 scope 感知预留的通道。

四端实现状态：

| 平台 | `scopeId` 字段 | `bridge.cancelScope` 方法 | 处理逻辑 |
|------|:---:|:---:|:---:|
| Android | 已实现 | 已实现 | ack 空壳 |
| iOS | 已实现 | 已实现 | ack 空壳 |
| Flutter | 已实现 | 已实现 | ack 空壳 |
| HarmonyOS | 已实现 | 已实现 | ack 空壳 |

> **JS 侧现状**：`bridge.cancelScope` 端到端当前不可用（详见 [03-protocol.md §7.3](03-protocol.md)），上表为 Native 侧预留状态；JS 侧 scope 管理由 `AbortSignal` 承担（见下节），不依赖这两个协议预留。

### JS 侧生命周期管理（已实现）

采用 Web 标准的 `AbortSignal`，不引入自定义 scope 概念。SPA 每个逻辑页面创建独立的 `AbortController`，页面内的 Bridge 调用和事件监听通过 `signal` 关联到该控制器。页面销毁时触发 abort，所有关联的待处理回调被拒绝（`E_CANCELED`），事件监听器被注销——不触碰信道、会话和就绪状态。

已实现的能力：

- `CallOptions.signal?: AbortSignal`——传入后，请求与该 signal 的生命周期绑定
- `registerEventHandler(method, handler, signal?)`——传入后，事件监听器与该 signal 的生命周期绑定
- signal abort 时：pending 请求被 reject（`E_CANCELED`），事件监听器被注销
- 预中止 signal（`signal.aborted === true`）：直接 reject，不发送请求
- 流式请求（`keep=true`）：abort 同样生效，后续帧被忽略
- 不传 signal 时：行为与之前完全一致（渐进增强）

Conformance 用例 C24–C27 覆盖以上行为。

### 方案选型回顾：自定义 scopeId vs AbortSignal（选型时点对比）

> 下表是**选型决策时点**（Scope 机制尚未入协议）的对比，用于解释为何 JS 侧选中 AbortSignal。选型完成后，协议层另行落地了 scope 基础设施预留（现状见上方注记）；AbortSignal（JS 侧管理机制）与 scopeId / cancelScope（协议预留通道）并非互斥关系。

| | 自定义 scopeId | AbortSignal |
|---|---|---|
| Web 标准 | 自造概念 | 浏览器原生 API |
| 协议影响 | 当时为零（后已作为预留字段落地） | 零——纯 JS 侧状态管理 |
| 框架集成 | 需适配各框架 | React `useEffect`、Vue `onUnmounted` 天然支持 |
| 渐进增强 | 需新协议字段 | 调用选项加一个可选参数 |
| 粒度 | scope 级（一页面一 scope） | 任意粒度 |
| 跨端一致性 | 需要四端同步实现 | 仅 JS 侧，Native 不感知 |

### Native 侧需要感知 scope 吗

**当前阶段：不需要。** `bridge.cancelScope` 的 Native 处理为空壳 ack。JS 侧 scope 销毁后，Native 侧的响应/事件会被 JS 侧自然丢弃（无匹配的待处理回调 → 丢弃，无匹配的事件监听器 → 忽略）。这是浪费但不是错误——大部分 Native 处理是毫秒级的。

**未来可选**：将 `bridge.cancelScope` 的 Native 处理从空壳 ack 升级为实际取消逻辑——终止 scope 内进行中的处理（特别是 `keep=true` 流式场景）。`bridge.cancelScope` 保留方法和 `scopeId` 字段已为此预留，升级时无需协议变更。

---

## 8 与现有文档的关系

| 文档 | 关联点 |
|------|--------|
| [03-protocol.md](03-protocol.md) §10 会话模型 | Session 的绑定与轮换语义以三层模型为概念基础；§10"绑定与轮换"区分真实导航与 SPA 路由跳转 |
| [02-architecture.md](02-architecture.md) §3 消息处理流程 | 页面重置的关键说明引用三层模型解释关注点拆分 |
| [04-cross-platform.md](04-cross-platform.md) §4.3 | 页面重置时机对比表补充 SPA 场景说明 |
| [09-conformance.md](09-conformance.md) | C18（页面重置后旧 session 失效）覆盖 Layer 2；Layer 3 的 JS 侧 scope 管理已由 C24–C27 覆盖（AbortSignal 三路径：待处理请求 / 流式请求 / 事件监听注销） |

本文档定义概念模型与设计方向。页面重置关注点拆分已在四端落地（§6），协议层 scope 基础设施已在四端落地（§7 协议层支持）。JS 侧 `AbortSignal` 生命周期管理已实现，conformance 用例 C24–C27 覆盖。
