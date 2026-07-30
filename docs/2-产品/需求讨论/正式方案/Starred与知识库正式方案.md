# Starred 与知识库正式方案

> 日期: 2026-07-02
> 状态: 正式方案
> 范围: Starcat 私有知识库状态、详情页 ❤️ 入口、Smart Collections 知识库集合、AI/MCP 范围改造

## 1. 方案目标

将 GitHub `starred` 与 Starcat“知识库”拆成两套语义:

- `starred`: GitHub 公开行为和同步事实。
- `libraryState`: Starcat 私有知识管理状态。

目标是让 Starcat 从“只有 GitHub starred 一种 repo 关系”升级为“GitHub starred 与 Starcat 知识库两种关系并存”。AI/MCP、预热、embedding 和分享能力都可以覆盖 starred 与知识库,但 UI 必须清楚区分它们的语义。

## 2. 产品原则

1. Starred 是来源,不是知识库边界。
2. 加入知识库是私有动作,不自动 star。
3. Star 是 GitHub 公开动作,不自动入库。
4. 未 star repo 可以加入知识库。
5. `正在使用` 继续是用户私有状态,并视为强知识库信号。
6. AI/MCP 不只面向知识库;starred 与知识库都可以作为可选范围,单仓库 AI 功能也可以按用户显式触发。

## 3. 信息架构

Smart Collections 新增系统集合:

| 集合 | 规则 | 说明 |
|---|---|---|
| 知识库 | `libraryState == .inLibrary` | Starcat 私有入库范围 |
| 正在使用 | `RepoStatus.using` | 保留现有语义,作为更强工作信号 |

第一版只新增“知识库”。不引入“未整理”“已忽略”等额外状态,避免把详情页 ❤️ 的二态 toggle 扩展成整理工作流。

## 4. 数据状态

新增 `LibraryState`。它只表达是否进入 Starcat 私有知识库,不承载整理池或忽略状态:

| 状态 | UI 文案 | 含义 |
|---|---|---|
| `outsideLibrary` | 未入库 | 未进入 Starcat 私有知识库 |
| `inLibrary` | 已入库 | 进入 Starcat 私有知识库 |

默认规则:

