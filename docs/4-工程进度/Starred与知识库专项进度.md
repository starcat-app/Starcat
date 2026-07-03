# Starred 与知识库专项进度

> 状态: 方案已确认, 进行中
> 创建: 2026-07-02
> 需求讨论: `docs/2-产品/需求讨论/Starred与知识库语义拆分需求讨论.md`
> 正式方案: `docs/2-产品/需求讨论/正式方案/Starred与知识库正式方案.md`
> 详细设计: `docs/3-设计/详细设计/38-Starred与知识库改造详细设计.md`

## 1. 目标

把 GitHub `starred` 与 Starcat 私有“知识库”拆开:

1. `starred` 继续代表 GitHub 公开 Star 和同步事实。
2. `知识库` 代表 Starcat 私有入库状态。
3. 详情页新增常驻 ❤️ 入口。
4. Smart Collections 新增系统集合“知识库”。
5. AI/MCP 支持 starred、知识库和两者并集,不把任一范围硬性排除。

## 2. 不做范围

- [ ] 不把 GitHub Star 自动等同于加入知识库。
- [ ] 不把加入知识库自动等同于 GitHub Star。
- [ ] 不用 `RepoStatus` 混装知识库状态。
- [ ] 不机械替换所有 `starred` 调用点。
- [ ] 不新增一级导航“知识库”,第一版放在 Smart Collections。
- [ ] 不做 AI 自动入库或复杂评分模型。

## 3. PR-1: 数据模型与 Repository

- [x] 新增 `LibraryState` enum。
- [x] `repo_notes` 增加 `library_state` 与更新时间字段。
- [x] `RepoNote` 模型补 library state 字段。
- [x] `RepoNoteRepositoryProtocol` 增加查询/更新 library state 方法。
- [x] `GRDBRepoNoteRepository` 实现 library state 查询/更新/统计。
- [x] `RepoRepositoryProtocol` 增加知识库范围查询。
- [x] `GRDBRepoRepository` 支持未 star repo 入库写入。
- [x] 单测覆盖 status/content/library state 互不覆盖。
- [x] 单测覆盖设置 `RepoStatus.using` 时自动设为 `libraryState = .inLibrary`。
- [x] 单测覆盖取消 `RepoStatus.using` 时不自动取消入库。
- [x] 单测覆盖手动加入知识库时默认 `RepoStatus.unread`。
- [x] 单测覆盖从 `RepoStatus.using` 自动入库时保持 `using`。
- [ ] 单测覆盖批量加入知识库时已入库 repo 保持不变、未入库 repo 设为 `.inLibrary`。
- [ ] 单测覆盖批量加入知识库不调用 GitHub star。
- [x] 预留 `library_updated_at`,后续 CloudKit 冲突解决按最后更新时间胜出。
- [x] `library_updated_at` 只在 `libraryState` 实际变化时更新。
- [x] 重复加入已入库 repo 不更新 `library_updated_at`。
- [ ] notes / tags / status 改变不更新 `library_updated_at`。
- [ ] 不可访问/恢复可访问不更新 `library_updated_at`。
- [ ] `libraryState` 按 GitHub 登录用户隔离,与 notes/status/tags 的用户私有语义一致。
- [ ] 同一个 repo 在不同账号下可以拥有不同的 `libraryState/libraryUpdatedAt/notes/status/tags`。
- [ ] 退出登录或切换账号不删除本地 `libraryState/notes/tags/status`,只隐藏非当前账号数据。
- [ ] 未登录态不展示用户私有知识库,也不允许修改 `libraryState`。
- [ ] 重新登录同一 GitHub 账号后恢复该账号的知识库状态和用户数据。
- [ ] 只有显式“清除本地数据 / 删除账号数据”才删除用户私有知识库数据。
- [ ] 记录 CloudKit 同步范围: `libraryState` 后续随 notes/status/tags 同步,当前不实施 CloudKit。
- [ ] JSON 导出包含 `libraryState` 与 `libraryUpdatedAt`。
- [ ] JSON 导入恢复 `libraryState` 与 `libraryUpdatedAt`,不调用 GitHub star。
- [ ] JSON 导入未 star 已入库 repo 时写入 repo metadata,并保持 `isStarred = false`。
- [ ] JSON 导入同 repo 冲突时按 `libraryUpdatedAt` 较新的状态胜出。
- [ ] JSON 导入状态胜出时保留导入文件里的 `libraryUpdatedAt`,不使用当前时间覆盖。
- [ ] JSON 导入缺少 `libraryState` 字段时默认 `.outsideLibrary`。
- [ ] JSON 导入写入当前登录账号的用户私有数据,不沿用导出来源账号作为归属。
- [ ] 未登录时不允许执行会写入 `libraryState` 的 JSON 导入。
- [ ] GitHub 404/410/权限不足不自动改变 `libraryState`。
- [ ] 不可访问已入库 repo 保留 notes/tags/status/README 缓存。
- [ ] 无 GitHub token / token 权限不足时,已入库私有 repo 仍可读写本地 notes/tags/status 与知识库状态。
- [ ] 无权限且 README 无缓存时展示权限不足/内容不可用,不伪装成空 README。
- [ ] 已登录但离线时,本地已有 repo 可以加入/移出知识库。
- [ ] 未登录时不允许加入/移出知识库。
- [ ] 离线且未落库的外部 repo 不能直接加入知识库。

