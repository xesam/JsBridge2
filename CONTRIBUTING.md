# 贡献指南

感谢关注 JsBridge2！本项目的核心约束是**跨端协议一致性**——任何贡献都需要遵循这一原则。请先阅读 [AGENTS.md](AGENTS.md)（工程约定总纲）与 [docs/01-design-principles.md](docs/01-design-principles.md)（五条设计原则）。

## 开发环境

| 平台 | 依赖 |
|------|------|
| WebAssets（必须） | Node.js 20+ · pnpm 9+ |
| Android | JDK 17+（AGP 8.5 构建；库产物为 Java 8 语言级别） |
| iOS | Xcode 16+ / Swift 6（macOS） |
| Flutter | Flutter SDK（Dart 3.11+） |
| HarmonyOS | DevEco Studio 4.0+（可选，无 SDK 时相关测试自动跳过） |

首次 clone 后必须先构建并同步 JS SDK（四端 WebAssets 不纳入版本控制）：

```bash
cd web-assets && pnpm install && pnpm sync && cd ..
```

## 开发工作流

```bash
# 修改任何 web-assets/packages/ 下的内容后，重新构建并同步四端：
cd web-assets && pnpm sync

# 一键验证（四端 + WebAssets + JS conformance）：
scripts/test_all.sh

# 单端验证：
cd js_bridge_android && ./gradlew :js-bridge-core:test
swift test --package-path js_bridge_ios/js-bridge-core-swift
cd js_bridge_flutter/packages/js_bridge_core && flutter test
```

## 跨端变更规则（最重要）

1. **协议契约变更必须四端同步**。修改消息信封、策略链、错误码语义、握手契约前，先更新 `docs/03-protocol.md` / `docs/02-architecture.md`，再同步四端实现。
2. **WebAssets 变更后必须 `pnpm sync`**，再跑 `pnpm check` 验证四端一致。
3. **新增 conformance 用例必须四端同落地**（Native core 用例加进四端 `ConformanceCoreBaseline*` 测试；JS client 用例改 `bridge-client-conformance.cases.js` 四份副本——由 `pnpm check` 保证互比一致）。
4. 详细的变更影响评估清单见 [docs/04-cross-platform.md §9](docs/04-cross-platform.md)。

## 代码规范

- Android：Java 8，包根 `io.github.xesam.android.bridge`，JUnit4；测试方法命名 `scenario_expectedBehavior`。
- iOS：遵循 Swift API Design Guidelines；公共 API 变更须向后兼容。
- Flutter：遵循 Dart style guide；文件名 `snake_case`。
- HarmonyOS：Stage model；遵守 ArkTS 语法限制（不使用 `any` / 动态特性）。
- TypeScript（web-assets）：4 空格缩进；构建产物经 Babel **只降语法、不补 polyfill**——两份产物中仅 IIFE bundle 转译至 ES5，其运行时依赖 `Promise` / `WeakMap` / `Map` / `Symbol` / `MessagePort` 等 ES6+ 运行时 API（ESM 产物保留现代语法、由消费者的打包器负责降级）。缺 API 的旧环境由宿主自备 polyfill——本项目刻意不往产物中注入任何 polyfill（兼容矩阵见 `web-assets/packages/sdk/README.md`）。

## Commit 规范

Conventional Commits 格式：`feat(scope): ...` / `fix(scope): ...` / `docs: ...`，scope 取值见 [AGENTS.md](AGENTS.md)。

## 提交 PR 前检查清单

> **当前阶段（MVP 预览）未启用 CI**，PR 验证以本地 `scripts/test_all.sh` 为准；环境不全时对应项会以 SKIP 跳过（退出码 125），请在 PR 描述中注明跳过项。

```
[ ] 是否修改了消息信封 / 策略链 / 错误码语义？  → 是：先改文档，四端实现 + conformance 同步
[ ] 是否修改了 web-assets/packages/？           → 是：pnpm sync 后提交
[ ] 是否新增 conformance 用例？                 → 是：编号先在 docs/09 §3 登记（编号规则见其 §6.2），四端同步落地
[ ] scripts/test_all.sh 全绿（或说明跳过项）？
[ ] 对应平台的单元测试通过？
```

## 报告问题

提交 issue 时请附上：平台与版本、`SecurityConfig` 级别（Level 0/1/2）、可复现的消息信封（JSON）与期望行为。安全问题请勿公开讨论，请通过 GitHub Security Advisories（仓库 Security 标签页 → Report a vulnerability）私密报告。
