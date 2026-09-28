# JsBridge Harmony

跨平台 JsBridge 协议的 HarmonyOS（鸿蒙）实现。

> 消息模型为纯异步（协议 v1 不支持同步调用，所有结果以独立 response/event 消息回传，详见 [docs/03-protocol.md §1 消息模型](../docs/03-protocol.md)）。ArkWeb `javaScriptProxy` 注入的函数为 `void postMessage` 形态，无同步返回。

## 模块

| 模块 | 说明 |
|------|------|
| `js-bridge-core` | HAR 核心库：CoreBridge、JsBridge、PolicyEngine、SessionService |
| `js-bridge-example` | 示例应用：完整的集成示例 |

## 快速开始

```bash
# 核心单元测试：HAR 的 src/test 不参与打包，须以副本接入 example 的 ohosTest
# 在真机/模拟器上经 hypium 执行——入口统一为根目录脚本（自动同步测试副本 →
# 构建 → 设备在线则安装运行，无设备时退化为编译验证）：
bash scripts/test_harmony.sh

# 示例 App：
cd js_bridge_harmony/js-bridge-example
# 在 DevEco Studio 中打开并运行
```

## 集成教程

> 内核分为两层，递进使用：
> - **CoreBridge**（Tier 1）— 纯消息分发，零安全依赖。适合可信本地页面、原型开发。
> - **JsBridge**（Tier 2）— 叠加在 CoreBridge 之上，增加握手、策略链、会话管理。适合生产环境。

### 1. 添加依赖

```json5
// oh-package.json5
{
  "dependencies": {
    "@xesam/js_bridge_core": "file:../../js-bridge-core"
  }
}
```

---

## 第一部分：CoreBridge

CoreBridge 是 Tier 1 核心协议层，只做三件事：注册 handler、分发消息、构建响应/事件。它不感知安全策略、会话、握手——这些全部由上层 JsBridge 负责。

### 1.1 创建 CoreBridge

CoreBridge 可不传 transport（后续通过 `attachTransport` 注入）：

```typescript
import { CoreBridge } from '@xesam/js_bridge_core';

const core = new CoreBridge();
```

### 1.2 注册 Handler

CoreBridge 只有两个注册入口：`registerSimpleHandler`（单帧响应）与 `registerAsyncHandler`（多帧响应）。
两者的 page context（`TrustedPageContext`）均为**第一形参**。Simple handler 恒为单帧（`done=true`），
多帧只能由 Async handler 通过 `ResponseEmitter` 表达。同一 method 重复注册时**后者覆盖前者**（单一注册表）。

```typescript
import { BridgeHandlerResult, BridgeError, ResponseEmitter, Result, TrustedPageContext } from '@xesam/js_bridge_core';

// ArkTS 禁止向 Object 类型形参传裸对象字面量（arkts-no-untyped-obj-literals），
// payload 须经由带构造器的类产生（demo 同款），或以 Record<string, Object> 显式过渡：
class UserPayload {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class TimerTickPayload {
  event: string = 'tick';
  value: number;
  seq: number;

  constructor(value: number, seq: number) {
    this.value = value;
    this.seq = seq;
  }
}

class TimerStoppedPayload {
  event: string = 'stopped';
  running: boolean = false;
}

// Simple handler：单帧响应，返回即结束（done 恒为 true）
core.registerSimpleHandler('getUser', (context: TrustedPageContext, payload: Object | null) => {
  const rawUserId = (payload as Record<string, Object>)?.['userId'];
  const userId = typeof rawUserId === 'string' ? rawUserId : undefined;
  if (userId === '001') {
    return BridgeHandlerResult.success(new UserPayload('xesam'));
  }
  return BridgeHandlerResult.failure(new BridgeError('E_NOT_FOUND', 'user not found'));
});

// Async handler：多帧响应，可返回后继续推帧（done=false 为非终帧，done=true 收尾）
core.registerAsyncHandler('timerLog', async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null) => {
  if (emitter === null) {
    return;
  }
  for (let i = 0; i < 3; i++) {
    await emitter(
      Result.success<Object, BridgeError>(new TimerTickPayload(Math.floor(Math.random() * 100), i + 1)),
      false
    );
  }
  await emitter(Result.success<Object, BridgeError>(new TimerStoppedPayload()), true);
});
```