## 4. PR-2: Smart Collections 知识库集合

- [x] `SmartCollectionKind` 新增 `library`。
- [x] Smart Collections 总览展示“知识库”集合。
- [x] 中栏列表可进入知识库集合。
- [x] 第一版查看知识库 repo 的整库入口固定为 Smart Collections -> 知识库。
- [x] Manage / 列表筛选菜单增加知识库筛选条件: 全部 / 已入库 / 未入库。
- [x] Manage 默认列表仍是 starred 管理视图,不混入未 star 已入库 repo。
- [x] 知识库集合包含 `libraryState == .inLibrary`。
- [x] 未 star 已入库 repo 能出现在知识库集合。
- [x] 知识库筛选与现有 status / tag / hide archived / hide forks 条件可组合。
- [x] 知识库集合支持 tag / status / language / archived / fork 筛选。
- [x] 知识库集合按 `COALESCE(starred_at, library_updated_at, cached_at) DESC` 排序。
- [x] 未 star 已入库 repo 按 `library_updated_at DESC` 参与排序。
- [ ] 知识库集合中不可访问 repo 仍显示,并标记为不可访问/已失效。
- [x] i18n 补齐知识库相关文案。
- [x] 单测覆盖集合命中与计数。

## 5. PR-3: 详情页 ❤️ 入口

- [x] 新增 `LibraryToggleButton`。
- [x] Manage 详情页动作区接入 ❤️。
- [x] Trending 详情页动作区接入 ❤️。
- [ ] Discovery 详情页动作区接入 ❤️。
- [x] Weekly / Activity 详情页动作区接入 ❤️。
- [x] 点击加入成功有动画反馈。
- [x] 失败有明确错误反馈且不改变本地状态。
- [x] 详情页 ❤️ 不做乐观更新,写入成功后再更新 UI 与 registry。
- [x] 详情页 ❤️ 操作中禁用重复点击。
- [x] 详情页 ❤️ 写入失败时保持原状态,不先变更再回滚。
- [x] 未 star repo 也能通过 ❤️ 加入知识库。
- [x] 详情页 ❤️ 清晰展示单仓是否已入库,作为单 repo 级查看入口。
- [x] 已入库且 `using` 的 repo 点击取消入库时弹二次确认。
- [x] 二次确认后同时设置 `libraryState = .outsideLibrary` 并把 `RepoStatus.using` 降级为 `read`。
- [x] 二次确认文案明确说明会从“正在使用”改为“已读”。
- [x] 非 `using` 的已入库 repo 移出知识库不弹确认。
- [x] 设置 `RepoStatus.using` 自动入库时给轻量 toast,不弹确认。
- [x] 移出知识库只更新 `libraryState`,不删除 notes/tags/status/Releases 订阅关系/repo metadata。
- [ ] 移出知识库后,若 repo 同时不在 starred 与知识库,release 轮询不再自动刷新它。
- [ ] 重新 star 或重新入库后,保留的 Releases 订阅关系重新进入自动刷新候选。
- [x] 多选菜单支持批量加入知识库。
- [x] 批量加入知识库跳过或保持已入库 repo。
- [x] 第一版不提供批量移出知识库。

