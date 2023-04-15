# 04 跨端一致性验收

## 1 目的

定义 JS-Native bridge 协议行为的跨端验收标准。所有平台实现必须通过全部用例。合规 = 通过 C01–C30。

## 2 用例格式

每条用例包含以下字段：

- **id**：唯一标识符（C01–C30）
- **名称**：简短描述该用例验证的行为
- **前置条件**：执行该用例时 bridge 的初始状态
- **输入**：触发行为的操作或消息
- **期望输出**：通过验收的可观测结果
- **覆盖层**：Native core 或 JS client

## 3 验收用例（C01–C30）

### Native core（C01–C13, C17, C18, C28–C30）

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C01 | 握手前请求被拒绝 | bridge ready，无 session | getUser 请求，无 sessionId | ok=false，E_POLICY_DENY | Native core |
| C02 | 握手成功返回 session payload | 无 session | bridge.handshake 请求 | ok=true，payload 含 sessionId/capabilities/sessionTtlMs/policyVersion/origin/accepted | Native core |
| C03 | 非白名单方法被拒绝 | 已握手 | 调用 notAllowed 方法 | ok=false，E_METHOD_NOT_ALLOWED | Native core |
| C04 | 非允许 origin 被拒绝 | 无 session | bridge.handshake，origin 不在白名单 | ok=false，E_ORIGIN_DENY | Native core |
| C04b | origin 前缀不精确匹配拒绝 | 无 session | origin 为白名单条目的子路径 | ok=false，E_ORIGIN_DENY | Native core |
| C05 | 握手后合法请求成功 | 已握手 | 白名单内方法 + 有效 session | ok=true | Native core |
| C06 | 无 session 的请求被拒绝 | 已握手 | 业务请求，不携带 sessionId | ok=false，E_SESSION_INVALID | Native core |
| C07 | origin 不匹配被拒绝 | 已握手 | 业务请求，session origin 与请求 origin 不同 | ok=false，E_SESSION_INVALID | Native core |
| C08 | pageInstanceId 不匹配被拒绝 | 已握手 | 业务请求，resetForNewPage 后使用旧 session | ok=false，E_SESSION_INVALID | Native core |
| C09 | 能力集外方法被拒绝 | 已握手 | 调用不在 capabilities 内的方法 | ok=false，E_CAPABILITY_DENY | Native core |
| C10 | 无 handler 方法返回 not found | 已握手 | 白名单内但未注册的方法 | ok=false，E_METHOD_NOT_FOUND | Native core |
| C11 | handler 抛出异常被归一化 | 已握手 | 调用会抛出异常的 handler | ok=false，E_INTERNAL | Native core |
| C12 | extraPolicy 自定义拒绝 | 已握手，注入自定义 deny policy | 任意请求 | ok=false，自定义错误码 | Native core |
| C13 | 流式响应多帧+最终帧 | 已握手，注册 streaming handler | keep=true 请求 | 多帧 done=false + 最终 done=true | Native core |
| C17 | transport send 失败可观测 | transport 配置为失败 | 任意响应尝试发送 | sendFailureCount 递增 | Native core |
| C18 | resetForNewPage 使旧 session 失效 | 已握手，调用 resetForNewPage | 用旧 session 发请求 | ok=false，E_SESSION_INVALID | Native core |
| C28 | lifecycle 事件 ready 前排队补发 | 构造 LifecycleExtension，未握手 | 触发 3 个 lifecycle 事件 → 握手 | 握手前 transport 无 runtime.state；握手后按原顺序收到 3 条，seq=1,2,3 | Native core |
| C29 | lifecycle 队列超限丢最旧 | LifecycleExtension maxPendingEvents=2，未握手 | 触发 3 个事件 → 握手 | 仅收到后 2 条，seq 保持原值 2,3 | Native core |
| C30 | ready 后 lifecycle 直发且 payload 固定 | 已握手 | 触发 1 个事件 | 立即发出 kind=event, method=runtime.state，payload 恰为 {state, seq} | Native core |

