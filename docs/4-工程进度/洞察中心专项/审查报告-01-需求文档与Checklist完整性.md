# 审查报告 01：需求、文档与 Checklist 完整性

> 审查时间：2026-07-27
>
> 审查状态：已完成首轮检查，存在 1 个待修复 finding
>
> 审查基线：Starcat `addeaa0b`；`starcat-discovery-api` `0a107d2`

## 1. 审查范围

- 两张原型与 49 / 50 号详细设计。
- 洞察中心专项 Checklist、需求追踪矩阵和验收步骤。
- 洞察顶级入口、我的洞察、仓库洞察与 Star 趋势的生产代码。
- 首期区块、非目标、Mock 残留和空壳入口。

## 2. 结论

信息架构、首期区块和非目标已落地，未发现独立 Dashboard、重复 Star History Sheet、Traffic 指标或空壳入口。发现 1 个 P2 一致性问题：真实 Provider 已接入后，生产 target 和测试 target 仍保留整套前端 Mock 数据代码与过时说明。

M0 真实 BigQuery 验证、部署和完整人工 UI 矩阵属于已声明的外部授权 / 人工门槛，不计为本轮实现缺失，也不得伪造完成。

## 3. Findings

### R01-F01：真实数据接入后仍保留前端 Mock 生产代码与契约测试

- 等级：P2
- 状态：待修复
- 证据：
  - `Starcat/Features/Insights/InsightsMockData.swift` 仍编入生产 target，但已经没有运行时调用方。
  - `Starcat/Features/Insights/InsightsNavigationViews.swift` 仍定义未使用的 `MockDataBadge`。
  - `StarcatTests/InsightsMockDataTests.swift` 只验证已废弃演示数据，而非真实 Provider。
  - `InsightsModels.swift` 文件头仍称“首阶段由 Mock provider 供数”。
  - `验收步骤说明.md` 仍要求检查“Mock 说明”，需求追踪矩阵仍把 `InsightsMockDataTests` 作为 INS-01 自动化证据。
- 风险：后续维护者可能误以为 Mock 仍是正式回退路径；无调用的演示代码继续扩大生产 target，并让“已移除演示数据”的 Checklist 与仓库事实不一致。
- 修复要求：
  1. 删除生产 Mock 文件、未使用 Badge 与对应废弃测试。
  2. 更新模型注释、验收步骤和需求追踪矩阵，只保留历史截图作为视觉基线。
  3. 运行 `xcodegen generate`、洞察定向测试、Debug build 和 `git diff --check`。
- 修复 commit：待回填
- 验证结果：待回填

## 4. 无问题项

- 洞察继续使用 Starcat 三栏框架。
- 仓库洞察位于 `ManageDetailContent`，没有改写 `RepoDetailScaffold` 场景职责。
- Star 趋势没有独立 Hero action、Sheet 或第四种详情模式。
- PR / Issue / Commit、贡献者、Health、社区、安全和最近活动均有真实数据层。
- 49 / 50 号文档已区分代码完成、M0、部署与人工验收边界。
- `docs/功能实现总览.md` 与四份 Changelog 均未修改。

## 5. 下一步

本报告提交后，按 R01-F01 单独修复并提交；验证通过后再回填本报告的 commit、命令与关闭结论。