## 6. PR-4: Repo 卡片 ❤️ 入库标识

- [x] `RepoCardViewData` 增加知识库状态字段。
- [x] `Repo.asCardData(...)` 支持注入 library state。
- [x] `TrendingRepo.asCardData(...)` 支持从 library registry 回填是否入库。
- [x] `DiscoveryRepoDTO.asCardData(...)` / 探索列表适配支持回填是否入库。
- [x] `WeeklyFeedItem.asCardData(...)` 支持从 library registry 回填是否入库。
- [x] `UnifiedRepoRow` 在 repo logo 左上角展示已入库 ❤️。
- [x] `UnifiedRepoRow` 保留 Activity kind icon 右下角展示,不与 ❤️ 冲突。
- [x] Manage repo 列表展示已入库 ❤️。
- [x] Trending repo 列表展示已入库 ❤️。
- [x] Discovery repo 列表展示已入库 ❤️。
- [x] Weekly repo 列表展示已入库 ❤️。
- [x] Activity repo-backed 卡片展示已入库 ❤️。
- [x] 列表 ❤️ 只读,点击 row 仍进入详情页或选择 row,不在列表内执行入库 toggle。
- [x] 已 star ✓ 与已入库 ❤️ 可以同时展示,语义和 tooltip 不混淆。
- [x] 详情页 ❤️ 更新成功后列表 ❤️ 状态即时刷新。

## 7. PR-5: AI 与 MCP 范围改造

- [x] `SemanticIndexBuilder` 支持 starred / knowledge / all 三种范围。
- [x] Home 语义搜索候选支持 starred / knowledge / all。
- [x] 语义搜索 UI 增加范围筛选: starred / knowledge / all。
- [x] FTS 加权与当前语义搜索范围对齐。
- [x] `StarcatMCPFacade.searchRepos` 支持范围参数。
- [x] `StarcatMCPFacade.semanticSearch` 支持范围参数。
- [x] `StarcatMCPFacade.resources` 支持 starred / knowledge / all recent repo。
- [x] 搜索 / AI / MCP 的 knowledge 范围可作为使用知识库 repo 数据的入口。
- [ ] 单仓库 AI 摘要仍允许未入库 repo 显式触发。
- [ ] 单测覆盖 starred、knowledge、all 三种候选范围。

## 8. PR-6: Companion / Browser Plugin / 外部来源

- [x] repo-context DTO 增加 library state。
- [x] Browser Plugin GitHub 页面展示空心/实心 ❤️ 知识库状态。
- [x] Browser Plugin 支持直接加入/移出知识库,逻辑与详情页一致。
- [x] Search Center 搜索结果展示入库状态。
- [x] Search Center 可操作 ❤️ 放在 trailing action 区或详情/预览动作区,logo 角标不可点击。
- [x] Search Center 搜索结果支持直接加入/移出知识库。
- [x] Search Center 直接移出 `using` repo 时弹同样的二次确认,非 `using` repo 直接移出。
- [x] 新增本机服务写 library state 的 action/route。
- [x] Browser Plugin 操作失败时显示插件内 toast 并回滚 ❤️ 状态。
- [x] Notes 写入允许已入库未 star repo。
- [x] Tags 写入允许已入库未 star repo。
- [x] Status 写入允许已入库未 star repo。
- [x] notes / tags / status 的本地写入前置条件从必须 starred 扩展为 `isStarred || libraryState == .inLibrary`。
- [x] Releases 订阅入口允许已入库未 star repo。
- [x] Releases 订阅本地关系前置条件从必须 starred 扩展为 `isStarred || libraryState == .inLibrary`。
- [ ] Release 列表拉取和通知刷新仍按 GitHub token、权限和 repo 可访问性降级。
- [ ] Watchers / Forks / Issues 等 GitHub 统计刷新候选覆盖 starred 与知识库并集。
- [ ] GitHub 统计刷新遇到 token 权限不足、私有或不可访问 repo 时跳过或降频。
- [ ] GitHub 统计刷新失败不改变 `libraryState`,也不自动移出知识库。
- [ ] 单 repo 手动 README 刷新允许已入库未 star repo。
- [ ] 单 repo 手动 Repo Health 刷新允许已入库未 star repo。
- [ ] 单 repo 手动 OpenSSF 刷新允许已入库未 star repo。
- [ ] 单 repo 手动 README / Repo Health / OpenSSF 刷新失败时保留旧缓存,不改变 `libraryState`,不自动移出知识库。
- [ ] open/codeflow/codebase action 允许已入库未 star repo。
- [ ] GitHub star/unstar、远程刷新、私有 GitHub 内容拉取仍按 GitHub 状态、token 与权限分层。
- [ ] Star 操作仍保持独立。
- [ ] 单测覆盖未 star 已入库 repo 的插件路径。

