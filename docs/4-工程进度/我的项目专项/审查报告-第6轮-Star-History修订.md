# 我的项目专项审查报告：第 6 轮 Star History 修订

> 审查日期：2026-07-29
>
> 审查分支：`dev`
>
> 审查范围：GitHub Stargazers 数据链、详情图表、专项设计、验收步骤、checklist、最终复审与结果报告
>
> 结论：**发现 4 项文档一致性问题，需修复后复审**

## 1. 已确认实现

1. GitHub REST 客户端已使用 `application/vnd.github.star+json` 分页读取 `starred_at`，DTO 不解码 Stargazer 用户身份。
2. Star History Repository 已按 `user_projects.authorization_source` 路由 OAuth / GitHub App；项目关系命中后不降级到公共 Discovery。
3. Private / Internal 项目只允许直连 GitHub 并在本机按 UTC 日期聚合；无有效项目凭据时只保留本机 snapshot。
4. UI 已区分 `github_stargazers + reconstructed`，使用独立来源说明和虚线曲线，明确不包含已取消 Star 的用户。
5. 聚焦测试已覆盖 OAuth 两页聚合、GitHub App 私有项目路由、公共 Discovery 零调用和既有 Star History 回归。

## 2. 发现的问题

### R6-01：设计文档验收条目仍使用旧数据源描述

- `14.4 Star History 与隐私` 仍写“Public 项目可以走现有远端历史”，没有明确项目必须优先直连 GitHub。
- 结论第 10 条仍写“Private 项目只使用本机 Star snapshot”，与已授权 GitHub App 可读取 Stargazers 的实现冲突。
- 处理：改为项目按关系凭据直连 GitHub；Private / Internal 仅禁止 Discovery，无凭据时才只显示本机 snapshot。

### R6-02：专项 checklist 仍有两项标记为进行中

- “复用详情与 Star History”及“Private / Internal 不调用 Discovery”仍为 `[~]`。
- 处理：实现与自动化证据确认后改为 `[x]`，补充 OAuth / GitHub App 路由、内存聚合和不保存用户身份的完成说明。

### R6-03：验收步骤仍要求 Private 项目只显示本机 snapshot

- 旧步骤无法验证已授权 GitHub App 的真实 Stargazers 重建路径。
- 处理：拆分“已授权”和“未授权”两种 Private / Internal 验收结果，并增加来源、精度和已取消 Star 边界检查。

### R6-04：最终复审与结果报告未记录本次修订

- 两份收口文档仍只描述公共服务拦截，没有说明项目专属 GitHub Stargazers 数据源。
- 处理：增加 2026-07-29 修订章节，记录实现、测试、提交和剩余人工 Gate；不改写原 worktree 交付历史。

## 3. 修复与验证计划

1. 先同步设计、checklist、验收步骤、最终复审和结果报告。
2. 运行 Star History、User Project、GitHub API 相关聚焦测试。
3. 运行全量单测、Debug build、`.xcstrings` JSON 和 i18n 静态检查。
4. 新增第 7 轮最终一致性复审；若发现问题，继续修复并独立提交。

## 4. 边界

- `docs/功能实现总览.md` 未获得单独写入授权，本轮保持只读且不回填。
- 真实 GitHub App selected repositories、组织审批、VoiceOver 与 Light / Dark 仍是人工验收 Gate，不伪造完成证据。
