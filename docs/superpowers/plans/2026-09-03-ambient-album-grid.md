# Ambient Album Grid 实施计划

> 状态：2026-09-05 无缝满铺与随机单格翻转已实现，待 dong4j 本机构建和运行时验收
> 执行边界：只有 dong4j 明确要求实施后才修改 Swift；`docs/功能实现总览.md` 仍需单独授权
> 执行方式：按 Task 顺序小步实现和验证，不依赖当前环境不存在的 `superpowers:*` skill，也不默认启用 subagent

**目标：** 在 App 内提供对标 macOS 经典 Album Artwork 的 Ambient 全屏网格：Repo / Owner 两场景独立播放，无缝满铺并随机单格翻转，Core 可在未来 `.saver` 壳中复用。

**架构：** `AmbientCatalogProviding` 提供一次性卡片快照 → 纯值 `AmbientGridEngine` 用单调时间维护当前卡、下一张卡和 deadline → `AmbientViewModel` 在 MainActor 上按下一 deadline 调度 → AppKit 全屏壳与 SwiftUI 网格只负责窗口和像素。

**技术栈：** Swift 6 语言模式、SwiftUI + 窄 AppKit 窗口壳、Swift Testing、现有 `RepoRepositoryProtocol.fetchAllStarred()`、Kingfisher 缓存与 `ImagePrefetcher`、xcodegen / Makefile 标准入口。

**Spec：** `docs/superpowers/specs/2026-09-03-ambient-album-grid-design.md`

## 1. 全局约束

- v1 只渲染 `AmbientDensity.minimal`；保留 `.info` / `.rich` 枚举，不实现其 UI 和数据装配。
- `.repos` / `.owners` 一次只播放一种；切换场景必须取消旧加载与旧调度。
- 运动模型是固定网格的随机单格翻转，不是按索引扫描、整屏换批或自由漂浮拼贴。
- 纯观赏：卡片没有点击行为；Esc / 明确退出最终都关闭 Ambient 窗口。
- 进入 Ambient 时读取一次 stars 快照；运行中不追随同步增量。
- Core 禁止依赖 SwiftUI、AppKit、Kingfisher、`Database.shared` 和具体窗口。
- Engine 使用单调 uptime；禁止墙钟时间、`@unchecked Sendable` 和无锁共享可变状态。
- App 独立窗口根必须走 `.appHostEnvironment(dependencies)`，继承 locale、interface scale 与动画偏好。
- `starcatReduceMotion == true` 时只显示静态首屏，不创建持续 Timer / Timeline。
- Ambient 固定深色纯黑背景；文字 / 图标仍只用 `.primary` / `.secondary`。
- 新文案 key 使用 `ambient.*`；`Localizable.xcstrings` 只允许 Xcode 或经验证的唯一锚点按行插入，禁止 ApplyPatch / StrReplace / JSON 重排写回。
- 默认参数：5 行、全局每 3s 随机换一格、首次换卡延后 2s、Y 轴翻转 0.8s、间距与外边距均为 0。
- 不执行 package / release / upload / notarization / deploy。
- 不修改 `docs/功能实现总览.md`、Changelog 或其它专题文档。

## 2. 文件地图