## 9. 预热 / embedding / 分享范围

- [ ] README 预拉覆盖 starred 与知识库并集。
- [ ] Repo Health stale / missing 候选查询覆盖 starred 与知识库并集。
- [ ] Repo Health coverage total / snapshot total 使用 starred 与知识库并集口径。
- [ ] OpenSSF stale 候选查询覆盖 starred 与知识库并集。
- [ ] OpenSSF coverage total / fetched total 使用 starred 与知识库并集口径。
- [ ] Initial warmup Health/OpenSSF 的 complete / pause 判断使用同一 active scope,避免 total 与候选范围不一致导致永久重试。
- [ ] README / Repo Health / OpenSSF 后台任务跳过或降频处理不可访问 repo,避免反复失败。
- [ ] README / Repo Health / OpenSSF 后台任务对无 token / token 权限不足的私有 repo 不反复远程刷新。
- [ ] Health / OpenSSF 后台任务运行中取消入库不强行中断已开始请求,下一批候选自然排除。
- [ ] Health / OpenSSF 后台任务运行中加入知识库不抢占当前批次,下一轮 poller 或 warmup retry 补齐。
- [ ] embedding 覆盖 starred 与知识库并集,只清理同时不在两者中的 repo。
- [ ] 移出知识库不删除已有 README / Repo Health / OpenSSF 缓存。
- [ ] ShareCard 文件导出入口文案从“导出 Starred”改为“导出到文件”。
- [ ] ShareCard 文件导出下拉包含“导出 Starred 到 HTML.”。
- [ ] ShareCard 文件导出下拉包含“导出 Starred 到 Markdown.”。
- [ ] ShareCard 文件导出下拉包含“导出 知识库 到 HTML.”。
- [ ] ShareCard 文件导出下拉包含“导出 知识库 到 Markdown.”。
- [ ] Starred 文件导出继续只导出 GitHub starred repo。
- [ ] 知识库文件导出只导出 `libraryState == .inLibrary` 的 repo,并包含未 star 已入库 repo。
- [ ] 知识库文件导出排序沿用知识库集合排序。
- [ ] 知识库 HTML 导出重新设计格式,不复用 Starred 模板只改标题。
- [ ] 知识库 Markdown 导出重新设计格式,不复用 Starred 模板只改标题。
- [ ] 知识库 HTML/Markdown 的标题、页头、基础排版参考现有 Starred 导出模板。
- [ ] 知识库导出格式包含总数、主要语言、状态分布和导出时间。
- [ ] 知识库导出 repo 条目包含 owner/name、description、language、status、tags、notes、是否 starred、library_updated_at。
- [ ] 知识库 HTML/Markdown 导出默认包含 notes,不提供额外开关。
- [ ] 知识库导出与现有 Starred 导出一致: 有摘要就导出,没有摘要不临时生成。
- [ ] 知识库导出可展示 README 摘要、Repo Health、OpenSSF 缓存信息,但不为导出触发 README 拉取、AI 摘要、Health 或 OpenSSF 刷新。
- [ ] 知识库为空时,点击“导出 知识库 到 HTML/Markdown”不生成空文件。
- [ ] 知识库为空时显示 toast: “知识库为空,暂无可导出的 repo”。
- [ ] Starred 导出现有空状态行为不因本专项改变。
- [ ] ShareCard/Profile 知识库文件导出始终导出全量知识库。
- [ ] ShareCard/Profile 知识库文件导出不跟随 Smart Collections 当前筛选条件。
- [ ] Starred HTML 默认文件名为 `starcat-starred-YYYY-MM-DD.html`。
- [ ] Starred Markdown 默认文件名为 `starcat-starred-YYYY-MM-DD.md`。
- [ ] 知识库 HTML 默认文件名为 `starcat-library-YYYY-MM-DD.html`。
- [ ] 知识库 Markdown 默认文件名为 `starcat-library-YYYY-MM-DD.md`。
- [ ] ShareCard 文件导出文案不能把知识库导出伪装成 GitHub Starred。