### 1.3 主动推送事件

```typescript
// payload 同样不得为裸对象字面量——LifecycleExtension 内部即以 RuntimeStatePayload 推送 runtime.state
class RuntimeStatePayload {
  state: string;
  seq: number;

  constructor(state: string, seq: number) {
    this.state = state;
    this.seq = seq;
  }
}

// 向 JS 侧推送事件（kind=event），无需等待请求
await core.postEvent('runtime.state', new RuntimeStatePayload('foreground', 1));
```

### 1.4 消息分发

CoreBridge 的 `dispatch` 接收 `BridgeMessage` + `TrustedPageContext`，返回响应 JSON 字符串数组：

```typescript
import { BridgeMessage, TrustedPageContext } from '@xesam/js_bridge_core';

const request = BridgeMessage.fromJsonString(messageJson);
const context = new TrustedPageContext('file://', 'page-1');
const responses = await core.dispatch(request, context);
for (const response of responses) {
  sendToWeb(response);
}
```

### 1.5 独立使用场景

当页面完全可信（如本地 `file://` 页面）、无需安全校验时，CoreBridge 可独立使用。只需自行接收 JS 消息并调用 `dispatch`：

```typescript
const core = new CoreBridge();
core.registerSimpleHandler('getUser', (context: TrustedPageContext, payload: Object | null) => {
  const user: Record<string, Object> = { 'name': 'xesam' };
  return BridgeHandlerResult.success(user);
});

// 绑定 transport
core.attachTransport((messageJson: string): boolean => sendToWeb(messageJson));

// 手动分发
async function handleMessageFromWeb(messageJson: string): Promise<void> {
  const request = BridgeMessage.fromJsonString(messageJson);
  const context = new TrustedPageContext('file://', 'page-1');
  const responses = await core.dispatch(request, context);
  for (const response of responses) {
    sendToWeb(response);
  }
}
```

> **上下文**：HarmonyOS 无 `bind()` 自动闭环形态（该形态为 Android 特有）：standalone 使用时经构造期注入（或 `attachTransport`）出站、手动调用 `dispatch`，`TrustedPageContext` 由宿主手工构造——该 origin 为**宿主自声明**（须为归一化形态，见 [docs/03-protocol.md §9 细则 5](../docs/03-protocol.md)），不是内核经 Provider 派生的可信值，信任边界不高于 null 配置（见 [docs/04-cross-platform.md §3.1](../docs/04-cross-platform.md)）；页面非完全可信时请使用 Tier 2 JsBridge。

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截消息入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全模式

`securityConfig` 参数二选一，没有中间态：

| 配置 | 行为 |
|------|------|
| `null` | 无安全检查：仅校验消息结构，无需握手 |
| `SecurityConfig` | 握手门控 + session 校验；`allowedOrigins` / `methodWhitelist` 决定两个白名单维度是否进链（`Set(['*'])` = 显式不限制）；`methodWhitelist` 为业务方法白名单，协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架自动放行 |

> **配置校验**：传入 `SecurityConfig` 时 `allowedOrigins` 与 `methodWhitelist` 必须显式设置（不可为 `null`），否则构造期抛错；`Set(['*'])` 是合法的"不限制该维度"声明。`methodWhitelist` 只需列出**业务方法**——协议方法由框架装配期自动并入放行集，无需显式写入 `bridge.handshake`。

### 2.2 创建 JsBridge

需要自行实现 `PageContextProvider`。**origin 必须经由核心库导出的 `OriginNormalizer.normalize(...)` 产生**（协议契约见 [docs/03-protocol.md §9 细则 5](../docs/03-protocol.md)：`TrustedPageContext.origin` 的唯一合法形态由内核的四端统一手写归一化算法产生，宿主不得自写归一化，验收锚点 C54）：