| 路径 | 职责 |
|------|------|
| `Starcat/Features/Ambient/Core/AmbientModels.swift` | 场景、密度、卡片、配置、槽位和推进结果 |
| `Starcat/Features/Ambient/Core/AmbientCatalogProviding.swift` | `async throws` Catalog 协议与静态测试实现 |
| `Starcat/Features/Ambient/Core/AmbientCardFactory.swift` | Repo / Owner minimal 卡片与 visualKey 归一化 |
| `Starcat/Features/Ambient/Core/AmbientGridEngine.swift` | 纯值 deadline 状态机、随机槽位 bag、预选下一张、休眠恢复 |
| `Starcat/Features/Ambient/App/LocalAmbientCatalog.swift` | 从本地 repository 拍快照，保留读取错误 |
| `Starcat/Features/Ambient/App/AmbientViewModel.swift` | MainActor 加载状态、调度、取消和快照发布 |
| `Starcat/Features/Ambient/App/AmbientWindowController.swift` | 单例全屏窗口与进入 / 退出状态机 |
| `Starcat/Features/Ambient/App/AmbientRootView.swift` | loading / empty / failed / loaded 根视图 |
| `Starcat/Features/Ambient/App/AmbientGridView.swift` | 按实际 geometry 计算无缝满铺和横向裁切 |
| `Starcat/Features/Ambient/App/AmbientCellView.swift` | 单槽位 Y 轴翻转、标题遮罩、占位 |
| `Starcat/Features/Ambient/App/AmbientArtworkView.swift` | 大尺寸 artwork、像素请求和 Kingfisher 缓存 |
| `Starcat/Features/Ambient/App/AmbientImagePrefetcher.swift` | 有界预热当前快照的下一张 artwork |
| `Starcat/App/StarcatApp.swift` | DEBUG 菜单 Repo / Owner 入口 |
| `Starcat/Resources/Localizable.xcstrings` | `ambient.*` 中英文文案 |
| `StarcatTests/AmbientGridEngineTests.swift` | deadline、恢复、抽卡和小池测试 |
| `StarcatTests/AmbientCardFactoryTests.swift` | minimal 字段、Owner 聚合和 visualKey 测试 |
| `StarcatTests/AmbientCatalogTests.swift` | Catalog 成功 / 空 / 抛错测试 |
| `StarcatTests/AmbientViewModelTests.swift` | 加载代际、取消、调度与 Reduce Motion 测试 |
| `StarcatTests/AmbientArtworkTests.swift` | 像素 URL、稳定占位和有界预取测试 |
| `StarcatTests/AmbientWindowLifecycleTests.swift` | 不启动真实 Window 的全屏状态机测试 |

## 3. Task 0：开工前检查与工作区隔离

**目标：** 在新增文件前确认主进度、UI 契约、真实代码接口和脏文件边界。

- [ ] 只读打开：
  - `docs/功能实现总览.md`
  - `docs/1-立项/开发前问题清单.md`
  - `DESIGN.md`
  - `docs/5-规范/UI-颜色规范.md`
  - `docs/5-规范/UI-Focus-Ring-规范.md`
  - `docs/5-规范/国际化-规范.md`
  - `docs/5-规范/i18n-军规.md`
- [ ] 核对 `RepoRepositoryProtocol.fetchAllStarred()`、`Repo.ownerAvatar`、`RemoteAvatar`、`AppHostEnvironment`、`StarcatAppCommands` 与 `starcatReduceMotion` 的当前实现。
- [ ] 运行 `git status --short`，记录所有预存修改；2026-09-05 审查时 `Starcat/App/StarcatApp.swift` 有未提交修改，实施前必须重新核对，并确认如何避免把原改动带入 Ambient 提交。
- [ ] 如果需要新 branch / worktree，先读取 `BRANCH.md` 与 `docs/5-规范/Git-分支与Worktree规范.md`，取得相应授权后再操作；不要擅自移动当前脏工作区。
- [ ] 确认两份 `docs/superpowers` 方案在实际实施 workspace 中可见。它们在 2026-09-05 审查时是 untracked，不能假设新 worktree 会自动包含；以开工时 `git status` 为准。

**Gate：** 无法隔离 `StarcatApp.swift` 的重叠修改，或实施 workspace 看不到本方案时，停止并向 dong4j 报告；不得用 `git add -A` 绕过。

## 4. Task 1：Core 模型与 Catalog 协议

**Files**

- Create `Starcat/Features/Ambient/Core/AmbientModels.swift`
- Create `Starcat/Features/Ambient/Core/AmbientCatalogProviding.swift`

### 4.1 接口

