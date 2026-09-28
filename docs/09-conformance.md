# 09 跨端一致性验收

> 更新日期：2026-09  
> 适用平台：Android · iOS · Flutter · HarmonyOS

## 1 目的

定义 JS-Native bridge 协议行为的跨端验收标准。所有平台实现必须通过全部用例。合规 = 通过 C01–C65（含 C04b，为 C04 的补充用例；C42/C58/C59 属宿主 instrumented 层，随宿主接入套件执行）。

## 2 用例格式

每条用例包含以下字段：

- **id**：唯一标识符（C01–C65，含补充用例 C04b）
- **名称**：简短描述该用例验证的行为
- **前置条件**：执行该用例时 bridge 的初始状态
- **输入**：触发行为的操作或消息
- **期望输出**：通过验收的可观测结果
- **覆盖层**：Native core / JS client / 宿主 instrumented / Android host 四类之一（以 §3 各行「覆盖层」列的登记为准）

## 3 验收用例（C01–C65）

### Native core（C01–C13, C17, C18, C28–C30, C33–C38, C48, C49, C51–C56, C60, C61, C62, C64, C65）

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C01 | 握手前请求被拒绝 | bridge ready，无 session | getUser 请求，无 sessionId | ok=false，E_NOT_READY（与 E_POLICY_DENY 分立，见 [03-protocol.md](03-protocol.md) §8 传输层类） | Native core |
| C02 | 握手成功返回 session payload | 无 session | bridge.handshake 请求 | ok=true，payload 含 sessionId/sessionTtlMs/policyVersion/origin/accepted | Native core |
| C03 | 非白名单方法被拒绝 | 已握手 | 调用 notAllowed 方法 | ok=false，E_METHOD_NOT_ALLOWED | Native core |
| C04 | 非允许 origin 被拒绝 | 无 session | bridge.handshake，origin 不在白名单 | ok=false，E_ORIGIN_DENY | Native core |
| C04b | origin 前缀不精确匹配拒绝 | 无 session | origin 为白名单条目的子路径 | ok=false，E_ORIGIN_DENY | Native core |
| C05 | 握手后合法请求成功 | 已握手 | 白名单内方法 + 有效 session | ok=true | Native core |
| C06 | 无 session 的请求被拒绝 | 已握手 | 业务请求，不携带 sessionId | ok=false，E_SESSION_INVALID | Native core |
| C07 | origin 不匹配被拒绝 | 已握手 | 业务请求，session origin 与请求 origin 不同 | ok=false，E_SESSION_INVALID | Native core |
| C08 | pageInstanceId 不匹配被拒绝 | 已握手 | 业务请求，resetPageInstance 后使用旧 session | ok=false，E_SESSION_INVALID | Native core |
| C10 | 无 handler 方法返回 not found | 已握手 | 白名单内但未注册的方法 | ok=false，E_METHOD_NOT_FOUND | Native core |
| C11 | handler 抛出异常被归一化 | 已握手 | 调用会抛出异常的 handler | ok=false，E_INTERNAL | Native core |
| C12 | extraPolicy 自定义拒绝 | 已握手，注入自定义 deny policy | 任意请求 | ok=false，自定义错误码 | Native core |
| C13 | 流式响应多帧+最终帧 | 已握手，注册 Async handler（ResponseEmitter） | keep=true 请求 | 多帧 done=false + 最终 done=true | Native core |
| C17 | transport send 失败可观测 | transport 配置为失败 | 任意响应尝试发送 | `postEvent` 返回 `false`（send 失败可观测；内部 `sendFailureCount` 计数递增——公开 reader 已按「零兼容包袱」四端删除） | Native core |
| C18 | resetPageInstance 使旧 session 失效 | 已握手，调用 resetPageInstance | 用旧 session 发请求 | ok=false，E_SESSION_INVALID | Native core |
| C28 | lifecycle 事件 ready 前排队补发 | 构造 LifecycleExtension，未握手 | 触发 3 个 lifecycle 事件 → 握手 | 握手前 transport 无 runtime.state；握手后按原顺序收到 3 条，seq=1,2,3 | Native core |
| C29 | lifecycle 队列超限丢最旧 | LifecycleExtension maxPendingEvents=2，未握手 | 触发 3 个事件 → 握手 | 仅收到后 2 条，seq 保持原值 2,3 | Native core |
| C30 | ready 后 lifecycle 直发且 payload 固定 | 已握手 | 触发 1 个事件 | 立即发出 kind=event, method=runtime.state，payload 恰为 {state, seq} | Native core |
| C33 | 空 method 请求返回 E_INVALID_MESSAGE | bridge ready | 合法信封但 method="" | ok=false，E_INVALID_MESSAGE | Native core |
| C34 | 缺 kind 的消息静默丢弃 | bridge ready | 无 kind 字段的请求 | 无任何响应（解析层丢弃） | Native core |
| C35 | handshake 不在白名单仍自动放行 | 传入 SecurityConfig，methodWhitelist 不含 bridge.handshake | bridge.handshake 请求 | ok=true，payload 含 sessionId（协议方法由框架装配期自动并入放行集） | Native core |
| C36 | 未知 sessionId 请求被拒绝 | 已握手 | 白名单内方法 + 不存在的非空 sessionId | ok=false，E_SESSION_INVALID | Native core |
| C37 | cancelScope 响应回显 payload scopeId | 传入 SecurityConfig，whitelist 含 bridge.cancelScope | bridge.cancelScope，payload 含 scopeId | ok=true，payload={scopeId: 回显值, accepted: true} | Native core |
| C38 | 缺失可选字段取默认值 | 无配置（null），注册 echo handler | 仅含 id/kind/method 的请求（无 sessionId/ts/timeoutMs/keep/payload） | 解析不丢弃，正常分发，ok=true | Native core |
| C48 | 协议方法自动并入白名单 | 传入 SecurityConfig，methodWhitelist 不含 bridge.handshake 与 bridge.cancelScope | 握手 → bridge.cancelScope（payload 含 scopeId）→ 白名单外业务方法 → 白名单内业务方法 | 握手 ok=true；cancelScope ok=true 回显 scopeId；白名单外业务方法 E_METHOD_NOT_ALLOWED；白名单内业务方法 ok=true | Native core |
| C49 | 重复注册同 method 后者覆盖 | 无配置（null） | 同一 method 连续注册 h1、h2 两个 Simple handler → 发起该方法的请求 | 仅 1 帧响应，payload 来自 h2，`ok=true`；h1 未被调用（既非并存、亦非"先注册者生效"） | Native core |
| C51 | 必填字段类型非法静默丢弃 | bridge ready | 依次发送 id/kind/method 为非字符串值、sessionId 为非字符串值的请求 | 四条消息均**无任何响应**（见 docs/03 §3.4：必填字段类型非法 → 静默丢弃，禁止宽容转换），后续正常请求不受影响 | Native core |
| C52 | handler 无数据成功必发终止帧 | 无配置（null），注册返回 `success(null)` 的 Simple handler | 发起该方法的请求 | 收到恰好 1 帧 `ok=true` 且 `payload=null` 的 `done=true` 响应——**不得静默吞帧**（Harmony emitter 适配器曾因 null 守卫吞掉终止帧） | Native core |
| C53 | 策略拒绝无 error 时 fail-closed | 传入 SecurityConfig，extraPolicies 注入"返回 deny 但不携带 error"的策略 | 发起任意业务请求 | 收到 `ok=false`、`error.code = E_POLICY_DENY` 的失败响应（deny 但缺 error 时以 E_POLICY_DENY 兜底，禁止静默放行到 dispatch） | Native core |
| C54 | origin 序列化归一化契约 | 使用各端核心层提供的 origin 归一化函数（四端同一套手写字符串算法，不依赖平台 URL 解析器） | `c54_…vectorSuite`：正本 `docs/origin-normalizer-vectors.json` 的全量向量（scheme 词法 / 非层级形态 fail-closed / 本地内容协议 `scheme://` / IPv6 括号保留 / 端口 1..65535 纯数字校验 / 默认端口整数值省略） | 43 条向量四端逐一命中；内嵌向量集由 `scripts/check_origin_vectors.sh` 与正本强制一致（四端漂移的程序化防线） | Native core |
| C55 | postEvent 默认空串广播 | 无配置（null），握手建立 session 后 | `postEvent(method, payload)` 不传 sessionId → 发起请求 | 事件帧 `sessionId=""`；JS 客户端按 C22 空串语义无条件派发（四端默认值统一为广播；v1 事件投放**唯一形态**为广播，见 docs/03 §3.3） | Native core |
| C56 | session 签发时清扫过期记录 | SessionService（InMemory 实现），签发 session A（TTL 短） | 推进时钟超过 A 的 TTL → 再次握手签发 session B → 查询 A | `find(A)` 失败（E_SESSION_INVALID 语义）；存储中过期记录被签发时的顺带清扫移除——握手高频场景下存储不随过期条目无界增长 | Native core |
| C60 | sessionTtlMs=0 永不过期 | SecurityConfig `sessionTtlMs=0`，注册 echo handler | 握手建立 session → 推进时钟（真实等待或注入时钟）越过任意时长 → 再次以该 sessionId 请求 | 请求 `ok=true`，session 不因 TTL 失效；签发时清扫亦不移除该记录（docs/03 §10 "0 表示永不过期"——此前 Android/iOS/Harmony 误实现为立即过期） | Native core |
| C61 | 重复握手刷新旧 session | SessionService，同一 `TrustedPageContext`（同 origin+pageInstanceId） | 连续两次握手签发 session A、B → 查询 A → 以 A 的 sessionId 发起白名单内业务请求 | `find(A)` 失败、旧请求返回 `E_SESSION_INVALID`；`find(B)` 有效且存储内同 pageInstanceId 仅存活 1 条（docs/03 §7.1 幂等性"应刷新会话（而非报错）"、§10 刷新语义——刷新而非并存） | Native core |
| C62 | async handler 启动即返，不阻塞入站管线 | JsBridge（无配置或完成握手）+ transport mock；注册 Async handler `busy`（发射 `done=false` 首帧后挂起、不收尾）+ Simple handler `ping` | 发起 `busy` 请求 r1 → busy 首帧发出后，发起 `ping` 请求 r2 | r2 的 `done=true` 单帧响应在 busy 挂起期间已写入 transport——dispatch 不因流式 handler 未完成而阻塞后续消息（四端统一"启动即返"语义；HarmonyOS 曾为唯一内联 await 实现，已对齐）；r1 除首帧外无终帧逃逸 | Native core |
| C64 | Tier-1 kind 路由守卫：非 request 信封不派发 | standalone CoreBridge（不经策略链）+ transport mock，注册 Simple handler `leak.test` | 以 kind=response / kind=event 信封（method 与注册表同名）直接 dispatch；再以 kind=request 对照 | 非 request 信封： handler 零调用、零响应帧产出（丢弃而非按 method 派发——Tier-2 路径由 RequestShapePolicy 先行拒绝，本用例锚定 standalone 面）；对照 request 正常单帧响应 | Native core |
| C65 | 通配 `*` 使 Origin/MethodGate 节点不进链（真实装配面） | 真实 `JsBridge` 装配：`SecurityConfig` 非 null 且 `allowedOrigins`/`methodWhitelist` 均为 `{"*"}`；注册业务 handler；context provider 供任意未白名单 origin | 握手（origin=任意）→ 已注册但白名单外的业务方法请求（同 origin）→ 换 context origin 后复用该 sessionId 请求 | 握手 `ok=true`；白名单外方法请求 `ok=true`（Origin/MethodGate 均未进链——通配是"节点不装配"而非"装配后对齐放行"，非通配配置下同输入为 E_ORIGIN_DENY/E_METHOD_NOT_ALLOWED，锚定装配逻辑而非手拼链）；换 origin 后 `ok=false`、`E_SESSION_INVALID`（SessionPolicy 仍在链——通配只豁免对应维度，不影响 session origin 匹配。2026-09-26 前 Origin/MethodGate 的通配排除分支四端均为"代码为真、无用例锁定"，本用例收口该缺口） | Native core |