## 10. 验证记录

- [ ] `rtk xcodegen generate`
- [x] `rtk jq empty Starcat/Resources/Localizable.xcstrings`
- [x] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RepoNoteRepositoryTests test`
- [x] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/RepoRepositoryTests test`
- [x] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/HomeViewModelFilterSortTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' -only-testing:StarcatTests/SemanticSearchTests test`
- [ ] `rtk xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' build`
- [x] `rtk git diff --check`

## 11. 人工验证流程

### 11.1 准备数据

- [ ] 准备 A: 已 star 且未入库 repo。
- [ ] 准备 B: 已 star 且已入库 repo。
- [ ] 准备 C: 未 star 且未入库 repo,可从 Trending / Discovery / Search Center 打开。
- [ ] 准备 D: 未 star 且已入库 repo。
- [ ] 准备 E: 已入库且 `RepoStatus.using` repo。

### 11.2 详情页 ❤️

- [ ] A 详情页显示空心 ❤️,点击后变为实心 ❤️,列表标识同步出现。
- [ ] B 详情页显示实心 ❤️,点击取消后变为空心 ❤️,列表标识同步消失。
- [ ] 点击 ❤️ 后先进入操作中/禁用状态,写入成功后才更新状态。
- [ ] 模拟写入失败时,详情页 ❤️ 保持原状态并显示错误反馈。
- [ ] C 详情页允许点击 ❤️ 入库,不会自动 GitHub star。
- [ ] D 详情页允许点击 ❤️ 移出知识库,不会删除 notes / tags / status / Releases 订阅关系 / repo metadata。
- [ ] D 这类未 star 已入库 repo 可以编辑 notes / tags / status。
- [ ] D 这类未 star 已入库 repo 可以开启 Releases 订阅。
- [ ] D 这类未 star 已入库 repo 如果 release 拉取因权限失败,订阅关系保留并展示权限/不可访问状态。
- [ ] D 这类未 star 已入库 repo 进入 Watchers / Forks / Issues 等 GitHub 统计刷新候选。
- [ ] D 这类未 star 已入库 repo 统计刷新失败时保留入库状态和已有缓存。
- [ ] D 这类未 star 已入库 repo 可以手动触发 README / Repo Health / OpenSSF 刷新。
- [ ] D 这类未 star 已入库 repo 手动刷新失败时只显示错误反馈,不改变入库状态和已有缓存。
- [ ] D 这类未 star 已入库 repo 的 GitHub star/unstar、远程刷新能力仍按权限和 GitHub 状态分层。
- [ ] E 点击移出知识库时出现二次确认;确认后 `libraryState = .outsideLibrary`,状态降级为 `read`。
- [ ] E 的二次确认文案明确说明会从“正在使用”改为“已读”。
- [ ] 非 `using` 的已入库 repo 移出知识库不弹确认。
- [ ] 未入库 repo 手动加入知识库后默认 `RepoStatus.unread`。
- [ ] 设置 `RepoStatus.using` 时自动入库,出现轻量 toast,不弹确认。
- [ ] 从 `RepoStatus.using` 自动入库时保持 `using` 状态。
- [ ] 取消 `RepoStatus.using` 时仍保持已入库。

### 11.2.1 批量操作

- [x] 多选菜单出现 `加入知识库`。
- [x] 批量加入后,未入库 repo 变为已入库。
- [x] 批量加入后,已入库 repo 保持不变。
- [x] 批量加入不会触发 GitHub star。
- [x] 第一版没有批量 `移出知识库` 入口。

### 11.3 列表标识