```swift
enum AmbientSceneKind: String, Sendable, CaseIterable {
    case repos
    case owners
}

enum AmbientDensity: String, Sendable, CaseIterable {
    case minimal
    case info
    case rich
}

struct AmbientCardModel: Identifiable, Equatable, Sendable {
    let id: String
    let visualKey: String
    let title: String
    let artworkURLString: String?
    let subtitle: String?
    let metadata: [String: String]
}

struct AmbientGridConfig: Equatable, Sendable {
    var rowCount: Int
    var columnCount: Int
    var changeInterval: TimeInterval
    var flipDuration: TimeInterval
    var initialLeadIn: TimeInterval
}

struct AmbientSlotSnapshot: Identifiable, Equatable, Sendable {
    let id: Int
    let card: AmbientCardModel?
    let nextCard: AmbientCardModel?
}

protocol AmbientCatalogProviding: Sendable {
    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel]
}
```

### 4.2 约束

- `TimeInterval` 表示进程单调 uptime，不是 `Date.timeIntervalSince1970`。
- `slotCount` 对非正行列返回 0；配置构造时钳制 `changeInterval > flipDuration >= 0`。
- `visualKey` 表达视觉素材身份。Repo / Owner 使用 `owner:<lowercased-login>`，使不同 Repo 共享同一头像时仍可避邻。
- `.info` / `.rich` 只保留枚举和模型字段；Factory 本迭代只生成 minimal 数据，不提前实现未来展示逻辑。
- `StaticAmbientCatalog` 同样 `async throws`，并允许测试注入错误。

### 4.3 验证

- [ ] 新文件落盘后立即 `xcodegen generate`。
- [ ] 先做编译级 smoke；不要在尚未进入工程的测试文件上声称“预期编译失败”。
- [ ] `git diff --check -- <本 Task 文件>`。

## 5. Task 2：AmbientGridEngine（TDD）

**Files**

- Create `Starcat/Features/Ambient/Core/AmbientGridEngine.swift`
- Create `StarcatTests/AmbientGridEngineTests.swift`

### 5.1 类型与隔离

- Engine 优先实现为 `struct AmbientGridEngine: Sendable`，由 MainActor ViewModel 独占并 `mutating` 推进。
- 禁止 `@unchecked Sendable`、锁外共享 class 和 Engine 内部 Timer。
- UI 不直接持有 Engine 可变引用，只消费 ViewModel 发布的 `[AmbientSlotSnapshot]`。

### 5.2 初始化

1. 按 `rowCount × columnCount` 创建槽位。
2. 为每个槽位选择当前卡，尽量避开已经就位的上 / 左邻居 id 与 visualKey。
3. 为每个槽位预选 `nextCard`，避开本槽当前 / 上一张及邻格当前视觉素材。
4. 全局 deadline 从 `now + initialLeadIn` 开始；槽位顺序使用 seeded shuffle-bag 随机排列。
5. 空池保留槽位但 card / nextCard 为 nil；单卡池不制造虚假的视觉变化。

### 5.3 推进

`mutating func advance(now:) -> AmbientAdvanceResult`：

- 未到全局 deadline：返回 unchanged，并带当前 `nextDeadline`。
- 到达 deadline：从 shuffle-bag 取一个槽位，执行 `card = nextCard` 并预选新的 `nextCard`。
- 一轮 bag 内每格最多命中一次；新一轮重新洗牌，并避免与上一轮末尾连续命中同一格。
- 下一 deadline 始终按 `now + changeInterval` 重算；睡眠 / 阻塞恢复后不追赶历史次数。
- 若新旧 card id 相同，不发布 flip 变化，但仍维护未来 deadline。
- 空槽 / Reduce Motion 模式由 ViewModel 决定不调度。

### 5.4 失败测试先行

- [ ] 空池保留正确槽位数，card / nextCard 为 nil。
- [ ] 单卡池填满但 `advance` 不伪报视觉变化。
- [ ] 首次 2 秒内不立即换卡。
- [ ] 正常 deadline 只随机换一个槽位，全局间隔为 3 秒。
- [ ] shuffle-bag 一轮覆盖全部槽位且不按索引顺序，跨轮不连续重复。
- [ ] 大时间跳跃只换一个槽位，并从当前时间重新计算 deadline。
- [ ] 固定 seed 的初始布局和推进结果可复现。
- [ ] 候选足够时，相邻 id 与 visualKey 都不重复。
- [ ] 候选不足时允许重复且不死循环。
- [ ] 0 / 负数行列、异常 interval 不崩溃并按配置策略处理。