> **C35 语义说明**：`methodWhitelist` 为**业务方法白名单**——协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架在装配期自动并入放行集，宿主无需显式列入（显式列入亦合法，冗余无副作用；C37 保留显式列入写法，恰构成向后兼容断言）。C35 期望输出为"ok=true"。见 `docs/03-protocol.md §7.1 / §9`。

> **C49 语义说明**：同一 method 重复注册时**后者覆盖前者**（四端统一，后注册生效）。该用例正是「双注册表隐式优先级」缺陷的回归锚点——此前 Android 的 `contextHandlers` 与 `CoreBridge.handlers` 分属两张表，同一 method 两边注册时"先注册者未必生效"。C49 以**单一注册表**为前提，四端行为由该用例固定。

> **C13 与 C43 的分工**：两者都断言多帧，但锚定不同契约面——**C13 断言流式帧序语义**（`keep=true` 请求、`done=false → done=true` 帧序），**C43 断言异步时序**（handler 返回后经 ResponseEmitter 继续推帧，帧间穿插 await/等待）。两用例编号均已登记，不得合并或复用。二者统一由 `registerAsyncHandler` + ResponseEmitter 表达（Simple 路径恒为单帧、`done=true`，见 [08-handler-interface-contract.md](08-handler-interface-contract.md) §2）。**C62 断言管线不阻塞**（busy handler 挂起期间后续消息照常处理）——与 C13（帧序）、C43（返回后推帧时序）锚定不同契约面，三者不得合并或复用。

