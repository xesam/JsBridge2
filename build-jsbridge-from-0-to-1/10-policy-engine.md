# 第 10 章：策略引擎与渐进增强

## 目标
把"零散 if 判断"升级为可组合策略链。

## 设计
- 协议固定一条基线策略链与求值顺序，四端一致；宿主通过 `securityConfig`（传 `null` 或传入完整 `SecurityConfig`）选择是否启用，再注入额外策略承接业务差异。

## 策略链（固定求值顺序）
任一策略返回 `allowed=false` 短路整条链：

| 顺序 | 策略 | 进链条件与职责 | 拒绝错误码 |
|------|------|--------------|-----------|
| 1 | `RequestShapePolicy` | 永远激活：`method` 非空且 `kind=request` | `E_INVALID_MESSAGE` |
| 2 | `HandshakeGatePolicy` | `SecurityConfig` 非 null：未握手时阻断非 `bridge.handshake` 调用 | `E_NOT_READY`（v1 起从 `E_POLICY_DENY` 分立） |
| 3 | `OriginPolicy` | `allowedOrigins` 显式配置且不含 `*`：origin 精确匹配白名单 | `E_ORIGIN_DENY` |
| 4 | `MethodGatePolicy` | `methodWhitelist` 显式配置且不含 `*`：业务 method 白名单（协议方法由框架装配期自动并入放行集） | `E_METHOD_NOT_ALLOWED` |
| 5 | `SessionPolicy` | `SecurityConfig` 非 null：session 存在 → origin/pageInstanceId 匹配 | `E_SESSION_INVALID` |
| 6 | `extraPolicies` | 宿主注入的自定义规则，按注入顺序执行 | 由规则自带 |

`SessionPolicy` 对 `bridge.handshake` 有豁免：直接放行（握手正是为了建立 session）。协议方法（`bridge.handshake` / `bridge.cancelScope`）不需要写进 `methodWhitelist`——`methodWhitelist` 是**业务方法**白名单，框架在装配 `MethodGatePolicy` 时自动把协议方法并入放行集（`BridgeApiContract` 定义协议方法集），白名单漏掉握手时握手请求依然 `ok=true`（conformance C35/C48）。

## 二态安全配置（渐进增强）
`securityConfig` 参数二选一，没有中间态：

```java
null                      // 无安全检查：仅 RequestShapePolicy，无需握手
new SecurityConfig()      // 握手 + session 校验；两个白名单维度显式配置或 {"*"}
    .allowedOrigins(...)
    .methodWhitelist(...)
```

传入 `SecurityConfig` 时构造期强制 `allowedOrigins`（精确匹配，无前缀通配）与 `methodWhitelist` 显式配置——防呆约束：任一字段为 `null` 时构造函数直接抛 `IllegalArgumentException`，逼宿主做出真实配置；`{"*"}` 是合法的"不限制该维度"显式声明（对应策略节点不进链）。`sessionTtlMs`（默认 15 分钟）有内置默认值，不强制显式配置。

## 扩展策略接口
```java
public interface PolicyRule {
    PolicyDecision evaluate(PolicyInput input);
    String name();
}
```

通过 `SecurityConfig.extraPolicies(...)` 注入；`PolicyInput(message, trustedPageContext, ready, sessionRecord)` 组装上下文，`PolicyDecision` 携带 `allowed/error/rule`。

## 判定流程
1. 组装 `PolicyInput`。
2. 按固定顺序执行规则。
3. 首个 deny 直接短路，错误回包给 JS，同时输出审计日志（第 13 章）。

## 验收清单
1. 未通过策略的请求返回对应错误码（如 `E_ORIGIN_DENY`），而非笼统拒绝。
2. 不改核心代码即可通过 `extraPolicies` 增加一条业务策略。
3. 策略执行顺序与短路语义明确且四端一致（基线链：shape → gate → origin → method → session → extra）。
4. `securityConfig == null` 时 `resetPageInstance()` 后无需握手即可调用。

## 常见坑
1. 在 handler 内部补做策略判断，导致策略分散。
2. 策略 deny 但无错误码，前端无法区分原因。
3. 把业务风控做成基线策略，导致核心耦合业务。
4. 传入 `SecurityConfig` 却把 `allowedOrigins` 配成 `{"*"}` 图省事——它只是显式声明"不限制"（构造不报错），`OriginPolicy` 不会进链，来源校验实际被跳过；需要白名单防护时应配置具体 origin，真正漏配（`null`）才会被构造期拦截。