### 5.5 命令

```bash
xcodegen generate
make test TEST_ARGS="-only-testing:StarcatTests/AmbientGridEngineTests"
```

预期：Suite PASS；失败时先修 Engine / 测试假设，不扩大到 UI。

## 6. Task 3：Card Factory、Local Catalog 与加载状态

**Files**

- Create `Starcat/Features/Ambient/Core/AmbientCardFactory.swift`
- Create `Starcat/Features/Ambient/App/LocalAmbientCatalog.swift`
- Create `Starcat/Features/Ambient/App/AmbientViewModel.swift`
- Create `StarcatTests/AmbientCardFactoryTests.swift`
- Create `StarcatTests/AmbientCatalogTests.swift`
- Create `StarcatTests/AmbientViewModelTests.swift`

### 6.1 Factory

`AmbientRepoSeed` 只携带 v1 与已明确预留字段：repo id、owner、fullName、ownerAvatarURL、language、starsCount、description。

- Repo id：`repo:<github-id>`；title：`owner/repo`；visualKey：`owner:<lowercased-owner>`。
- Owner 按 lowercased login 聚合，展示名保留第一条有效原始 casing。
- Owner id / visualKey：`owner:<lowercased-owner>`。
- avatar 优先 `repo.ownerAvatar`，缺失时使用 `RepoAvatarURL.from(owner:)`。
- v1 无论保留何种 density 枚举，都不填充 info / rich metadata。

### 6.2 Catalog

```swift
struct LocalAmbientCatalog: AmbientCatalogProviding {
    let repository: any RepoRepositoryProtocol

    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel]
}
```

- 直接传播 `fetchAllStarred()` 错误；只在 ViewModel / UI 边界记录一次日志。
- 不将错误转换为 `[]`。
- 不访问 `Database.shared`；使用 `dependencies.repoRepository` 注入。

### 6.3 ViewModel 状态

```swift
enum AmbientLoadFailure: Equatable, Sendable {
    case repositoryUnavailable
}

enum AmbientLoadState: Equatable {
    case idle
    case loading
    case empty
    case loaded([AmbientSlotSnapshot])
    case failed(AmbientLoadFailure)
}
```

- `@MainActor @Observable final class AmbientViewModel` 在本 Task 先独占 Catalog、Engine、加载 Task 和调度 Task；Task 4 接入有界 prefetcher。
- `load(scene:layout:reduceMotion:)` 以 scene + layout identity 作为代际；旧 Task 完成后必须先检查代际 / cancellation。
- `failed` 保存类型化错误类别，由 View 按当前 locale 映射文案；不缓存已本地化 String，也不暴露底层数据库路径或 SQL。
- 关闭窗口、切场景、窗口失活时取消调度；恢复时用最新 uptime 推进，依赖 Engine 的去积压逻辑。
- Reduce Motion 打开时构建静态首屏后停止，不启动调度 Task；运行中切换设置时立即取消 / 恢复。

### 6.4 测试

- [ ] Repo minimal 字段和 visualKey 正确。
- [ ] Owner 聚合大小写不敏感，数量和展示名稳定。
- [ ] Catalog 成功、空数组、repository 抛错分别保持语义。
- [ ] 场景快速切换时旧结果不能覆盖新结果。
- [ ] Reduce Motion 不创建持续调度。

### 6.5 命令

```bash
xcodegen generate
make test TEST_ARGS="-only-testing:StarcatTests/AmbientCardFactoryTests -only-testing:StarcatTests/AmbientCatalogTests -only-testing:StarcatTests/AmbientViewModelTests -only-testing:StarcatTests/AmbientGridEngineTests"
```

## 7. Task 4：专用 Artwork 与有界预取