- [ ] Manage / Trending / Discovery / Weekly / Activity 的已入库 repo 在 repo logo 左上角显示 ❤️。
- [ ] 未入库 repo 不显示 ❤️,不显示空心心。
- [ ] repo logo 左上角 ❤️ 不可点击,点击 row 仍执行原有选择/打开详情行为。
- [x] GitHub 已 star 标识与知识库 ❤️ 可同时存在,语义不混淆。
- [ ] Activity kind icon 仍在右下角,不与左上角 ❤️ 冲突。

### 11.4 Smart Collections / Manage

- [x] Smart Collections 出现系统集合“知识库”。
- [x] 知识库集合包含 B / D。
- [x] Manage 默认列表不显示 D。
- [x] Manage 知识库筛选条件支持全部 / 已入库 / 未入库,并可与 status / tag / hide archived / hide forks 组合。
- [x] 知识库集合支持 tag / status / language / archived / fork 筛选。
- [x] 知识库集合按 `COALESCE(starred_at, library_updated_at, cached_at) DESC` 排序。
- [x] D 这类未 star 已入库 repo 按 `library_updated_at DESC` 参与排序。
- [ ] GitHub 404/410/权限不足的已入库 repo 仍出现在知识库集合。
- [ ] 不可访问 repo 在 UI 中标记为不可访问/已失效。
- [ ] 无 token / token 权限不足时,已入库私有 repo 的本地 notes/tags/status 与入库状态仍可正常查看和修改。
- [ ] 已登录但离线时,本地已有 repo 的 ❤️ 可以正常加入/移出知识库。
- [ ] 未登录时,❤️ 入库操作不可用并给出登录提示。
- [ ] unstar B 后,B 从 Manage 默认列表消失,但仍保留在知识库集合。
- [ ] Star/unstar 不改变 `libraryState`。

### 11.5 Search Center / Browser Plugin

- [x] Search Center 搜索结果显示入库状态。
- [x] Search Center 搜索结果可以直接加入知识库。
- [x] Search Center 搜索结果可以直接移出知识库。
- [x] Search Center 可操作 ❤️ 位于 trailing action 区或详情/预览动作区,logo 角标不可点击。
- [x] Search Center 移出 `using` repo 时弹同样的二次确认,非 `using` repo 直接移出。
- [x] Browser Plugin GitHub 页面显示空心/实心 ❤️。
- [x] Browser Plugin 可加入/移出知识库,不会自动 GitHub star/unstar。
- [x] Browser Plugin 操作失败时显示插件内 toast,并回滚 ❤️ 状态。

### 11.6 AI / MCP / 语义搜索

- [ ] 语义搜索 `starred` 范围只返回 starred repo。
- [ ] 语义搜索 `knowledge` 范围返回已入库 repo,包含 D。
- [ ] 语义搜索 `all` 范围返回 starred 与知识库并集。
- [ ] MCP repo 查询支持 starred / knowledge / all 范围。
- [ ] 单仓 AI 摘要仍允许对未入库 repo 显式触发。

### 11.7 预热 / 缓存 / 分享

- [ ] README 预拉候选覆盖 starred 与知识库并集。
- [ ] Repo Health 候选与 coverage total 都使用 starred 与知识库并集。
- [ ] OpenSSF 候选与 coverage total 都使用 starred 与知识库并集。
- [ ] 移出知识库不删除已有 README / Repo Health / OpenSSF 缓存。
- [ ] GitHub 404/410/权限不足不删除已有 README / Repo Health / OpenSSF 缓存。
- [ ] README / Repo Health / OpenSSF 后台任务不会对不可访问 repo 反复失败重试。
- [ ] README / Repo Health / OpenSSF 后台任务不会对无 token / token 权限不足的私有 repo 反复远程刷新。
- [ ] 移出知识库后,若 repo 仍 starred,embedding 保留。
- [ ] 移出知识库后,若 repo 同时不在 starred 与知识库,只是不再属于 active scope,不立即删除缓存。
- [ ] 移出知识库后,若 repo 同时不在 starred 与知识库,release 轮询不再自动刷新它,但订阅关系仍保留。
- [ ] ShareCard 文件导出入口显示“导出到文件”。
- [ ] ShareCard 文件导出四个下拉项与方案文案一致。
- [ ] Starred HTML/Markdown 导出不包含未 star 已入库 repo。
- [ ] 知识库 HTML/Markdown 导出包含未 star 已入库 repo。
- [ ] 知识库 HTML/Markdown 导出顺序与 Smart Collections -> 知识库一致。
- [ ] 知识库 HTML/Markdown 使用独立知识库格式,不是 Starred 模板换标题。
- [ ] 知识库 HTML/Markdown 没有新增独立视觉设计分支,标题/页头/基础排版沿用 Starred 导出模板风格。
- [ ] 知识库 HTML/Markdown 导出文件中包含 notes。
- [ ] 知识库 HTML/Markdown 对已有摘要正常导出,对缺失摘要不触发生成。
- [ ] 知识库为空时,知识库 HTML/Markdown 导出不创建文件并显示 toast。
- [ ] 在 Smart Collections -> 知识库开启筛选后,从 Profile/ShareCard 导出知识库仍导出全量知识库。
- [ ] 四种导出默认文件名分别使用 `starcat-starred-*` / `starcat-library-*` 前缀和正确扩展名。
- [ ] Starred 导出与知识库导出的标题/说明文案区分清楚。

