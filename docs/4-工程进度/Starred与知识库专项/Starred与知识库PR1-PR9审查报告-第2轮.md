# Starred 与知识库 PR1-PR9 审查报告 - 第2轮

> 日期: 2026-07-03
> 范围: 第1轮修复后的 PR-1 到 PR-9 复查。
> 结论: 第1轮发现的未登录入口与 PR-5 测试证据已修复；剩余主要缺口集中在不可访问 repo 状态承载与人工验证回填。

## 1. 已复查的修复

- 未登录态详情页与 Search Center 的知识库 ❤️ 已隐藏，写入入口不再暴露。
- `SemanticIndexScope.selectCandidates(...)` 已作为 starred / knowledge / all 候选范围的单一分派函数。
- `SemanticIndexingTests` 已覆盖 starred、knowledge、all 三种候选范围。
- Discovery 详情页 ❤️ 由 `RepoDetailScaffold` 统一渲染，已登录且 repo id 有效时覆盖 Discovery / Trending / Weekly / Activity / Manage。
- 单仓 AI 摘要入口没有按知识库状态拦截，未入库 repo 仍可显式生成摘要；未 star 时只关闭标签建议。

## 2. 新增发现

### B1. PR-2 不可访问 repo 缺少稳定本地状态承载

正式方案和详细设计要求 GitHub 404/410/权限不足的已入库 repo 仍留在知识库集合，并在 UI 标记不可访问/已失效。当前 `Repo` 模型和 `repos` 表只有 `is_private`、`is_archived`、`is_starred`，没有 `accessStatus` / `unavailableReason` 一类字段；Smart Collections 的卡片也只能展示 archived/fork/health/status 等已有状态。

影响: “仍显示”由 `fetchKnowledgeRepos()` 可以满足，但“标记不可访问/已失效”没有可维护的数据来源，不能只靠 UI 猜测。

建议修复: 增加本地 repo 访问状态字段与 Repository 更新方法，并在明确的远程失败路径写入；Smart Collections/详情卡片按该字段展示“不可访问/已失效”标记。

### B2. PR-1 README 无缓存且权限不足不是空状态，但缺少专门权限态

`ReadmeViewModel` 在无缓存且 refresh 失败时进入 `.error(message:)`，不会进入 `.empty`，因此“不伪装成空 README”成立。但当前没有专门的 `.unavailable` / `.permissionDenied` 状态，UI 展示的是通用错误消息。

处理建议: checklist 可按“不伪装成空 README”回填；如果产品要求明确文案“权限不足/内容不可用”，需要另拆 UI 状态细化。

### B3. “只有显式清除才删除用户私有知识库数据”缺少 checklist 回填

现有登出/切账号路径没有删除 `repo_notes`、tags、status、library state；进度文档中账号隔离和重新登录恢复已勾选，但“只有显式清除本地数据 / 删除账号数据才删除”仍未勾选。该项属于文档回填，不是新增代码缺口。

### B4. §2 不做范围仍为未勾选

§2 是本专项明确不做范围，当前仍是 `[ ]`。为了让审计状态清晰，应改为 `[x]` 表示这些边界已经确认并遵守，而不是待开发功能。

### B5. 人工验证项仍应保持未勾选

§11 中大量 UI 视觉和离线/权限场景需要真实 App 或构造环境验证。没有人工执行前不应批量勾选。可回填的只限于有自动化测试或代码证据的条目。

## 3. 下一步修复清单

- 回填 B2/B3/B4 对应 checklist 与变更记录。
- 对 B1 做最小设计与实现: 增加 repo 访问状态承载、Repository 写入/查询测试、Smart Collections 标记。
- B1 完成后新增第3轮审查报告，继续核对 PR-1 到 PR-9 是否还有代码/文档不一致。