**Files**

- Create `Starcat/Features/Ambient/App/AmbientArtworkView.swift`
- Create `Starcat/Features/Ambient/App/AmbientImagePrefetcher.swift`
- Modify `Starcat/Features/Ambient/App/AmbientViewModel.swift`
- Create `StarcatTests/AmbientArtworkTests.swift`

### 7.1 AmbientArtworkView

- 不直接复用 `RemoteAvatar`：该组件固定圆形并将像素限制在 256，适用于列表头像而非全屏 tile。
- 复用 `GitHubAvatarURL` 的 URL 归一化思路与 Kingfisher cache，但允许按 `tilePointSize × backingScale` 请求 64…1024px。
- 使用 downsampling / target cache processor，避免把大于目标像素的原图常驻解码。
- 图片 `.scaledToFill()` 后按直角正方形裁切；tile 之间不能有圆角、间距或外边距，外层负责底部渐变标题遮罩。
- Kingfisher 自带 fade 与槽位 flip 不能叠加两套明显动画；Ambient 路径关闭内部 fade 或把它限制为只处理首次加载。

### 7.2 占位

- 从卡片 title 提取首个可见字母 / 字符。
- 背景色由 card id 稳定 hash 映射到一组低饱和颜色；不能使用 Swift 进程随机 `hashValue`。
- 标题仍可读；SF Symbol 是无法提取字符时的最后兜底。

### 7.3 预取

- 参考 `AwesomeSourceOpenGraph` 中 `ImagePrefetcher` 的生命周期持有方式。
- 每次快照只收集 `nextCard.artworkURLString`，标准化、去重后预取；数量上限为 slotCount。
- 场景 / layout identity 变化时取消旧 prefetcher；禁止预取整个 stars 池。
- 当前图片和下一张图片共享同一规范化 cache key，确保预热真正命中显示路径。

### 7.4 验证

- [ ] 80pt、200pt、Retina 大 tile URL 的像素参数符合边界。
- [ ] 相同 URL 不重复预取。
- [ ] 快速切场景会取消旧预取。
- [ ] 断网 / 非法 URL 使用稳定占位，不影响轮换。

```bash
xcodegen generate
make test TEST_ARGS="-only-testing:StarcatTests/AmbientArtworkTests -only-testing:StarcatTests/AmbientViewModelTests"
```

## 8. Task 5：Ambient 全屏窗口生命周期

**Files**

- Create `Starcat/Features/Ambient/App/AmbientWindowController.swift`
- Create `Starcat/Features/Ambient/App/AmbientRootView.swift`
- Create `StarcatTests/AmbientWindowLifecycleTests.swift`

### 8.1 选型

Ambient 是进入后立即全屏、退出后销毁的短生命周期媒体窗口，使用窄 `NSWindowController` 合理；不要再写“对齐 `AgentWorkspaceWindowController` 单例 AppKit 模式”，当前 Agent 实际由 SwiftUI `Window(id:)` 承载。

SwiftUI 根必须：

```swift
AmbientRootView(...)
    .appHostEnvironment(dependencies)
    .preferredColorScheme(.dark)
```

### 8.2 Window 配置

- 逻辑标题使用 `String.l10n("ambient.window.title")`，即使 titlebar 隐藏也保留可访问名称。
- `styleMask` 至少包含 `.titled / .closable / .resizable / .fullSizeContentView`，隐藏可见 titlebar。
- `collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]`。
- `tabbingMode = .disallowed`；不设置 restoration identifier，不在启动时恢复。
- 使用 `NSApp.keyWindow?.screen ?? NSScreen.main` 选择显示器，只用于初始窗口放置；网格列数从 SwiftUI 实际 content geometry 计算。
- 背景为纯黑，进入全屏前不闪白。

### 8.3 生命周期状态机

用可单测的纯枚举表示：

```text
closed → opening → enteringFullScreen → fullScreen
                     ↓ fail              ↓ requestClose / system exit
                   closing ← exitingFullScreen
```