### 11.8 数据同步预留

- [ ] `library_updated_at` 已写入并随入库/移出更新。
- [ ] 重复加入已入库 repo 后,`library_updated_at` 不变化。
- [ ] 修改 notes / tags / status 后,`library_updated_at` 不变化。
- [ ] 不可访问/恢复可访问后,`library_updated_at` 不变化。
- [ ] CloudKit 当前不实施,但设计和字段已记录后续同步范围。
- [ ] 账号 A 将 repo X 加入知识库后,切换到账号 B 时 repo X 不显示为 B 的已入库。
- [ ] 账号 A 与账号 B 分别对同一 repo 设置知识库状态时,`libraryState/libraryUpdatedAt/notes/status/tags` 互不覆盖。
- [ ] 退出登录后不显示用户私有知识库,且 ❤️ 入库操作不可用。
- [ ] 重新登录账号 A 后,账号 A 之前的知识库状态恢复。
- [ ] 切换到账号 B 后,账号 A 的知识库状态不可见但未被删除。
- [ ] JSON 导出文件包含 `libraryState` 与 `libraryUpdatedAt`。
- [ ] JSON 导入 `.inLibrary` 后恢复知识库状态,不会自动 GitHub star。
- [ ] JSON 导入未 star 已入库 repo 后,repo 出现在知识库集合,但不出现在 Manage 默认列表。
- [ ] JSON 导入同 repo 冲突时,`libraryUpdatedAt` 较新的状态胜出。
- [ ] JSON 导入状态胜出时,本地保留导入文件里的 `libraryUpdatedAt`。
- [ ] JSON 导入旧文件缺少 `libraryState` 时,该 repo 默认为 `.outsideLibrary`。
- [ ] 登录账号 B 后导入账号 A 导出的文件,`.inLibrary` 恢复到账号 B 名下,不影响账号 A 的本地状态。
- [ ] 未登录时执行包含 `libraryState` 的 JSON 导入,不会落库并提示需要登录。

## 12. 变更记录

