# AI 用量统计面板专项 Checklist

> 状态: 已完成
> 创建: 2026-07-19
> 基线: `dev@59067156`
> 实施分支: `codex/ai-usage-dashboard`
> Worktree: `/Users/dong4j/Developer/1.AI/ai-incubator/Starcat-ai-usage-dashboard`

## 1. 目标

为 Starcat 建立本地优先的 AI 用量统计闭环，统一记录 Chat、流式 Chat 与 Embedding 请求的调用次数和 token 用量，并提供精美、可筛选、可追溯的 macOS 原生统计面板。

## 2. 产品与数据边界

- [x] 主入口放在全局状态 popover，提供今日 token / 调用次数摘要，并可打开独立统计窗口。
- [x] 辅助入口放入全局 Actions 菜单，避免用户必须记住状态图标入口。
- [x] 不在主 Sidebar 增加长期占位，不把完整统计页面塞入设置页。
- [x] 统计维度覆盖时间、功能、Provider、模型、请求状态与 token 数据来源。
- [x] 分别展示输入、输出、总 token 与调用次数；缓存输入属于输入子集，推理 token 属于输出子集，不重复计入总量。
- [x] 单次 HTTP 推理请求计为一次调用；批量 Embedding 额外记录 item 数量。
- [x] Provider 未返回 usage 时保留“不可用”，不伪装成 0；明确区分精确值、估算值和不可用值。
- [x] 数据仅保存在本地 SQLite，不进入 CloudKit。
- [x] 不记录 prompt、response、API Key、Base URL 或完整错误文本。
- [x] 本期不计算金额，不回填版本发布前的历史用量。

## 3. 数据与采集

- [x] 新增 `v14-ai-usage-events` 数据库迁移、索引和已发布数据库升级测试。
- [x] 新增用量事件领域模型、功能 / 阶段 / 状态 / 来源枚举及 GRDB Repository。
- [x] 为非流式 Chat 接入 Provider 精确 usage 采集。
- [x] 为流式 Chat 请求 usage，并在正常结束时采集；中断或不兼容 Provider 不影响原调用结果。
- [x] 为 Embedding 接入 usage 与批量 item 数采集。
- [x] 将 RAG 规划、查询向量、回答、标题、压缩等阶段映射到稳定功能维度。
- [x] 将知识库索引、语义搜索、Repo AI、README 翻译、Agent 与 MCP 调用映射到稳定功能维度。
- [x] 成功、失败、取消请求均记录调用事件，错误仅落枚举分类。

## 4. 查询与展示

- [x] 新增 Today / 7 天 / 30 天 / 全部时间范围查询和功能 / Provider / 模型筛选。
- [x] 新增总览指标：总 token、输入 token、输出 token、API 调用次数、Embedding item 数、可用率。
- [x] 新增按日趋势图，区分输入 / 输出 token，并显示调用次数。
- [x] 新增功能分布与模型分布，支持从图表联动筛选明细。
- [x] 新增最近调用明细，展示时间、功能、模型、状态、耗时、token 与 usage 来源。
- [x] 新增独立 AI 用量窗口，支持空态、加载态、错误态、明暗主题和窗口尺寸恢复。
- [x] 全局状态 popover 增加紧凑摘要与跳转入口。
- [x] 全局 Actions 菜单增加“AI 用量”入口。
- [x] 完成 en / zh-Hans 国际化与辅助功能标签。

## 5. 文档、测试与验收

- [x] 新增 AI 用量统计面板详细设计文档，记录语义、隐私、迁移与扩展边界。
- [x] 新增数据迁移、Repository 聚合、usage 映射和 ViewModel 单元测试。
- [x] 新增人工验收步骤，覆盖真实 Provider、无 usage Provider、失败 / 取消、筛选和主题切换。
- [x] 运行专项单测、全量单测、静态规范检查和 `git diff --check`。
- [x] 只读核对 `docs/功能实现总览.md`；未获得单独授权时仅在报告中给出拟同步内容。

## 6. 多轮审查

- [x] 第一轮：代码架构、数据库迁移与隐私边界审查；先提交报告，再修复发现。
- [x] 第二轮：功能完整性、UI 契约与国际化审查；先提交报告，再修复发现。
- [x] 第三轮：单元测试、失败路径与性能审查；先提交报告，再修复发现。
- [x] 第四轮：文档、工程进度、Checklist 与提交历史一致性复审；先提交报告，再修复发现。
- [x] 全部问题关闭后新增最终复审报告和结果报告。

## 7. 提交约束

- [x] 基于当前 `dev` 创建独立 worktree 与 `codex/ai-usage-dashboard` 分支。
- [x] 每完成一个小功能提交一次，commit message 使用中文。
- [x] 不 push。
- [x] 不带入原 `dev` 工作区的未提交改动。
- [x] 最终 Checklist 全部回填并保持工作区 clean。