```typescript
import { JsBridge, SecurityConfig, TrustedPageContext, PageContextProvider, OriginNormalizer, BridgeMessage } from '@xesam/js_bridge_core';

const PAGE_ORIGIN = 'file://';

// 实现 PageContextProvider
class FilePageContextProvider implements PageContextProvider {
  createContext(message: BridgeMessage, pageInstanceId: string): TrustedPageContext {
    // origin 必须经核心层归一化产生（docs/03 §9 细则 5，验收锚点 C54）
    return new TrustedPageContext(OriginNormalizer.normalize(PAGE_ORIGIN), pageInstanceId);
  }
}

// 无安全配置 — 开发环境（无握手，无来源校验）
const bridge = new JsBridge({
  securityConfig: null,
  transport: (messageJson: string): boolean => sendToWeb(messageJson),
  pageContextProvider: new FilePageContextProvider(),
});

// 传入 SecurityConfig — 生产环境（握手 + 来源白名单 + 方法白名单）
const secureBridge = new JsBridge({
  securityConfig: {
    allowedOrigins: new Set<string>([PAGE_ORIGIN]),
    methodWhitelist: new Set<string>([
      'getUser',
      'getCurrentLocation',
    ]),
  },
  transport: (messageJson: string): boolean => sendToWeb(messageJson),
  pageContextProvider: new FilePageContextProvider(),
});
```

> URL 缺失 / scheme 词法非法 / 非层级形态（`about:` / `data:` 等）/ 畸形端口，归一化一律返回空串 `""`（例：`about:blank` → `""`）——空串 origin 永远不会命中任何白名单，fail-closed。因此**不要**在 `allowedOrigins` 中写 `"about:blank"` 之类的死条目，也不要用占位值替代真实 origin。

### 2.3 配置 Web 组件

HarmonyOS 使用 `javaScriptProxy` 与 WebView 进行通信。消息从 JS 到达后，通过 `bindTransport()` 返回的回调自动进入 JsBridge 处理（策略链 → 握手/会话 → 委托 CoreBridge.dispatch → 响应自动发回）：

```typescript
import { webview } from '@kit.ArkWeb';

// struct 成员声明（ArkTS：以下均为 struct 内字段初始化，完整代码见 js-bridge-example 的 Index.ets）：
private controller: webview.WebviewController = new webview.WebviewController();
private bridge: JsBridge = this.createBridge();          // 构造见 §2.2（transport 经 JsBridgeOptions 构造期注入）
private onIncoming: (messageJson: string) => Promise<void> = this.bridge.bindTransport();
private nativeBridge: NativeBridgeProxy = new NativeBridgeProxy((messageJson: string): void => {
  void this.onIncoming(messageJson);
});

// 组件 build() 内挂 javaScriptProxy（bindTransport() 返回的入站回调经 proxy 自动进入 JsBridge：
// 策略链 → 握手/会话 → 委托 CoreBridge.dispatch → 响应自动发回）
Web({ src: $rawfile('web/index.html'), controller: this.controller })
  .javaScriptProxy({
    object: this.nativeBridge,
    name: 'NativeBridge',
    methodList: ['postMessage'],
    controller: this.controller
  })
  .onPageBegin(() => {
    this.bridge.resetPageInstance();
  })
```

`bindTransport()` 返回的回调内部自动串联内核的入站处理（解析 → 策略链 → 分发）→ `sendViaTransport` 闭环，无需手动处理消息路由和响应发送。

> 出站发送仍需在构造时通过 `transport` 参数注入：
> ```typescript
> transport: (messageJson: string): boolean => this.sendToWeb(messageJson),
> ```

### 2.4 注册 Handler

JsBridge 委托 CoreBridge 注册 handler，注册入口与形参形态完全一致（page context 为第一形参）；
同一 method 重复注册时后者覆盖前者。

