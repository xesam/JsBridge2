# 第 10 章：策略引擎与渐进增强

## 本章目标
把“零散 if 判断”升级为可组合策略链。

## 分层思路
- 协议固定一条基线策略链与求值顺序，四端一致。
- 宿主通过配置选择启用到哪一级，再注入额外策略承接业务差异。

这样可以做到：
- 核心稳定。
- 业务可定制。
- 版本演进可控。

## 策略链（固定求值顺序）
任一策略返回 `allowed=false` 短路整条链：

| 顺序 | 策略 | 职责 | 拒绝错误码 |
|------|------|------|-----------|
| 1 | `RequestShapePolicy` | `method` 非空且 `kind=request` | `E_INVALID_MESSAGE` |
| 2 | `HandshakeGatePolicy`（可选） | 未握手时阻断非 `bridge.handshake` 调用 | `E_POLICY_DENY` |
| 3 | `AccessControlPolicy`（可选） | origin 白名单 → method 白名单 → session 有效性 → capabilities | `E_ORIGIN_DENY` / `E_METHOD_NOT_ALLOWED` / `E_SESSION_INVALID` / `E_CAPABILITY_DENY` |
| 4 | `extraPolicies` | 宿主注入的自定义规则，按注入顺序执行 | 由规则自带 |

`AccessControlPolicy` 对 `bridge.handshake` 有豁免：通过 origin/method 检查后跳过 session 检查（握手正是为了建立 session）。

## 三级安全配置（渐进增强）
策略链通过 `JsBridge.SecurityConfig` 可选且渐进地启用：

```java
new SecurityConfig()                    // Level 0：仅 RequestShapePolicy，无需握手
new SecurityConfig().withHandshakeGate() // Level 1：加握手门禁，无 origin/capability 校验
SecurityConfig.secure()                  // Level 2：withHandshakeGate + withAccessControl，生产场景
```

Level 2 必须显式配置 `allowedOrigins`（精确匹配，无前缀通配）、`methodWhitelist`、`defaultCapabilities`、`sessionTtlMs`。防呆约束：启用 AccessControl 但 `allowedOrigins` 仍是通配 `"*"` 时，构造函数直接抛 `IllegalArgumentException`——逼宿主做出真实配置。

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
1. 未通过策略的请求返回对应错误码（如 `E_ORIGIN_DENY`、`E_CAPABILITY_DENY`），而非笼统拒绝。
2. 不改核心代码即可通过 `extraPolicies` 增加一条业务策略。
3. 策略执行顺序与短路语义明确且四端一致。
4. Level 0 下 `resetForNewPage()` 后无需握手即可调用。

## 常见坑
1. 在 handler 内部补做策略判断，导致策略分散。
2. 策略 deny 但无错误码，前端无法区分原因。
3. 把业务风控做成基线策略，导致核心耦合业务。
4. Level 2 下沿用通配 `"*"` 的 allowedOrigins——形同虚设，已被构造函数拦截。

## 小结
策略引擎让 Bridge 具备“统一门禁 + 可插拔增强”的能力。第 11 章进入事件扩展。
