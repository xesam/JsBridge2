# JsBridge2 文档导航

本目录包含 JsBridge2 的完整设计文档与实施指南。

> **📖 阅读提示**: 文档聚焦于协议/架构/设计层面,各端具体集成代码请查看各平台项目 README。

---

## 快速开始

各端集成指南位于各平台项目中：

- **Android**: [js_bridge_android/README.md](../js_bridge_android/README.md)
- **iOS**: [js_bridge_ios/README.md](../js_bridge_ios/README.md)
- **Flutter**: [js_bridge_flutter/README.md](../js_bridge_flutter/README.md)
- **HarmonyOS**: [js_bridge_harmony/README.md](../js_bridge_harmony/README.md)

完成集成后,阅读以下文档理解设计思路。

---

## 核心文档（按逻辑层次组织）

### 1. 设计原则与架构

- **[01-design-principles.md](01-design-principles.md)** — 五条设计原则、安全分级模型、配置决策
- **[02-architecture.md](02-architecture.md)** — 分层结构、策略链、安全配置
- **[03-protocol.md](03-protocol.md)** — 消息格式、会话模型、错误码定义
- **[04-cross-platform.md](04-cross-platform.md)** — 四端契约、入口签名、安全边界

### 2. 核心机制详解

- **[05-lifecycle-layers.md](05-lifecycle-layers.md)** — 三层生命周期模型（WebView / Session / Scope）
- **[06-channel-establishment.md](06-channel-establishment.md)** — 信道建立 pull 模型与 reqId 往返
- **[07-transport-bridge-design.md](07-transport-bridge-design.md)** — Transport 抽象与平台适配
- **[08-handler-interface-contract.md](08-handler-interface-contract.md)** — CoreBridge 接口契约规范（Simple/Async handler，四端实现规范）

### 3. 验证与测试

- **[09-conformance.md](09-conformance.md)** — 一致性验收用例（C01–C65；编号登记正本见其 §3，C09/C44 为登记空缺）
- [origin-normalizer-vectors.json](origin-normalizer-vectors.json) — origin 归一化校验向量正本（C54，由 `scripts/check_origin_vectors.sh` 强制四端一致）

---

## 快速导航：按关注点查找

### 我想了解...

| 关注点 | 推荐文档 | 关键章节 |
|--------|---------|---------|
| **快速上手集成** | 各端 README | Android/iOS/Flutter/HarmonyOS 项目 |
| **SPA 应用适配** | 05-lifecycle-layers.md | §0 使用方关注要点 |
| **安全配置（null/完整配置）** | 01-design-principles.md | §2 渐进增强的实际体现（§2.2 策略链装配 / §2.5 安全分级） |
| **错误排查** | 06-channel-establishment.md | §6.2 故障排查（握手超时、通道失效等） |
| **为什么采用 pull 模型** | 01-design-principles.md, 06-channel-establishment.md | §4.1, §1 设计原则 |
| **生命周期分层原因** | 01-design-principles.md | §4.2 生命周期：为什么分三层 |
| **四端 API 对齐规则** | 04-cross-platform.md | §3 协议一致性边界（通道建立入口契约在 §3.1） |

### 我遇到了...

| 症状 | 排查文档 | 关键内容 |
|------|---------|---------|
| 握手超时 | 06-channel-establishment.md §6.2 | 检测容器环境、确认 bind 调用 |
| 路由切换后旧回调仍执行 | 05-lifecycle-layers.md §0.2 | SPA 需要 AbortSignal |
| 后退后通道失效 | 06-channel-establishment.md §5.2 | Bfcache 恢复机制 |
| `__jsbridge2__ is not defined` | 07-transport-bridge-design.md §4.3 | Bootstrap 注入时机 |

---

## 文档关系图

```
01-design-principles (设计原则) ←─┐
    ↓ 被实现                     │
02-architecture (架构)            │
    ↓ 遵循                        │
03-protocol (协议定义)            │ 相互引用
    ↓ 被实现                     │
04-cross-platform (四端契约) ─────┤
    ↓ 应用                        │
05-lifecycle-layers (生命周期) ───┤
    ↓ 依赖                        │
06-channel-establishment (信道) ──┤
    ↓ 使用                        │
07-transport-bridge-design ───────┤
    (Transport 抽象)              │
    ↓ 依赖                        │
08-handler-interface-contract ────┘
    (Handler 契约)

09-conformance (验收用例) ← 覆盖所有设计点
```

---

## 使用方典型路径

### 路径 1：新项目集成（0 → 可用）

1. 选择平台查看集成指南（见上方"快速开始"）
2. 理解安全配置选项 [01-design-principles.md §2.4 推荐配置模式](01-design-principles.md)
3. 运行验收用例 [09-conformance.md](09-conformance.md) 验证集成

### 路径 2：从 null 配置升级到完整安全配置

1. 阅读 [01-design-principles.md §2.5 安全分级](01-design-principles.md) 了解配置要求
2. 参考 [02-architecture.md §4](02-architecture.md) 理解策略链
3. 实施 [04-cross-platform.md §3.2](04-cross-platform.md) 的 PageContextProvider
4. 参考各端 README 的"安全模式"章节配置

### 路径 3：SPA 应用适配

1. 阅读 [05-lifecycle-layers.md §0](05-lifecycle-layers.md) 症状自查
2. 实施 AbortSignal scope 管理（见 §0.1 示例）
3. 运行 C24–C27 验收用例确认

### 路径 4：故障排查

1. 根据症状在上方"我遇到了..."表格查找对应文档
2. 按文档故障排查章节逐项检查
3. 无法解决时带着检查结果提问（控制台日志 + 平台版本）

### 路径 5：理解设计思路（贡献者/深度使用者）

1. [01-design-principles.md](01-design-principles.md) — 为什么这样设计
2. [02-architecture.md](02-architecture.md) — 内部如何组织
3. [03-protocol.md](03-protocol.md) — 协议细节与约束
4. [04-cross-platform.md](04-cross-platform.md) — 四端如何保持一致

---

## 版本说明

所有文档基于协议版本 **v1** 编写（2026-09 更新），适用于 Android / iOS / Flutter / HarmonyOS 四端。个别文档另标注自身修订版本（如 [08-handler-interface-contract.md](08-handler-interface-contract.md) 的"规范版本： v1.1"），指该文档自身的修订号，与协议版本 v1 是两个维度。

---

## 贡献指南

文档修改请遵循以下原则：

1. **使用方视角优先** — 先说"什么时候需要关心"，再说"是什么"
2. **症状自查先行** — 故障排查章节提供症状-原因对照表
3. **避免过早优化** — 默认场景说"无需关心"，不要强制用户理解不需要的细节
4. **时效性清晰** — 正文只保留最终方案，不保留论证过程与历史记录
5. **跨文档一致性** — 术语、错误码、用例编号保持统一
6. **集成代码正本在各端 README** — docs/ 内代码块限于契约签名、协议消息示例与论证所需的最小示意；可拷贝的完整集成代码只存在于各平台项目 README，docs 与 README 不重复维护同一段代码（四端差异对照可保留，如 04 §7）

文档结构变更需同步更新本导航文件。
