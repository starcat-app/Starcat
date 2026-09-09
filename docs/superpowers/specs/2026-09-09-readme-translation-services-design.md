# README 翻译服务（非 AI + 菜单聚合）设计

> 日期：2026-09-09  
> 状态：已确认，进入实现  
> 范围：MVP A（系统翻译 + 菜单聚合 AI；外接 MT 二期）

## 1. 问题

现有 README 翻译仅走 AI（BYOK），延迟高。需要可切换的非 AI 引擎，同时保留 AI 路径与既有分段/全文能力。

## 2. 产品决策（已确认）

| 项 | 决策 |
|----|------|
| 门控 | 一期不做 Pro/Free 区分 |
| 设置分区 | AI 配置留在「AI 服务」；新建「翻译服务」配系统翻译与默认引擎 |
| 详情菜单 | 「翻译服务」组聚合**当前可用**引擎（含 AI）；未配置/不可用则不展示 |
| 切换写回 | 菜单切换引擎写回 `AppSettings`，非一次性覆盖 |
| 切引擎是否自动重译 | 否；靠主按钮 /「重新翻译」 |
| MVP 引擎 | 系统翻译（Apple Translation）+ AI；不做 Google/阿里/百度 UI |

## 3. 详情页下拉菜单（已确认）

```text
[ 翻译 / 原文 ]  [ ▾ ]
                    ├─ 翻译服务          ← 仅 availableEngines()
                    │   ├─ 系统翻译
                    │   └─ AI 翻译       ← 配置仍在 AI 设置
                    ├─ 翻译方式
                    ├─ 目标语言
                    └─ 重新翻译
```

主按钮使用设置中当前选中引擎。

## 4. 架构

```text
WebView 抽段 / 模式 / 语言 / 磁盘缓存 / DOM 回填  —— 复用
                         ↓
              settings.readmeTranslationEngine
                 ├─ .system → SystemTranslationBackend
                 └─ .ai     → 现有 AI 批处理路径
```

### 4.1 引擎枚举

```swift
enum ReadmeTranslationEngine: String, CaseIterable, Codable, Sendable {
    case system
    case ai
    // 二期：google / aliyun / baidu
}
```

持久化键：`settings.readme.translation.engine.v1`（名称以实现为准）。

### 4.2 可用性

`ReadmeTranslationEngineAvailability.availableEngines(target:)`：

- `.system`：目标语种在 `LanguageAvailability` 下非 `.unsupported`（需下载仍可出现，首次触发系统下载）。
- `.ai`：翻译任务 Provider + API Key + 模型可解析（与现 `makeClient` 前置条件对齐）。

若当前默认引擎不在可用列表：回落到第一个可用项并写回设置；全无则主按钮不可用并提示。

### 4.3 缓存隔离

`ReadmeTranslation.model`（或等价字段）写入：

- 系统：`system`
- AI：`ai:<providerModel>`（可保持现有 model 字符串，但查找/落盘路径须含引擎，避免互踩）

同一 owner/repo/language/mode 下，不同引擎分文件或分目录，禁止覆盖。

### 4.4 系统翻译行为

- 框架：Apple `Translation`（macOS 15+）。
- 会话：优先通过 SwiftUI `.translationTask` 获取 `TranslationSession`（以便未安装语言包时弹出系统下载授权）；已安装可用 `installedSource:target:` 作补充。
- 切批：复用 `makeBatches`（首批小、后续略大）；系统侧不强行 4 路多 session。
- 同语种跳过：继续 `TranslationSourceLanguageGate`。
- 取消 / 切仓：复用 VM generation 守门。

### 4.5 设置页

新建「翻译服务」侧栏（或等价一级页）：

- 默认引擎 Picker（`availableEngines`）
- 系统翻译说明（on-device、可能下载语言包）
- 不包含 AI 密钥 / Prompt（深链可「前往 AI 设置」）

## 5. 非目标（一期）

- Google / 阿里 / 百度实现与设置壳
- 将 AI 配置迁入翻译服务页
- 改 `功能实现总览.md`（须 dong4j 另行确认）
- 通知详情翻译引擎切换（可复用后端，UI 二期对齐）

## 6. 测试要点

- `availableEngines`：无 AI 配置时无 AI；system unsupported 时无 system
- 缓存：system 与 ai 互不覆盖
- 切仓：系统翻译进行中切仓不写错页
- 菜单：不可用引擎不出现

## 7. 二期预留

在引擎枚举与 Backend 协议上预留外接 MT；设置页增加 BYOK 表单；菜单自动纳入已配置外接项。