- 相同场景重复 `show`：激活现有窗口，不重建。
- 不同场景重复 `show`：取消旧 ViewModel Task，在同一窗口切换场景并重新加载。
- `requestClose`：若已全屏则标记 pending close 并 `toggleFullScreen(nil)`；只在 `windowDidExitFullScreen` 后 `close()`。
- 进入过程中收到关闭：等待 `windowDidEnterFullScreen` 后立即退出，避免重复 toggle。
- `windowDidFailToEnterFullScreen`：记录一次诊断并关闭，不能留一个无边框普通窗口。
- 用户按 Esc 或通过系统动作退出全屏：`windowDidExitFullScreen` 最终关闭 Ambient。
- `windowWillClose`：取消加载、调度和预取，清理 singleton。
- 窗口失去 key / App 失活时暂停调度；恢复后由 Engine 重新铺开 deadline。

### 8.4 测试与冒烟

- [ ] 正常打开 → 进入 → 请求退出 → 退出完成 → 关闭。
- [ ] 进入中快速退出不会重复 toggle。
- [ ] 全屏进入失败必达关闭态。
- [ ] 重复同场景复用；切场景只保留新代际。
- [ ] 本 Task 只验证状态机和 Window 构造；最终 DEBUG 菜单在 Task 7 接线后做真实窗口冒烟，不添加第二套临时调用。

## 9. Task 6：无缝满铺网格与单格 Y 轴翻转

**Files**

- Create `Starcat/Features/Ambient/App/AmbientGridView.swift`
- Create `Starcat/Features/Ambient/App/AmbientCellView.swift`
- Modify `Starcat/Features/Ambient/App/AmbientRootView.swift`

### 9.1 几何

在 `GeometryReader` 中使用实际 content size：

1. `tileSide = max(1, height / 5)`，横纵间距与外边距均为 0。
2. `columnCount = max(1, ceil(width / tileSide))`，保证内容宽度不小于 viewport。
3. 整张网格水平居中，viewport 裁掉左右超出部分；边缘 tile 允许只显示局部，不缩小 tile。
4. tile 内 artwork 使用 `scaledToFill + clipped`，并移除圆角，保证图片彼此无缝拼接。
5. geometry / backing display 变化时 debounce 后重建 layout identity；重建不做整屏动画。

标题在 tile 内部遮罩，不额外增加高度，从而保证 5 行真正落在可见区域。

### 9.2 单格转场

- 使用以 slot id 稳定定位的容器；旧卡在 0.4s 内转到 90°，侧面不可见时无动画换面，新卡再用 0.4s 从 -90° 转回正面。
- 只有 `AmbientAdvanceResult.changedSlotIDs` 对应槽位执行 0.8s Y 轴翻转；layout 重建、初始加载、错误恢复不触发翻转。
- 翻转角度不越过 ±90°，避免展示镜像背面；`starcatReduceMotion` 时 ViewModel 不推进 Engine。
- cell 不使用 `Button`，不产生 hover / focus ring；退出按钮若 `.buttonStyle(.plain)` 必须 `.focusEffectDisabled()`。

### 9.3 Root 四态

- loading：轻量 `ProgressView` + 退出。
- empty：`ambient.empty.title` / `ambient.empty.message` + 退出。
- failed：`ambient.error.title` / `ambient.error.message` + 重试 / 退出。
- loaded：纯黑网格 + 右上角低干扰退出入口；该入口不能在普通观看时抢占视觉焦点。

### 9.4 视觉 Gate

- [ ] Repo 卡为 square artwork + `owner/repo` 底部遮罩，不呈现“圆头像 + 下方文字”的联系人列表。
- [ ] Owner 卡同构，只显示 owner login。
- [ ] 五行图片墙零间距、零外边距，左右只裁图片、不出现黑边。
- [ ] 变化位置随机且无从左到右扫描感；翻转中不出现镜像、白闪或新旧卡穿帮。
- [ ] 相邻格尽量不出现相同 artwork；缺图占位彼此可区分。
- [ ] 首次加载、单格切换、慢网占位到图片的过渡没有双重 fade 或白闪。
- [ ] 生成运行时截图供 dong4j 验收；构建通过不能替代视觉验收。