### JS client（C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63）

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C14 | 超时触发客户端失败回调 | CoreBridgeClient 构造，transport mock | callNativeApi with timeoutMs=20，无响应 | fail 回调触发，error.code = E_TIMEOUT | JS client |
| C15 | 超时后迟到响应被忽略 | 同 C14 | 超时后再发送匹配 reqId 的响应 | fail 只触发一次，success 不触发 | JS client |
| C16 | session 不匹配 event 被忽略 | 注册 event handler，clientSession=s1 | event with sessionId=s2 | handler 不触发；event with sessionId=s1 → handler 触发 | JS client |
| C19 | lifecycle seq 乱序过滤 | 使用 createLifecycleBridge | 发 seq=1,3,2,4 的 runtime.state | listener 收到 1,3,4；seq=2 被丢弃 | JS client |
| C20 | policy-deny 错误形状校验 | CoreBridgeClient 构造 | 模拟 native 返回 ok=false 错误响应 | fail 回调中 error 含 code/message/retryable 三个字段 | JS client |
| C21 | settled-map TTL 到期清理 | CoreBridgeClient 构造，mock Date.now() | 超时 → 推进时间 >60s → 发同 reqId 响应 | TTL 内：log "late response dropped"；TTL 后：log "pending callback not found" | JS client |
| C22 | event sessionId 严格匹配含空串兼容 | clientSession=s1 | event with s2（忽略）、s1（派发）、""（派发） | s2 被过滤；s1 和 "" 均触发 handler | JS client |
| C23 | null 配置裸分发无需握手 | CoreBridgeClient 构造，sessionId="" | callNativeApi → 模拟 native ok:true / ok:false 响应 | success / fail 正常路由；请求正常发出 | JS client |
| C24 | AbortSignal 取消待处理请求 | CoreBridgeClient 构造，AbortController 创建 | callNativeApi with signal → abort() | fail 回调触发，error.code = E_CANCELED；迟到响应被忽略 | JS client |
| C25 | AbortSignal 取消流式请求 | CoreBridgeClient 构造，keep=true + signal | 发送 done=false 帧 → abort() | 前序帧 success 正常；abort 后 fail 回调触发，error.code = E_CANCELED；后续帧被忽略 | JS client |
| C26 | AbortSignal 注销事件监听器 | registerEventHandler with signal | 发 event → abort() → 再发 event | abort 前事件被派发；abort 后事件被忽略（handler 已注销） | JS client |
| C27 | 预中止 signal 立即拒绝 | AbortController 创建后立即 abort() | callNativeApi with pre-aborted signal | fail 回调触发，error.code = E_CANCELED；transport.send 未被调用 | JS client |
| C31 | policy-deny 响应路由到 fail 回调 | CoreBridgeClient 构造 | 模拟 native 返回 E_POLICY_DENY 的 ok=false 响应 | fail 回调触发一次，error.code = E_POLICY_DENY | JS client |
| C32 | keep 流式多帧与最终帧 | CoreBridgeClient 构造，keep=true | 2 帧 done:false + 1 帧 done:true + 迟到帧 | success 依序触发 3 次；done:true 后迟到帧被忽略 | JS client |
| C39 | timeoutMs=0 禁用超时 | CoreBridgeClient 构造 | callNativeApi with timeoutMs=0，无响应 → 等待 → 发送匹配响应 | 等待期间不触发 fail；响应送达时 success 正常触发 | JS client |
| C50 | 不可处理响应快速失败非超时 | CoreBridgeClient 构造，transport mock，挂起请求（短超时） | ① 发送 reqId 匹配但 kind 未知的响应；② 发送 reqId 不匹配的同款消息；③ 等待超过 timeoutMs | ① 关联请求**同步** fail，error.code = E_INTERNAL（非 E_TIMEOUT）且仅触发一次；② 无关联请求受影响；③ 到期无二次失败（挂起已正确清理） | JS client |
| C57 | 用户回调抛异常不破坏落定状态 | CoreBridgeClient 构造，transport mock，挂起请求 | 发送匹配响应，success 回调内抛异常；随后发送同 reqId 的迟到响应 | 回调异常被捕获（不向 transport 调用方穿透）；单帧响应后 pending 被清理：定时器摘除、迟到响应按 settled 丢弃、无二次 fail——落定路径的清理先于/独立于用户回调执行 | JS client |
| C63 | 响应帧落定收口：流中失败帧终结 + 会话错配 fail-fast（docs/03 §4.3） | CoreBridgeClient 构造，transport mock，keep=true 挂起请求；再挂起短超时请求 | ① 发送 ok=false 且 done=false 的流帧；② 再发同 reqId 的续流/终帧；③ 发送 reqId 匹配但 sessionId 错配的响应；④ 等待超过 timeoutMs | ① fail 恰好一次（携带 handler 错误码）且流终结；② 后续帧按迟到帧丢弃（无任何回调）；③ 同步 fail-fast，error.code = E_SESSION_INVALID（非静默丢弃、非 E_TIMEOUT）；④ 到期无二次失败 | JS client |