### JS client（C14–C16, C19–C23）

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C14 | 超时触发客户端失败回调 | BridgeClient 构造，transport mock | callNativeApi with timeoutMs=20，无响应 | fail 回调触发，error.code = E_TIMEOUT | JS client |
| C15 | 超时后迟到响应被忽略 | 同 C14 | 超时后再发送匹配 reqId 的响应 | fail 只触发一次，success 不触发 | JS client |
| C16 | session 不匹配 event 被忽略 | 注册 event handler，clientSession=s1 | event with sessionId=s2 | handler 不触发；event with sessionId=s1 → handler 触发 | JS client |
| C19 | lifecycle seq 乱序过滤 | 使用 createLifecycleBridge | 发 seq=1,3,2,4 的 runtime.state | listener 收到 1,3,4；seq=2 被丢弃 | JS client |
| C20 | policy-deny 错误形状校验 | BridgeClient 构造 | 模拟 native 返回 ok=false 错误响应 | fail 回调中 error 含 code/message/retryable 三个字段 | JS client |
| C21 | settled-map TTL 到期清理 | BridgeClient 构造，mock Date.now() | 超时 → 推进时间 >60s → 发同 reqId 响应 | TTL 内：log "late response dropped"；TTL 后：log "pending callback not found" | JS client |
| C22 | event sessionId 严格匹配含空串兼容 | clientSession=s1 | event with s2（忽略）、s1（派发）、""（派发） | s2 被过滤；s1 和 "" 均触发 handler | JS client |
| C23 | Level 0 裸分发无需握手 | BridgeClient 构造，sessionId="" | callNativeApi → 模拟 native ok:true / ok:false 响应 | success / fail 正常路由；请求正常发出 | JS client |
| C24 | AbortSignal 取消待处理请求 | BridgeClient 构造，AbortController 创建 | callNativeApi with signal → abort() | fail 回调触发，error.code = E_CANCELED；迟到响应被忽略 | JS client |
| C25 | AbortSignal 取消流式请求 | BridgeClient 构造，keep=true + signal | 发送 done=false 帧 → abort() | 前序帧 success 正常；abort 后 fail 回调触发，error.code = E_CANCELED；后续帧被忽略 | JS client |
| C26 | AbortSignal 注销事件监听器 | registerEventHandler with signal | 发 event → abort() → 再发 event | abort 前事件被派发；abort 后事件被忽略（handler 已注销） | JS client |
| C27 | 预中止 signal 立即拒绝 | AbortController 创建后立即 abort() | callNativeApi with pre-aborted signal | fail 回调触发，error.code = E_CANCELED；transport.send 未被调用 | JS client |

## 4 各端实现覆盖

| 平台 | Native core 测试 | JS client 测试 | 覆盖 |
|------|-----------------|----------------|------|
| Android | `js_bridge_android/js-bridge-core/src/test/java/.../ConformanceCoreBaselineTest.java` | `js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js` | C01–C18, C28–C30, C19–C27 |
| iOS | `js_bridge_ios/js-bridge-core-swift/Tests/BridgeCoreTests/ConformanceCoreBaselineTests.swift` | `js_bridge_ios/js-bridge-example/tests/js/bridge-client-conformance.cases.js` | C01–C18, C28–C30, C19–C27 |
| Flutter | `js_bridge_flutter/packages/js_bridge_core/test/conformance_core_baseline_test.dart` | `js_bridge_flutter/tests/js/bridge-client-conformance.cases.js` | C01–C18, C28–C30, C19–C27 |
| HarmonyOS | 暂无独立单元测试（hvigor build 验证） | `js_bridge_hm/tests/js/bridge-client-conformance.cases.js` | C14–C27（JS client） |

## 5 运行命令

```bash
# Android native core
cd js_bridge_android && ./gradlew :js-bridge-core:test

# iOS native core
swift test --package-path js_bridge_ios/js-bridge-core-swift

# Flutter native core
cd js_bridge_flutter/packages/js_bridge_core && flutter test

# JS client conformance（四端逐一运行）
node js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js
node js_bridge_ios/js-bridge-example/tests/js/bridge-client-conformance.cases.js
node js_bridge_flutter/tests/js/bridge-client-conformance.cases.js
node js_bridge_hm/tests/js/bridge-client-conformance.cases.js
```