## 10. Task 7：菜单入口与 i18n

**Files**

- Modify `Starcat/App/StarcatApp.swift`
- Modify `Starcat/Resources/Localizable.xcstrings`

### 10.1 菜单

在 `#if DEBUG` 的 `DebugMenuCommands` 菜单中加入两个入口：

```swift
Button("ambient.menu.openRepos") { ... }
Button("ambient.menu.openOwners") { ... }
```

- `dependencies == nil` 时禁用。
- 不新增第二套 command router 状态；入口只调用 `AmbientWindowController.show(dependencies:scene:)`。
- 2026-09-05 审查时 `StarcatApp.swift` 已有预存修改。开工时重新核对，编辑前后审查该文件 diff；提交时不能把非 Ambient hunk 一起暂存。
- 接线完成后从两个最终 DEBUG 菜单入口分别做全屏冒烟；禁止留下第二套临时调用。

### 10.2 本地化 key

| Key | zh-Hans | en |
|-----|---------|----|
| `ambient.window.title` | Ambient | Ambient |
| `ambient.menu.openRepos` | Ambient · 仓库 | Ambient · Repositories |
| `ambient.menu.openOwners` | Ambient · Owner | Ambient · Owners |
| `ambient.loading` | 正在准备 Ambient… | Preparing Ambient… |
| `ambient.empty.title` | 还没有可展示的 Star | No stars to display |
| `ambient.empty.message` | 同步一些仓库后再打开 Ambient | Sync some repositories, then open Ambient |
| `ambient.error.title` | 无法载入 Ambient | Couldn’t load Ambient |
| `ambient.error.message` | 请重试，或退出后再打开 | Try again, or exit and reopen Ambient |
| `ambient.retry` | 重试 | Retry |
| `ambient.exit` | 退出 | Exit |

### 10.3 Catalog 写入验证

编辑前先记录 `wc -l Starcat/Resources/Localizable.xcstrings`，编辑后必须不小于该基线。

```bash
git diff --stat -- Starcat/Resources/Localizable.xcstrings
wc -l Starcat/Resources/Localizable.xcstrings
jq empty Starcat/Resources/Localizable.xcstrings
rg -n '^[[:space:]]*"[^"]+":' Starcat/Resources/Localizable.xcstrings
rg -n '^[[:space:]]*"[^"]+" :[^ ]' Starcat/Resources/Localizable.xcstrings
```

要求：只新增目标 key，删除行为 0，行数不减少，JSON 合法，冒号格式检查无输出。

## 11. Task 8：收口验证

### 11.1 静态检查

```bash
xcodegen generate
git diff --check
rg "String\(localized:" --type swift Starcat/
rg "NSLocalizedString" --type swift Starcat/
```

新增 Swift 文件后必须再次 `xcodegen generate`。本地化两项搜索只能命中允许的注释 / 既有例外，不得新增调用。

### 11.2 测试

跑测前关闭 Xcode IDE。

```bash
make test TEST_ARGS="-only-testing:StarcatTests/AmbientGridEngineTests -only-testing:StarcatTests/AmbientCardFactoryTests -only-testing:StarcatTests/AmbientCatalogTests -only-testing:StarcatTests/AmbientViewModelTests -only-testing:StarcatTests/AmbientArtworkTests -only-testing:StarcatTests/AmbientWindowLifecycleTests"
make test
```

要求：Ambient 相关 Suite 和全量单测均 PASS；若全量测试存在已知非本改动失败，必须分开报告证据，不能把 targeted PASS 写成全量 PASS。

### 11.3 双渠道构建

```bash
make build-appstore
make build-direct
```

两套 scheme 都必须通过；不运行 package / release 脚本。

### 11.4 运行时验收

至少用一个正式 `.app` 前台运行验证：