> **编号说明**：C17/C18 属于 Native core 用例。JS client conformance 脚本早期复用了 C17/C18 编号表示两个 JS 用例，现已消歧为 C31/C32；"某用例已通过"必须以本表编号为准。C40/C41 已纳入四端 JS conformance cases（覆盖 transport 层，确定性断言）；C42 为宿主接入套件义务（instrumented 层），不计入四端纯 JVM 基线。

### Transport 信道建立（C40–C42）

> 基于 pull 模型 + reqId 相关性（见 [06-channel-establishment.md](06-channel-establishment.md)）。C40/C41 为确定性断言（无 sleep、无时序依赖）；C42 为宿主生命周期义务的可测断言。

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C40 | 投递必带 reqId 且匹配请求才采纳 | JS transport 构造，mock MessageEvent 携带 `bridge:channel` 信封 | 发起 requestBridgeChannel(reqId=r1) → 模拟携带 `{type:"bridge:channel",reqId:"r1"}` + port 的投递 | port 被采纳为当前 sender，queue 冲刷；信封缺失 reqId 或 reqId 不匹配请求的投递 → 不采纳 | JS client |
| C41 | 陈旧 reqId 投递被丢弃且端口关闭 | 已采纳 reqId=r2 的端口 | 模拟迟到投递 `{type:"bridge:channel",reqId:"r1"}`（r1 为已被 r2 轮换的旧请求） | 投递被丢弃，event.ports[0].close() 被调用，当前端口仍为 r2 的 port，无消息经旧 port 发出 | JS client |
| C42 | 导航/页面恢复后旧端口必关闭 | Native core 桩，已建通道 | 触发导航（onPageFinished）或页面恢复（pageshow persisted） | 旧 MessageChannel 半端口已关闭、per-WebView 通道记录已清理；宿主未清理 → 测试桩断言失败 | 宿主 instrumented（需 Robolectric/真机 WebView，不在四端纯 JVM 基线内；宿主信道 invalidate 义务的落点断言，见 [06-channel-establishment.md](06-channel-establishment.md) §5.2） |