- 2026-07-02: PR-5 第四批语义搜索 UI 增加 starred/knowledge/all 范围筛选。
- 2026-07-02: PR-5 第三批 MCP search/semantic/resources 支持范围参数。
- 2026-07-02: PR-5 第二批 Home 搜索候选与 FTS 按当前范围对齐。
- 2026-07-02: PR-5 第一批 SemanticIndexBuilder 支持 starred/knowledge/all 范围。
- 2026-07-02: PR-6 第四批 Browser Plugin 接入知识库心形状态与写入。
- 2026-07-02: PR-6 第三批新增 Companion library-state 写入 route。
- 2026-07-02: PR-6 第二批 repo-context DTO 增加 library state。
- 2026-07-02: PR-6 第一批放宽已入库未 star repo 的 notes/tags/status 本地写入。
- 2026-07-02: PR-4 第二批落地 Trending/Discovery/Weekly/Activity 已入库角标。
- 2026-07-02: PR-2 第三批落地知识库集合语言筛选和知识库语言统计。
- 2026-07-02: PR-3 第三批补齐设置 using 自动入库的轻量反馈。
- 2026-07-02: PR-4 第一批落地 Manage 列表已入库心形角标。
- 2026-07-02: PR-3 第二批落地 Manage 多选批量加入知识库。
- 2026-07-02: PR-3 第一批落地详情页知识库心形入口和真实写库。
- 2026-07-02: PR-2 第二批落地 Manage 知识库筛选条件和持久化。
- 2026-07-02: PR-2 第一批落地 Smart Collections 知识库集合入口和列表范围。
- 2026-07-02: PR-1 第二批落地知识库 repo 查询、FTS 范围和未 star 外部 repo metadata 写入。
- 2026-07-02: PR-1 第一批落地 LibraryState、repo_notes 字段和 RepoNoteRepository 查询/更新能力。
- 2026-07-02: 确认详情页 ❤️ 不做乐观更新,写入成功后再更新 UI。
- 2026-07-02: 确认单 repo 手动 README/Health/OpenSSF 刷新允许已入库未 star repo,失败不改状态不清缓存。
- 2026-07-02: 确认移出知识库保留 Releases 订阅关系,但非 active repo 不再自动 release 轮询。
- 2026-07-02: 确认 Watchers/Forks/Issues 等 GitHub 统计刷新覆盖 starred 与知识库并集,失败不改入库状态。
- 2026-07-02: 确认 Releases 订阅允许未 star 已入库 repo 使用,实际拉取按权限降级。
- 2026-07-02: 确认未 star 已入库 repo 允许完整使用本地 notes/tags/status。
- 2026-07-02: 确认 ShareCard/Profile 文件导出命名按 starcat-starred 与 starcat-library 加日期区分。
- 2026-07-02: 确认知识库导出标题/页头/基础排版参考现有 Starred 导出模板,不继续展开导出细节。
- 2026-07-02: 确认 ShareCard/Profile 知识库文件导出第一版始终导出全量知识库,不跟随当前筛选。
- 2026-07-02: 确认知识库导出为空时不生成空文件,只 toast;Starred 导出现有行为不变。
- 2026-07-02: 确认知识库导出与现有 Starred 导出一致,有摘要就导出且不临时生成。
- 2026-07-02: 确认知识库 HTML/Markdown 导出默认包含 notes,不加额外选项。
- 2026-07-02: 确认知识库导出排序沿用知识库集合,HTML/Markdown 需要重新设计格式。
- 2026-07-02: 确认 ShareCard 文件导出入口改为“导出到文件”,下拉支持 Starred/知识库 HTML 与 Markdown。
- 2026-07-02: 确认退出登录或切换账号时本地知识库数据保留但隐藏,同账号重新登录后恢复。
- 2026-07-02: 确认 JSON 导入按当前登录账号恢复知识库状态,未登录不写入 libraryState。
- 2026-07-02: 确认 libraryState 按 GitHub 用户隔离,同 repo 多账号状态互不影响。
- 2026-07-02: 确认已登录离线可改本地知识库状态,未登录不允许加入或移出知识库。
- 2026-07-02: 确认无 token / token 权限不足时,私有 repo 本地知识库数据可用,远程能力按权限降级。
- 2026-07-02: 确认 libraryUpdatedAt 仅在入库状态实际变化时更新。
- 2026-07-02: 确认不可访问 repo 保留入库状态,UI 标记失效且后台任务跳过或降频。
- 2026-07-02: 确认多选第一版只支持批量加入知识库,不支持批量移出。
- 2026-07-02: 确认 JSON 导入导出纳入 libraryState/libraryUpdatedAt 且不触发 GitHub star。
- 2026-07-02: 明确 logo 左上角标识、知识库排序、默认 unread、集合筛选和失败反馈。
- 2026-07-02: 补充人工验证流程,覆盖数据准备、入口、列表、集合、Search/Plugin、AI/MCP、缓存和同步预留。
- 2026-07-02: 补充 repo 卡片左上角 ❤️ 入库标识任务,覆盖 Manage/Trending/Discovery/Weekly/Activity。
- 2026-07-02: 建立 Starred 与知识库专项,明确语义拆分、详情页 ❤️ 入口和分阶段改造计划。
- 2026-07-02: 收敛详情页 ❤️ 为未入库 / 已入库二态 toggle,移除未整理 / 忽略等扩展状态。