```typescript
import { BridgeHandlerResult, ResponseEmitter, Result, BridgeError, TrustedPageContext } from '@xesam/js_bridge_core';

// payload 不得为裸对象字面量（ArkTS 限制，见 §1.2），
// UserPayload / TimerTickPayload / TimerStoppedPayload 的类定义同 §1.2

// Simple handler（委托 CoreBridge）：单帧响应
bridge.registerSimpleHandler('getUser', (context: TrustedPageContext, payload: Object | null) => {
  return BridgeHandlerResult.success(new UserPayload('xesam'));
});

// Async handler：多帧响应
bridge.registerAsyncHandler('timerLog', async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null) => {
  if (emitter === null) {
    return;
  }
  for (let i = 0; i < 3; i++) {
    await emitter(
      Result.success<Object, BridgeError>(new TimerTickPayload(Math.floor(Math.random() * 100), i + 1)),
      false
    );
  }
  await emitter(Result.success<Object, BridgeError>(new TimerStoppedPayload()), true);
});
```

### 2.5 页面生命周期

```typescript
import { LifecycleExtension } from '@xesam/js_bridge_core';

private lifecycleExtension: LifecycleExtension = new LifecycleExtension(this.bridge);

aboutToAppear(): void {
  this.bridge.resetPageInstance();
  void this.lifecycleExtension.onHostEvent('created');
}

onPageShow(): void {
  void this.lifecycleExtension.onHostEvent('foreground');
}

onPageHide(): void {
  void this.lifecycleExtension.onHostEvent('background');
}
```

> 在握手完成之前发送的事件会被排队（最多 32 条），握手完成后按顺序刷新。

### 2.6 加载页面

```typescript
// 确保 WebAssets 已通过 `pnpm sync` 同步到 entry/src/main/resources/rawfile/web/
Web({ src: $rawfile('web/index.html'), controller: this.controller })
```

## WebAssets

`entry/src/main/resources/rawfile/web/` 不纳入版本控制。从 `web-assets/` 同步：

```bash
cd web-assets && pnpm sync
```

## 构建与签名

HarmonyOS 应用安装到设备需要签名。示例工程的约定：

| 文件 | 是否入库 | 说明 |
|------|---------|------|
| `build-profile.json5.template` | ✅ | 项目结构模板，不含任何签名材料 |
| `build-profile.json5` | ❌（已 gitignore） | 由 DevEco Studio 自动生成，含本机 debug 签名路径 |

首次运行：

```bash
cd js_bridge_harmony/js-bridge-example
cp build-profile.json5.template build-profile.json5
# 用 DevEco Studio 打开本目录，IDE 会自动生成 debug 签名（证书位于 ~/.ohos/config/）
```

签名配置正确时构建输出 `entry-default-signed.hap`。若安装 `entry-default-unsigned.hap` 失败并报 `error: no signature file`，依次检查：

1. 本地 `build-profile.json5` 是否含 `signingConfigs.default`；
2. `products.default` 是否绑定 `"signingConfig": "default"`；
3. 引用的签名文件是否存在于 `~/.ohos/config/`。

命令行构建与真机测试（需配置 `DEVECO_SDK_HOME`）参见根目录 `scripts/test_harmony.sh`：设备在线时执行完整链路（同步测试副本 → assembleHap → hdc 安装 → hypium `aa test`，用例规模以脚本输出为准），无设备时退化为编译验证。

> **安全红线**：签名材料（`.p12` / `.p7b` / 证书路径 / 密码）绝不能提交进 Git。若曾误提交，必须轮换受影响的调试签名材料（仅清理最新提交不够）。CI 环境应将签名材料存入 secrets，构建时动态注入。生产签名参考 HarmonyOS 官方 release signingConfig 文档。

## 示例方法

| 方法 | 说明 |
|------|------|
| `getUser` | 返回模拟用户信息 |
| `request` | HTTP GET 请求 |
| `timerLog` | 流式定时器（多帧） |
| `showLoading` | 原生加载弹窗 |
| `pickImage` | 图片选择器 |
| `pickInput` | 输入对话框 |
| `getCurrentLocation` | 地理定位 |