### 验收强化用例（C43–C46）与竞态修复用例（C47）

> 由"实现偏离规范"的实际案例驱动新增（2026-09-23）。C45/C46 覆盖策略链求值顺序与安全级别切换——此前仅有单策略行为用例，链本身的行为无程序化约束。

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C43 | Async handler 经 emitter 推送多帧响应 | 无配置（null），注册 async handler（带 ResponseEmitter） | 发起请求，handler 依次 emitter(done=false) ×2 + emitter(done=true) | transport 收到 3 帧，前 2 帧 done=false，末帧 done=true，payload 依序递增 | Native core |
| C45 | 策略链按固定顺序求值且首个拒绝即短路 | 构造 `PolicyEngine`，按规范顺序注入策略 | 输入同时触发多个策略拒绝条件 | 返回**最早**拒绝者的错误码；后续策略不执行 | Native core |
| C46 | 安全配置改变策略链组成 | 分别构造无配置 / 有配置（维度 {"*"}）/ 完整配置的 PolicyEngine | 各配置下投喂合法与非法输入 | 无配置仅 RequestShape；有配置含 HandshakeGate+Session；完整配置另含 Origin+MethodGate；各配置错误码符合预期 | Native core |
| C47 | bind 前到达的通道请求被暂存而非丢弃 | Android transport，未调用 `bind()`（`pendingListener == null`） | JS 侧在页面脚本解析期发起 `requestBridgeChannel(reqId=r1)`，随后宿主才调用 `bind()` | 请求进入 pending 队列；`bind()` 时补投 r1 并建通道，JS 侧**无需**等到 2000ms 超时重试；epoch 轮换时队列清空 | Android host（需 WebView，不在四端纯 JVM 基线内；C47 落点见 §4） |

