# 第 16 章：架构复盘与发布前检查

## 本章目标
确认你完成的不是“能跑 demo”，而是“可演进的桥接库”。

## 复盘 1：分层是否清晰
本仓库最终的包结构（四端同构）：
- `api`：协议模型和契约（`BridgeMessage`、`BridgeError`、`BridgeApiContract`、`TrustedPageContext`）。
- `core`：Tier 1 编排与分发（`CoreBridge` + handler 接口 + `core.transport` 的 `BridgeTransport` SPI）。
- `security`：Tier 2 组件——上下文、策略链、session/capability；`JsBridge` 作为 Tier 2 入口叠加在 `CoreBridge` 之上。
- `extensions`：Tier 3 可选增强（lifecycle / registry / system），默认不接线。

依赖方向严格单向：`JsBridge → CoreBridge → api`，`security → api`，`extensions → JsBridge | CoreBridge | api`。CoreBridge 零 security 依赖；transport 与 security 不得互相引用。

检查问题：
1. core 是否依赖了具体 WebView？（不允许）
2. api 是否依赖了内部实现细节？（不允许）
3. 扩展是否可以独立增删？（Tier 3 全部可选）

## 复盘 2：职责是否稳定
- 核心只做核心：协议、分发、会话、基线策略。
- 业务策略通过 `SecurityConfig.extraPolicies` 注入，而非写死在核心。
- 平台差异留在 adapter 层处理（如 `AndroidWebViewBridgeTransport`）。

## 复盘 3：语义是否一致
特别关注：
1. 错误码是否统一取自 `BridgeApiContract` 基线。
2. single-flight 是否在文档与实现中一致。
3. 生命周期事件是否统一走 `runtime.state`（payload `{state, seq}`）。
4. 三级 SecurityConfig（Level 0/1/2）与渐进增强原则是否保持“默认关闭”。

## 发布前检查清单
1. 文档齐全：README + ARCHITECTURE + EXTENSION_GUIDE + tutorial。
2. 构建测试通过：
```bash
cd js_bridge_android
./gradlew :js-bridge-core:test :js-bridge-example:assembleDebug
```
3. 四端一致性：`scripts/test_all.sh` 全绿，conformance 用例（C01–C30）四端全部通过。
4. WebAssets 变更后执行过 `pnpm sync` 并通过 `pnpm check` 校验。
5. 变更记录能解释兼容性影响（协议字段只增不改不删）。

## 课程总结
从 0 到 1 的关键不是“把功能堆满”，而是“先有清晰边界，再做稳定核心，再开放扩展”。

当你按这 16 章完成实现后，你将拥有：
1. 一套可在 Android 落地的 JsBridge 核心（本仓库 `js_bridge_android/js-bridge-core` 即参考实现）。
2. 一套可迁移到 iOS/Flutter/HarmonyOS 的一致架构方法——本仓库已在四端各自实现（Swift / Dart / ArkTS），共享的只有协议。
3. 一套可持续迭代而不失控的工程化基线（分层测试 + conformance 用例 + 审计日志）。