1. 0 stars：空态、退出正常。
2. repository 抛错：错误态、重试、退出正常，不显示为空态。
3. 1 张 / 小于槽位 / 大池：不崩溃、不死循环、不整屏齐换。
4. Repo：square artwork、`owner/repo`、相邻相同 owner 头像尽量避开。
5. Owner：聚合大小写正确，不混入 Repo 标题。
6. Esc、退出按钮、系统退出全屏都最终销毁窗口。
7. 相同入口重复打开复用；Repo ↔ Owner 快速切换无旧结果覆盖。
8. 主显示器、外接显示器和窄窗口均满铺无黑边；左右边缘 tile 裁切合理，布局不依赖 `NSScreen.main`。
9. 睡眠 / 唤醒或人为暂停后只局部恢复，不追赶积压。
10. 系统 Reduce Motion 或 App“关闭动画”打开后静态展示，不存在后台 Timeline。
11. 中文 / 英文、慢网 / 断网、缺图占位可读。
12. 连续运行 10 分钟观察 CPU、内存、图片请求与缓存命中；无持续 30fps 重绘和无界预取。

运行时截图和观察结果单独报告；它们不能由单测或构建结果代替。

### 11.5 Git 安全

- 禁止 `git add -A`、`git add .`。
- 只暂存明确的 Ambient 新文件；对已有脏文件使用逐 hunk 审查，确保不带入用户原修改。
- 提交前分别执行：

```bash
git diff -- Starcat/Features/Ambient \
  Starcat/App/StarcatApp.swift \
  Starcat/Resources/Localizable.xcstrings \
  StarcatTests/AmbientGridEngineTests.swift \
  StarcatTests/AmbientCardFactoryTests.swift \
  StarcatTests/AmbientCatalogTests.swift \
  StarcatTests/AmbientViewModelTests.swift \
  StarcatTests/AmbientArtworkTests.swift \
  StarcatTests/AmbientWindowLifecycleTests.swift
git diff --cached --name-only
git diff --cached --check
```

未暂存的新文件不会出现在普通 `git diff --check` 中；若本次没有 commit / stage 授权，对每个未跟踪 Ambient 文件执行 `git diff --no-index --check /dev/null <file>`。该命令因“文件有差异”返回 1 属正常，只有输出具体 whitespace 错误才算失败。

- 是否创建 commit 取决于本次实施授权；没有明确授权时只交付工作树变更与验证证据。
- 不 push、不改远端、不写功能总览。

## 12. Spec 覆盖矩阵

| Spec 要求 | Task / Gate |
|-----------|-------------|
| App 内当前显示器独占全屏 | Task 5、运行时 6–8 |
| Repo / Owner 独立场景 | Task 3、5、7 |
| 无缝满铺 + 随机单格翻转 | Task 2、6 |
| minimal + 密度枚举预留 | Task 1、3 |
| 手动菜单入口 | Task 7 |
| 全部 stars 快照 | Task 3 |
| 纯观赏 | Task 6 |
| Catalog / Engine 可移植 | Task 1–3 |
| 空池 / 小池 / 数据错误 | Task 2、3、8 |
| 大尺寸清晰 artwork | Task 4、视觉 Gate |
| 下一张有界预取 | Task 2、4 |
| Reduce Motion 静态分支 | Task 3、6、运行时 10 |
| 休眠恢复不整屏齐换 | Task 2、运行时 9 |
| 多显示器真实 geometry | Task 5、6、运行时 8 |
| App Store / Direct | Task 8 |
| 系统 `.saver` | 不实现；只保留 Core 边界 |
| info / rich UI、设置页、空闲自动 | 不实现 |

## 13. Out of Scope

- `.saver` bundle、App Group 快照管道、安装与分发。
- 设置页行数 / 间隔 / 密度 UI。
- info / rich 数据装配与展示。
- 点击卡片打开 Repo / Owner。
- 空闲自动进入、阻止系统睡眠或 `caffeinate`。
- 数据库 schema / migration、后端服务、CloudKit。
- `docs/功能实现总览.md`、Changelog、package、release、push。