> **C45/C46 说明**：策略链求值顺序见 `docs/04-cross-platform.md §3.1`（安全策略链）与 `AGENTS.md`——固定为 RequestShape → HandshakeGate → Origin → MethodGate → Session → extraPolicies。C45 断言"短路于最早拒绝者"，C46 断言"级别决定链路成员"。四端实现路径：Android `PolicyGroupsTest`（`c45_*`/`c46_*`）、iOS `PolicyChainTests`、Flutter `policy_chain_test.dart`、HarmonyOS `PolicyGroupsTest.test.ets`。
>
> **C44 为保留空缺**：验收强化时该编号曾被草稿占用后释放，按 §6.2「编号不得复用」不再分配，以免与历史提交中的引用冲突。
>
> **C09 为保留空缺**：该编号从未在任何版本投入使用（全仓零定义、零实现、无释放记录），按 §6.2「编号不得复用」显式登记于此，不再分配。

### 建链安全边界用例（C58–C59，宿主 instrumented）

> 与 C42 同层：依赖真机/WebView/DOM 环境，不在四端纯 JVM 基线内（C42/C58 无可执行断言，由 `scripts/check_conformance_ids.sh` 的 `INSTRUMENTED_ONLY` 显式豁免；C59 的代码侧断言已并入 Node conformance 的 C40/C41 内联断言——伪造投递端口必被关闭，无需豁免）。落点断言属**已登记缺口**：宿主 instrumented 接入套件尚未建设（仓库内当前无可执行 C58 的 UI/仪器测试），隔离逻辑代码侧已存在（iOS `WKWebViewBridgeTransport` 的 `frameInfo.isMainFrame` 门控 + `forMainFrameOnly` bootstrap 注入）。instrumented 级完整断言随宿主套件建成后落地。

| 用例 | 名称 | 前置条件 | 输入 | 期望输出 | 覆盖层 |
|------|------|----------|------|----------|--------|
| C58 | iOS 非主 frame bridge 消息被拒收 | WKWebView 加载含可信主 frame + 跨域 iframe 的页面，宿主接入 `WKWebViewBridgeTransport` | iframe 内调用 `window.webkit.messageHandlers.<NativeBridge>.postMessage(...)` 伪造 bridge 信封 | 消息被丢弃（`frameInfo.isMainFrame` 门控），不产生响应、不触发握手；bootstrap 脚本仅注入主 frame（`forMainFrameOnly: true`），iframe 中不存在 `NativeBridge` handler | 宿主 instrumented（需 WKWebView，swift 基线无法构造 `WKScriptMessage`） |
| C59 | MessagePort 采纳校验投递来源 | 页面含第三方 iframe，已发起 `requestBridgeChannel`（reqId 泄露给 iframe） | 恶意 iframe 构造携带匹配 reqId 的 `bridge:channel` MessageEvent，投递自身 MessagePort | 采纳前校验 `event.source`（投递源必须是主 frame 自身，reqId 仅作配对凭证不作信任凭证），不匹配 → 端口关闭不采纳、请求路径不受劫持（docs/03 §9 细则 5 / docs/06 §2.2 投递信任边界） | 宿主 instrumented（需 DOM MessagePort/MessageEvent，Node conformance 无法模拟） |

## 4 各端实现覆盖

