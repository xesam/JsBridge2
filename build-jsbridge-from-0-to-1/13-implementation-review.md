# 第 13 章：实现回顾

## 目标
回头一起确认：我们完成的不是"能跑 demo"，而是"可演进的桥接库"。

## 复盘 1：分层是否清晰
本仓库最终的包结构（四端同构）：
- `api`：协议模型和契约（`BridgeMessage`、`BridgeError`、`BridgeApiContract`、`TrustedPageContext`）。
- `core`：Tier 1 编排与分发（`CoreBridge` + handler 接口 + `core.transport` 的 `BridgeTransport` SPI）。
- `security`：Tier 2 组件——上下文、策略链、session；`JsBridge` 作为 Tier 2 入口叠加在 `CoreBridge` 之上。
- `extensions`：Tier 3 可选增强（lifecycle / registry / system），默认不接线。

依赖方向严格单向：`JsBridge → CoreBridge → api`，`security → api`，`extensions → JsBridge | CoreBridge | api`（`system` 适配器还实现 security 层的 `PageContextProvider` SPI）。CoreBridge 零 security 依赖，security 零 core 依赖；transport 与 security 不得互相引用。

对着自己的实现检查一遍：
1. core 是否依赖了具体 WebView？——不允许，出现了就说明具体平台漏进了分层。
2. api 是否依赖了内部实现细节？——不允许，api 只保留协议模型与契约。
3. 扩展是否可以独立增删？——Tier 3 全部可选，不接线不影响主链路。

## 复盘 2：职责是否稳定
- 核心只做核心：协议、分发、会话、基线策略。
- 业务策略通过 `SecurityConfig.extraPolicies` 注入，而非写死在核心。
- 平台差异留在 adapter 层处理（如 `AndroidWebViewBridgeTransport`）。

## 复盘 3：语义是否一致
特别关注：
1. 错误码是否统一取自 `BridgeApiContract` 基线。
2. 生命周期事件是否统一走 `runtime.state`（payload `{state, seq}`）。
3. 二态 SecurityConfig（null / 完整配置）与渐进增强原则是否保持"默认关闭"。

## 我们最终得到的能力

1. 一条亲手打通的 JS-Native 双向通信链路——能说清 WebView 管道与消息协议的每个环节
2. 一套可叠加的分层架构（Tier 1 协议分发 + Tier 2 安全策略 + Tier 3 扩展）——知道每一层为什么这样切
3. 一条可复制的跨端一致性路径（协议一致 + 运行时各自实现）——可直接对照四端参考实现验证

## 后续演进方向

本教程聚焦"从 0 到 1 实现核心能力"，生产化需要补充的内容包括：
- 跨端一致性验收（参考 `docs/09-conformance.md` 用例设计）
- 可观测性与审计日志
- 性能优化与并发控制
- 完整测试覆盖（单元 + 集成 + E2E）

这些属于工程化实践，超出本教程范围。
