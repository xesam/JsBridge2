# 第 14 章：按层测试而不是只做端到端

## 本章目标
建立可维护测试体系，避免每次改动都靠手工点页面验证。

## 测试分层策略
对照本仓库 Android 参考实现的单测布局（`js_bridge_android/js-bridge-core/src/test/`）：

1. `core` 单测（`JsBridgeTest`）：
- Level 1/2 下握手前请求被拒绝（`E_POLICY_DENY`）。
- 握手后请求可成功分发。
- extraPolicy 在基线规则之后可 deny。
- handler 抛异常回 `E_INTERNAL`。
- transport 发送失败时 `sendFailureCount` 递增、`postEvent` 返回 false。
- Level 0 默认配置 `resetForNewPage()` 后立即可用、无需握手。
- Level 2 通配 origin 构造直接抛异常。
- 带上下文 handler 能收到 `TrustedPageContext`。

2. `security` 单测：
- `PolicyGroupsTest`：shape/gate/access 各拒绝分支与放行路径。
- `InMemoryCapabilitySessionStoreTest`：TTL 过期清理、`clearByPageInstance` 行为。

3. `extensions` 单测：
- `SingleFlightPendingLaunchesTest`：single-flight busy 语义、pending 清理。

4. 跨端一致性（conformance）：
- Native core 用例（C01–C13, C17, C18, C28–C30）位于 `ConformanceCoreBaselineTest`，四端各一份等价实现。
- JS client 用例（C14–C16, C19–C27）位于共享的 `bridge-client-conformance.cases.js`，直接用 node 运行：
```bash
node js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js
```

## 推荐命令
```bash
cd js_bridge_android
./gradlew :js-bridge-core:test                              # 全部单测
./gradlew :js-bridge-core:test --tests "*.PolicyGroupsTest" # 单个测试类
./gradlew :js-bridge-example:assembleDebug                 # 示例 app
./gradlew lint
```

四端一起跑（HM 在无 DevEco SDK 时自动跳过）：
```bash
scripts/test_all.sh
```

## 章节任务
1. 给每个风险点至少写一个正例和一个反例。
2. 固化可重复执行的 CI 命令。
3. 失败时输出足够定位信息。

## 验收清单
- 修改核心流程后，单测能快速反馈是否回归。
- 不依赖真机也能验证大部分逻辑。

## 常见坑
1. 只写 happy path，不写拒绝/异常路径。
2. 过度依赖集成测试，定位慢。
3. 测试名含糊，读不出行为意图（本仓库约定 `scenario_expectedBehavior` 命名）。

## 小结
分层测试是架构稳定的护城河。第 15 章我们把这些能力组装到示例应用里。