| 平台 | Native core 测试 | JS client 测试 | 覆盖 |
|------|-----------------|----------------|------|
| Android | `js_bridge_android/js-bridge-core/src/test/java/.../ConformanceCoreBaselineTest.java`（另有 `UnifiedHandlerApiTest` 承载 C43、`PendingChannelRequestsTest` 承载 C47、`PolicyGroupsTest` 承载 C45/C46） | `js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js` | C01–C08（含 C04b）, C10–C13, C17, C18, C28–C30, C33–C38, C43, C45–C49, C51–C56, C60, C61, C62, C64, C65, C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63 |
| iOS | `js_bridge_ios/js-bridge-core-swift/Tests/BridgeCoreTests/ConformanceCoreBaselineTests.swift`（另有 `PolicyChainTests` 承载 C45/C46） | `js_bridge_ios/js-bridge-example/tests/js/bridge-client-conformance.cases.js` | C01–C08（含 C04b）, C10–C13, C17, C18, C28–C30, C33–C38, C43, C45, C46, C48, C49, C51–C56, C60, C61, C62, C64, C65, C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63 |
| Flutter | `js_bridge_flutter/packages/js_bridge_core/test/conformance_core_baseline_test.dart`（另有 `policy_chain_test.dart` 承载 C45/C46） | `js_bridge_flutter/tests/js/bridge-client-conformance.cases.js` | C01–C08（含 C04b）, C10–C13, C17, C18, C28–C30, C33–C38, C43, C45, C46, C48, C49, C51–C56, C60, C61, C62, C64, C65, C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63 |
| HarmonyOS | `js_bridge_harmony/js-bridge-core/src/test/ConformanceCoreBaseline.test.ets` + `PolicyGroupsTest.test.ets`（真机 hypium 执行：`bash scripts/test_harmony.sh` 同步到 example ohosTest 后经 hdc 安装运行） | `js_bridge_harmony/tests/js/bridge-client-conformance.cases.js` | C01–C08（含 C04b）, C10–C13, C17, C18, C28–C30, C33–C38, C43, C45, C46, C48, C49, C51–C56, C60, C61, C62, C64, C65, C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63（JS client） |