- GitHub stars 同步进来的 repo 默认为 `.outsideLibrary`。
- 用户点击 ❤️ 后设为 `.inLibrary`。
- 用户再次点击已入库 ❤️ 后回到 `.outsideLibrary`。
- 用户的状态真正从非 `using` 变为 `using` 时,如果尚未入库,同步设为 `.inLibrary`;重复保存已有 `using` 不覆盖用户明确设置的 `.outsideLibrary`。
- 设置 `using` 自动入库时不弹确认,但给轻量 toast,例如“已标记正在使用,并加入知识库”。
- 用户从 `using` 改回 `read` / `unread` 时,保持当前 `libraryState` 不变;取消使用状态不代表加入或移出知识库。
- 用户从知识库移除时只设置 `libraryState = .outsideLibrary`;即使 repo 仍是 `using` 也不修改阅读状态、不弹状态降级确认。
- 未 star 外部 repo 点击 ❤️ 后落本地 repo 元数据,`isStarred = false`, `libraryState = .inLibrary`。
- 未入库 repo 加入知识库后默认 `RepoStatus.unread`;如果是从 `RepoStatus.using` 自动入库,则保持 `using`。
- 未 star 已入库 repo 允许完整使用本地 notes / tags / status,能力边界从“必须 starred”调整为“已 star 或已入库”。
- Releases 订阅允许未 star 已入库 repo 使用,能力边界同样从“必须 starred”调整为“已 star 或已入库”。
- GitHub star/unstar、远程 metadata refresh、README fetch、外部 GitHub 内容访问仍按 GitHub star 状态、token 与权限分层,不能因为已入库就伪装成 GitHub starred。
- Release 实际拉取仍走 GitHub 访问能力,需要按 token、权限和 repo 可访问性降级。
- Watchers / Forks / Issues 等 GitHub 统计刷新属于 repo metadata 展示能力,候选范围覆盖 starred 与知识库并集。
- 统计刷新遇到 token 权限不足、repo 私有或不可访问时应跳过或降频,不得自动移出知识库或修改 `libraryState`。
- 用户手动触发单个 repo 的 README / Health / OpenSSF 刷新时,能力边界同样覆盖“已 star 或已入库”。未 star 已入库 repo 可以手动刷新这些信息。
- 手动刷新失败只反馈错误并保留原缓存,不得改变 `libraryState`,也不得把 repo 自动移出知识库。
- Star/unstar 不自动改变知识库状态。已 star 且已入库的 repo 被 unstar 后仍保持 `.inLibrary`,可继续在知识库集合中出现。
- 移出知识库只更新 `libraryState`,不删除 repo metadata、notes、tags、status、Releases 订阅关系、README、Health、OpenSSF 或 embedding 缓存。
- 如果移出后 repo 同时不在 starred 与知识库,release 轮询不再把它作为 active scope 自动刷新;用户重新 star 或重新入库后,该订阅关系重新进入自动刷新候选。
- GitHub repo 被删除、转私有、返回 404/410 或权限不足时,不自动改变 `libraryState`。已入库 repo 仍保留在知识库集合,但 UI 应标记为不可访问/已失效。
- 不可访问 repo 的 README / Health / OpenSSF 后台任务应跳过或降频,避免反复失败;用户仍可手动移出知识库。如果后续重新可访问,恢复正常状态。
- 已入库的私有 repo 或权限 repo 在没有 GitHub token / token 权限不足时,知识库状态和本地 notes/tags/status 仍可用。
- 如果 README 已有本地缓存,允许继续查看缓存;没有缓存时展示权限不足或内容不可用,不得伪装成空 README。
- GitHub star/unstar、元数据刷新、README 拉取、外部 GitHub 内容访问等能力必须按 token 权限门控。
- AI/MCP 可以使用本地用户数据与已缓存内容,但必须明确只基于本地可用数据,不能假装已经访问到私有 GitHub 内容。
- 已登录但离线时,允许对本地已有 repo 执行加入/移出知识库,因为这是 Starcat 私有本地状态。
- 未登录时不允许加入/移出知识库。未登录态缺少明确用户归属,不能写入用户私有知识库关系。

## 4.1 数据写入位置

知识库不是直接在 `repos` 表上加一个业务字段来区分。

数据拆分如下:

- `repos`: 继续存 repo 元数据缓存,包括 owner/name/stars/is_starred 等。未 star repo 加入知识库时也需要先写入这里,但 `is_starred = false`。
- `starred_repos`: 继续存 GitHub star 关系和 starred_at,只服务 GitHub starred 事实。
- `repo_notes.library_state`: 存 Starcat 私有知识库关系,例如 `outside_library/in_library`。

这样做的原因:

- `repos` 是可重建的仓库元数据缓存,不应该承载用户私有入库关系。
- `starred_repos` 是 GitHub 公开 star 关系,不应该混入 Starcat 私有知识库。
- `repo_notes` 已经是“一 repo 一条用户私有数据”的承载点,可在 content/status 之外承载 library state。
- `libraryState` 必须跟 notes/status/tags 一样按 GitHub 登录用户隔离。同一个 repo 在不同账号下可以有不同的入库状态、笔记、标签和状态。
- 退出登录或切换账号时,不删除本地用户私有数据,只按当前登录账号决定可见性。未登录态不展示用户私有知识库,也不允许修改;重新登录同一 GitHub 账号后恢复该账号的 `libraryState`、notes、tags、status。
- 删除只来自用户显式动作,例如“清除本地数据”或“删除账号数据”,不能在普通退出登录时顺手清掉。

实现约束:

- 更新 note 内容不能覆盖 `library_state`。
- 更新 `RepoStatus` 不能覆盖 `library_state`。
- 更新 `library_state` 不能覆盖 note 内容和 `RepoStatus`。
- `libraryState` 属于用户私有数据,后续 CloudKit 集成时需要与 notes/status/tags 同步。第一版先记录字段和更新时间,暂不实现 CloudKit。
- `library_updated_at` 后续参与 CloudKit 冲突解决;多设备一边入库、一边移出时按最后更新时间胜出。
- `library_updated_at` 只在 `libraryState` 实际变化时更新。notes / tags / status 改变、不可访问状态变化、重复加入已入库 repo 都不更新。
- JSON 导入/导出需要包含 `libraryState` 与 `libraryUpdatedAt`。导入 `.inLibrary` 只恢复 Starcat 私有知识库关系,不调用 GitHub star。
- JSON 导入未 star 已入库 repo 时,需要写入 repo metadata 并保持 `isStarred = false`;目标设备已有同 repo 时,按 `libraryUpdatedAt` 较新的状态胜出。
- 导入文件没有 `libraryState` 字段时,默认按 `.outsideLibrary` 处理。
- JSON 导入状态胜出时使用导入文件里的 `libraryUpdatedAt`,不使用当前时间覆盖。
- JSON 导入始终写入当前登录账号的用户私有数据。导出文件可以来自其他账号,但导入时不把原账号作为归属继续带入。
- 未登录时不允许执行会写入 `libraryState` 的导入,避免产生无归属的用户私有数据。

## 5. 详情页入口

入口位置:

- 放在详情页动作区,紧跟当前 Wiki / 推荐 / CodeFlow / Codebase 等图标之后。
- 使用 ❤️ 常驻图标。
- 不放在 GitHub star ⭐ chip 内,避免混淆公开 Star 与私有入库。

状态:

| 状态 | 图标 | tooltip | 点击后 |
|---|---|---|---|
| 未入库 | 空心心形 | 加入知识库 | 设置 `.inLibrary` |
| 已入库 | 实心心形 | 已入库 | 设置 `.outsideLibrary` |
| 操作中 | 心形 + 动画 | 正在更新 | 禁用重复点击 |
| 失败 | 短暂抖动/红色反馈 | 更新失败 | 保持原状态 |

动画要求:

- 点击加入成功时给轻量缩放/填充动画。
- 点击已入库状态取消时也给轻量反馈,但不引入额外确认流程。
- 动画只表达本地状态成功,不代表 GitHub star。
- 详情页不做乐观更新。点击后先进入操作中/禁用状态,等待 repo metadata 与 `libraryState` 写入成功后再更新 ❤️、列表角标和 registry。
- 失败时不悄悄吞掉,但错误展示应复用现有 toast/error pattern。
- 失败时保持原状态,不先变更再回滚。

### 5.1 Repo 卡片入库标识

除详情页入口外,所有 repo 列表卡片都需要展示“是否已入库”的只读识别信号。

适用范围:

- Manage repo 列表。
- Trending repo 列表。
- Discovery repo 列表。
- Weekly repo 列表。
- Activity 中 repo-backed 卡片。

视觉规则:

- 在 repo logo 左上角叠加 ❤️。
- 仅 `libraryState == .inLibrary` 时展示;未入库不展示空心心。
- ❤️ 不替代现有 GitHub Star 标识,两者可以同时存在。
- ❤️ 不放在标题行,避免与 fullName、Fork、OpenSSF、Health、Weekly source 等徽章争空间。
- 列表 ❤️ 第一版只读,点击 row 仍进入详情页,入库/取消入库仍通过详情页动作区完成。
- 这里的“列表只读”只指 Manage / Trending / Discovery / Weekly / Activity 的 repo row 小角标。Search Center 和 Browser Plugin 可以提供空心/实心 ❤️ 操作入口。
- Search Center 的可操作 ❤️ 放在搜索结果 row 的 trailing action 区或详情/预览动作区,不要把 logo 角标做成可点击。

数据规则:

- `RepoCardViewData` 需要携带 `isInLibrary` 或等价字段。
- 本地 Manage / Activity repo 由 `RepoNote.libraryState` 派生。
- Trending / Discovery / Weekly 等远端卡片通过全局 library state registry 或批量查询回填。
- 判断优先使用 `ghRepoId`;缺失时才用 `owner/name` 兜底。

## 6. 未 star repo 的入库交互

允许未 star repo 加入知识库。

适用入口:

- Discovery 详情页。
- Trending 详情页。
- Weekly/Activity 中来自远端的 repo 详情。
- Search Center 的 GitHub 搜索结果。
- Browser Plugin 的 GitHub repo 页面。

交互:

