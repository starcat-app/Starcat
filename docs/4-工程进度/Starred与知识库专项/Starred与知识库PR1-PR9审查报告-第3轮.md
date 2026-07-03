# Starred 与知识库 PR1-PR9 审查报告 - 第3轮

> 日期: 2026-07-03
> 范围: 第2轮修复后的 PR-1 到 PR-9 复查。
> 结论: 代码与自动化测试层面的缺口已补到当前可验证范围；剩余未勾选项分为 JSON 延期、真实人工验证、以及需要全局网络状态能力的离线边界。

## 1. 已完成复查

- PR-1: 未登录态知识库写入入口已隐藏；本地已有 repo 的入库/移出只写本地数据库，不依赖 GitHub 请求。
- PR-2: `repos.access_state/access_reason/access_checked_at` 已作为不可访问状态承载；Repo Health 手动刷新 `/repos` 遇到 404/401/403/410 会标记 unavailable，成功刷新会恢复 accessible；Smart Collections 卡片显示“不可访问”标记。
- PR-3: Discovery / Trending / Weekly / Activity / Manage 详情页通过 `RepoDetailScaffold` 统一展示 ❤️。
- PR-5: starred / knowledge / all 候选范围已收口到 `SemanticIndexScope.selectCandidates(...)` 并有单测覆盖。
- PR-9: README 预拉、Health/OpenSSF、embedding、知识库导出已在前序提交中补齐，验证记录已回填。

## 2. 保留未勾选项说明

### C1. JSON 导入/导出延期

PR-1 与 §11.8 中 JSON 导入导出相关条目仍保持未勾选。进度文档已有明确延期说明，且用户已确认“JSON 导入导出延迟，备注好即可”。本轮不实施、不伪造完成。

### C2. 人工验证项未伪造勾选

§11 的准备数据、详情页视觉、列表角标、真实离线/权限环境、ShareCard 下拉交互等仍需要运行 App 人工验证。未执行真实人工验证前保持未勾选是正确状态。

### C3. “离线且未落库外部 repo 不能直接加入知识库”需要网络状态基础设施

当前代码没有全局 reachability / offline 状态服务。外部 repo 如果来自 Trending / Discovery / Weekly / Search 的缓存或远端 DTO，详情页可以持有完整 repo metadata 并在点击 ❤️ 时落库；这满足“未 star repo 可入库”，但无法严格区分“当前离线且此前未落库”。要严格满足该条，需要先引入全局网络状态依赖，并在外部未落库 repo 的 ❤️ 入口处按离线状态隐藏或禁用。

建议后续拆一个小任务: `NetworkReachability` 基础设施 + 外部未落库 repo 入库入口离线门控。当前不应把该条勾选。

## 3. 本轮验证

- `rtk jq empty Starcat/Resources/Localizable.xcstrings`
- `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/DatabaseMigrationsV1Tests -only-testing:StarcatTests/RepoRepositoryTests -only-testing:StarcatTests/RepoHealthServiceTests test`

## 4. 结论

PR-1 到 PR-9 的已实施功能、设计文档、专项进度和自动化测试已对齐。后续剩余不应混入本轮实现的项只有 JSON 延期、人工验证，以及需要新增全局网络状态能力的离线未落库边界。