> **C43 的平台差异**：Android 的 `AsyncHandler` 在 `dispatch()` 内**同步**执行，帧在 `deliver()` 返回前到达 transport；iOS/Flutter/HarmonyOS 需等待异步回调。C43 断言的是**帧序列与 done 语义**（跨端契约），执行时机差异不属于协议。HarmonyOS 的帧经 `bindTransport()` 路径发出——`processIncomingResponses` 的返回值不包含 emitter 推送的帧。
>
> **C47 的平台差异（Android 专有，已登记缺口）**：该用例约束的是 pull 模型下"请求先于 `bind()` 到达"的竞态窗口，仅 Android 存在此形态——iOS 走 resident 通道（无 requestBridgeChannel 入口与请求/采纳窗口），Flutter/HarmonyOS 走宿主注入函数（`bindTransport()` 直接闭环）。三端不存在等价丢弃路径，故不实现 C47；缺口由 `scripts/check_conformance_ids.sh` 的 `KNOWN_GAPS` 显式登记，非未登记缺口。
>
> **Android 建链哑入口的 frame 归因限制（残余限制，2026-09 登记）**：`addJavascriptInterface` 注入对象对页面内所有 frame 可见，哑入口层无 frame/origin 归因能力（对照 iOS C58 经 `WKScriptMessageHandler` 的 frame 信息）——跨域 iframe 与主 frame 共享同一限频额度。已实现缓解（`ChannelRequestJavascriptInterfaceTest` 断言）：(a) `postWebMessage` 目标为主 frame，跨域 iframe 拿不走端口（身份伪造不可行，残留危害仅为额度消耗）；(b) 限频 per-bind + 空闲复充窗口，一次性烧光额度只造成 windowMs 级暂时不可用。残余：攻击 iframe 持续洪泛期间主 frame 建通道仍受限——Android 平台能力边界，v1 接受；C58 的 Android 等效用例（iframe 不可采纳端口）属 instrumented 层，不在四端纯 JVM 基线内。
>
> **勘误登记（2026-09-26）**：提交 `46c0971`（`refactor(harmony-core)`：dispatch 启动即返等）的提交信息中，「emitStreamingResponse 失败帧透传 handler 的 done（移除 failResponse 硬改 done=true 与 ResponseEmitter 契约的分裂）」与「模板串拼接改 BridgeError.normalize」两项描述**未出现在该提交的 diff 中**，属提交信息失实。现行代码失败帧仍经 `failResponse` 硬编码 `done=true`——该行为本身正确（docs/03 §4.3：失败帧即终帧）。该函数的变更溯源以 diff 与本登记为准，不得引用该提交信息。
>
> JS client conformance cases 文件四端各存一份副本（仅 SDK 路径行不同），由 `pnpm check` 归一化路径行后四端互比，防止改一端忘三端。

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
node js_bridge_harmony/tests/js/bridge-client-conformance.cases.js
```

## 6 验收用例义务（强制约束）

> 本节为项目级强制约束，与 `AGENTS.md` 的 Conformance 章节互为引用。**任何协议或跨端一致性的设计变更，必须先有程序化验收用例。**

### 6.1 触发表

以下任一项变更，**必须在同一提交/PR 内**新增或更新 conformance 用例：

| 变更类型 | 示例 | 必备用例 |
|----------|------|----------|
| 消息信封字段 | 新增/删除/改语义 `kind`/`reqId`/`scopeId` | 信封解析 + 缺省值 + 非法值拒绝 |
| 错误码 | 新增错误码、拆分既有码（如 v1 的 `E_NOT_READY` 从 `E_POLICY_DENY` 分立） | 触发该码的输入 + 断言码值 |
| 策略链 | 求值顺序、短路语义、链路成员条件 | 顺序断言 + 短路断言 + 各级别链路组成 |
| 握手契约 | session payload 字段、TTL | 握手成功/失败/重复握手 |
| Session 生命周期 | `resetPageInstance` 失效语义、origin/pageInstanceId 匹配 | 失效后旧 session 拒绝 |
| Transport 信道 | `bindTransport`/`resetTransport`、reqId 相关性 | 投递采纳 + 陈旧投递丢弃 |
| Handler 注册契约 | 注册入口增删、handler 形参形态变更、重复注册语义 | 注册后行为断言（如 C49 重复注册覆盖） |
| 新增平台 | 第五端实现 | 全套 C01–C65 |

### 6.2 编号规则

1. **编号不得复用**。新增用例取当前最大编号 +1（当前最大为 **C65**；该「自称最大」与 §3 登记表实际最大的一致性由 `scripts/check_conformance_ids.sh` 的校验④强制约束）。补充用例用 `b` 后缀（如 C04b）。已释放/空缺的编号（**C09、C44**）不再分配。
2. **先登记后实现**。编号必须先写入本文件 §3 表格，再在四端实现。禁止代码中出现未登记的编号——C43 的缺口即由此产生。
3. **四端同步**。新增用例必须在四端全部实现，或在本文件 §4 显式登记缺口。**未登记缺口即视为不合规。**
4. **缺口须登记**。若某端暂时无法实现（如 C42 依赖 instrumented 环境），必须注明原因与落点：instrumented 层缺口登记于 §3 登记表的覆盖层列与所属分节引言（如 C42/C58）；单端专有缺口另在 §4 覆盖表的平台差异注记登记（如 C47）。

### 6.3 命名与位置

| 平台 | 命名 | 位置 |
|------|------|------|
| Android | `[Cc]45_scenario_expectedBehavior`（脚本兼容两种前缀，见下注） | `js-bridge-core/src/test/.../` |
| iOS | `testC45_scenario_expectedBehavior` | `Tests/BridgeCoreTests/` |
| Flutter | `C45_scenario_expectedBehavior` | `packages/js_bridge_core/test/` |
| HarmonyOS | `C45_scenario_expectedBehavior` | `js-bridge-core/src/test/` |

> **Android 前缀现状**：`scripts/check_conformance_ids.sh` 以 `[Cc]` 模式提取并统一大小写，`C`/`c` 两种前缀均被兼容。存量 `ConformanceCoreBaselineTest` 中 C01–C49 用例为旧式大写 `C` 前缀、C51–C65 用例为小写 `c` 前缀（新旧共存）；策略链/UnifiedHandlerApi 等独立承载文件（`PolicyGroupsTest`、`UnifiedHandlerApiTest`、`PendingChannelRequestsTest`）统一用小写 `c` 前缀（如 `c45_policyChain_evaluatesInFixedOrder_requestShapeFirst`、`c43_asyncHandler_...`、`c47_offerBeforeBind_...`）。**新增用例统一用小写 `c` 前缀**（如 `c45_scenario_expectedBehavior`）。

### 6.4 验证

协议变更后必须运行 `scripts/test_all.sh`（共 8 项：四端 + WebAssets + JS conformance + 编号一致性校验 `check_conformance_ids.sh` + origin 向量校验 `check_origin_vectors.sh`）并全绿。任何 FAIL 不得合并。