- 主按钮: `加入知识库`。
- 加入成功后可显示轻量操作 `同时 Star`,但不强制、不自动。
- 如果用户点击 `Star`,仍走现有 StarActionService。
- Search Center 搜索结果需要同时展示入库状态,并允许直接加入/移出知识库。
- Search Center 直接移出知识库时沿用详情页规则:只更新 `libraryState`,不修改阅读状态。
- Browser Plugin 中的 ❤️ 与详情页一致: 空心表示未入库,实心表示已入库,点击只更新 Starcat 私有知识库状态。
- Browser Plugin 操作失败时显示插件内 toast,并回滚 ❤️ 状态。

## 6.1 多选批量操作

第一版支持批量加入知识库,不支持批量移出知识库。

规则:

- 多选菜单增加 `加入知识库`。
- 已入库 repo 跳过或保持不变。
- 未入库 repo 设置 `.inLibrary`,默认 `RepoStatus.unread`。
- 不调用 GitHub star。
- 第一版不提供批量 `移出知识库`,避免一次操作内混入 `using` 二次确认、状态降级和误操作风险。

## 7. AI/MCP 范围

以下功能必须同时支持 starred 与知识库范围:

- 语义索引全量构建。
- 语义搜索候选集。
- AI 对话注入的 repo 候选上下文。
- 推荐上下文中“我的库/我的 stars”部分。
- MCP repo 查询和语义查询。
- Browser Plugin 暴露给 GitHub 页面的 Starcat 状态。

第一版不做“只能查知识库”的硬限制。推荐实现为范围参数或分段入口:

- `starred`: GitHub stars 范围。
- `library`: Starcat 知识库范围。
- `all`: starred 与知识库并集,用于 embedding、预热和全局搜索。

以下功能继续允许单 repo 显式触发,不要求已入库:

- 当前详情页的 AI 摘要。
- 当前详情页的 CodeFlow / Codebase 准备。
- 当前详情页的 README 查看。
- 当前详情页的 GitHub 外链 / clone。

这样既保留 starred 的原有 AI 能力,也让知识库成为更明确的私有筛选维度。

后台任务同样使用 starred 与知识库并集:

- README 预拉、Repo Health、OpenSSF、embedding 都以 `starred ∪ knowledge` 作为默认处理范围。
- Health / OpenSSF 的后台任务不能只改候选 SQL,还必须同步改 coverage 统计,否则首次预热会出现 total 包含一批 repo,实际候选却取不到,最终反复 pause/retry。
- 停止边界以“并集范围内无待处理候选”或“并集 coverage 已满”为准,而不是只看 starred。

ShareCard 文件导出需要同时支持 Starred 与知识库:

- 原“导出 Starred”入口文案改为“导出到文件”。
- 下拉项固定为“导出 Starred 到 HTML.”、“导出 Starred 到 Markdown.”、“导出 知识库 到 HTML.”、“导出 知识库 到 Markdown.”。
- Starred 导出继续表达 GitHub stars 语义。
- 知识库导出只导出 `libraryState == .inLibrary` 的 repo。
- 未 star 但已入库的 repo 可以出现在知识库导出中,但不得出现在 Starred 导出中。
- 文案不能把知识库导出伪装成 GitHub Starred。
- 知识库导出排序沿用知识库集合排序: `COALESCE(starred_at, library_updated_at, cached_at) DESC`。
- 知识库 HTML / Markdown 导出需要单独设计内容结构,不能只复用 Starred 导出模板改标题。标题、页头、基础排版参考现有 Starred 导出模板;内容结构围绕“个人知识库”语义组织,突出入库时间、状态、标签、语言、简介、README/Health/OpenSSF 等可用摘要信息。
- 知识库 HTML / Markdown 导出默认直接包含用户 notes,不提供额外开关。导出动作本身视为用户明确选择把知识库内容输出到文件。
- 知识库导出的摘要策略与现有 Starred HTML / Markdown 导出一致: 已有摘要就导出,没有摘要就留空或标记未生成,不得为了导出临时触发 README 拉取、AI 摘要、Health 或 OpenSSF 刷新。
- 知识库导出空状态: 如果 `libraryState == .inLibrary` 的 repo 数量为 0,点击“导出 知识库 到 HTML/Markdown”不生成空文件,直接 toast “知识库为空,暂无可导出的 repo”。Starred 导出现有空状态行为不在本专项修改。
- ShareCard/Profile 的知识库文件导出第一版始终导出全量知识库,不跟随 Smart Collections 当前筛选条件。原因是入口在 Profile/ShareCard,用户心智是“导出我的知识库”;如果后续在知识库集合页增加局部导出,再单独设计“导出当前筛选结果”。
- 文件名按范围区分,沿用日期后缀:
  - `starcat-starred-YYYY-MM-DD.html`
  - `starcat-starred-YYYY-MM-DD.md`
  - `starcat-library-YYYY-MM-DD.html`
  - `starcat-library-YYYY-MM-DD.md`

## 8. 仍基于 starred 的能力

以下能力必须继续基于 GitHub starred,不得机械替换:

- GitHub stars 同步。
- Star / unstar 操作。
- Star 图标状态。
- GitHub Star Lists。
- stars 数量、同步进度、ETag、增量同步 cutoff。
- “导出我的 stars”或分享 stars 相关能力。
- 需要明确表达 GitHub star 事实的 UI。

## 9. 版本切分建议

PR-1: 数据模型与查询

- 新增 `LibraryState`。
- 新增 repository 查询与写入方法。
- 单测覆盖默认状态、入库、移出、未 star 入库。

PR-2: Smart Collections 知识库集合

- 新增“知识库”系统 Smart Collection。
- Manage / 列表筛选菜单增加知识库筛选条件。
- 知识库集合支持现有 tag / status / language / archived / fork 筛选。
- 知识库集合包含未 star 已入库 repo。
- Manage 默认仍是 starred 管理视图,不混入未 star 已入库 repo;查看全量知识库走 Smart Collections -> 知识库。
- 知识库集合排序采用 `COALESCE(starred_at, library_updated_at, cached_at) DESC`;未 star 已入库 repo 主要按 `library_updated_at DESC` 排序。
- 单测覆盖集合命中与计数。

PR-3: 详情页 ❤️ 入口

- 详情页动作区增加常驻 ❤️。
- 接入状态读取、点击写入、动画反馈。
- 覆盖 Manage / Trending / Discovery / Weekly / Activity 等详情来源。
- 多选支持批量加入知识库,但不支持批量移出知识库。

PR-4: Repo 卡片 ❤️ 入库标识

- `RepoCardViewData` 增加知识库状态字段。
- `UnifiedRepoRow` 在 repo logo 左上角展示已入库 ❤️。
- Manage / Trending / Discovery / Weekly / Activity 的 row 数据接入 library state。
- 单测或快照检查覆盖 starred 与 knowledge 两个标识同时存在的情况。

PR-5: AI/MCP 范围改造

- `SemanticIndexBuilder` 支持 starred、knowledge、all 三种候选范围,默认可用 all。
- 语义搜索候选集支持 starred 与知识库。
- MCP 查询支持范围参数,不把 starred 能力移除。
- 单 repo 显式触发继续可用。

PR-6: Companion / Search / 外部来源入库

- Browser Plugin 返回并展示知识库状态。
- 插件动作允许将当前 GitHub repo 加入知识库。
- Search Center 展示入库状态并允许搜索结果直接入库/移出。
- Search / Discovery / Trending 未 star repo 支持入库。

## 10. 验收标准

- 用户可以在详情页通过 ❤️ 把 repo 加入知识库或取消入库。
- 已 star 未入库 repo 仍可参与 starred 范围的 AI/语义搜索。
- 未 star 已入库 repo 可以在知识库集合中出现。
- Manage 默认列表不显示未 star 已入库 repo。
- Star/unstar 不自动改变知识库状态。
- 已 star 且已入库 repo 被 unstar 后,仍保留在知识库集合中。
- 移出知识库不删除 notes、tags、status、README、Health、OpenSSF 或 embedding 缓存。
- `libraryState` 后续需要进入 CloudKit 同步,但 CloudKit 未集成前不实施同步逻辑。
- 知识库集合计数准确。
- MCP 与语义搜索可按范围返回 starred、知识库或两者并集。
- 现有 GitHub star 同步、Star Lists、分享 stars 不回归。
