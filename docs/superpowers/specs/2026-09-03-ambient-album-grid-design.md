# Ambient 专辑网格（App 内）设计

> 状态: 已讨论确认；2026-09-05 按运行时验收改为无缝满铺、随机单格翻转
> 范围: App 内 Ambient v1；系统 `.saver` 屏保仅预留边界，不在本迭代实现
> 非目标: 空闲自动进入、点卡打开业务页、信息密度 B/C 的完整 UI

## 1. 背景与目标

Starcat 希望提供类似 macOS **经典 Album Artwork 屏保**的氛围体验：多行网格，格子内封面按间隔自动轮换。素材来自用户 star 过的仓库（及由其聚合的 owner），而不是音乐专辑封面。

**v1 目标**

- 在 App 内以系统独占全屏展示 Ambient
- 两种**独立场景**：Repo 卡 / Owner 卡（一次只播一种）
- 视觉与换卡节奏对标经典 Album Artwork（无缝满铺 + 随机单格翻转），不对标自由漂浮拼贴
- 架构上抽出可移植 Core，便于后续做系统屏保壳

**明确不做（v1）**

- 系统 Screen Saver（`.saver`）分发与安装
- 空闲自动进入
- 滚动浏览完整素材池
- 点击卡片打开 Repo / Owner 详情
- 信息密度「信息卡 / 富卡」的完整展示（枚举先预留）

## 2. 产品决策（已锁定）

| 项 | 决策 |
|----|------|
| 形态 | App 内 Ambient，系统独占全屏 |
| 场景 | Repo / Owner 分开，一次一种 |
| 运动 | 经典网格；全局每 3 秒随机选择一个槽位做 Y 轴翻转 |
| 信息密度 | 两边都预留 `minimal / info / rich`；v1 只实现 `minimal` |
| 入口 | 手动（当前仅 DEBUG 菜单） |
| 素材池 | 当前账号全部 stars；Owner 由这些 stars 聚合 |
| 交互 | 纯观赏；Esc 或明确退出离开 |
| 架构 | 可移植 Core + 薄壳（App Ambient 现在；`.saver` 以后） |
| 显示器 | v1 只占用触发入口所在窗口的当前显示器；不复制到全部显示器 |
| 视觉主题 | Ambient 是媒体展示特例，固定深色纯黑背景，不跟随主工作区浅色表面 |

### 2.1 极简档（v1）展示内容

- **Repo 卡**: owner logo + `owner/repo`
- **Owner 卡**: avatar + owner login

后续档位字段（本迭代不渲染，仅模型预留）：

- Repo `info`: + language / stars 等 1–2 元数据；`rich`: + description / 摘要
- Owner `info`: + starred repo 数等；`rich`: 再加统计 / 简介

### 2.2 v1 视觉契约

- 每个槽位是一张**正方形 artwork tile**；网格零间距、零外边距、无圆角，按高度固定 5 行，横向多取完整一列并居中裁切，允许屏幕两侧只露出部分 tile。
- tile 内图片使用 `scaledToFill` 并裁切，不要求完整展示原始 Logo；标题放在底部渐变遮罩上，避免“头像在上、文字在下”的联系人列表观感。
- Repo 与 Owner 都使用专用 `AmbientArtworkView`，只复用 Kingfisher 缓存链路，不直接复用面向 32–80pt 圆形头像的 `RemoteAvatar`。
- 图片请求按 tile 的实际 point 尺寸与 backing scale 计算，不能沿用 256px 上限；解码尺寸仍必须受当前 tile 像素尺寸约束，禁止下载后按原图常驻。
- Repo 卡不同 id 可能共享同一 Owner 头像。抽卡除避免相邻 `card.id` 重复外，还要尽量避免相邻 `visualKey`（标准化头像 URL）重复。
- 缺图或加载失败使用“稳定首字母 + 由稳定 id 派生的低饱和背景色”，保证不同卡仍可区分；SF Symbol 只作为最后兜底。
- 固定 `.dark` color scheme，文字 / 图标仍使用 `.primary` / `.secondary`；纯黑背景是本场景经过产品定义的例外，不外溢到主窗口视觉语言。

## 3. 换卡模型

「采样 / 池」是**后台候选集合**，不是整屏翻页单位。

1. **候选池**: 全部 Repo 卡，或聚合后的 Owner 卡
2. **在场槽位**: 固定 `行 × 列` 网格；每个格子独立持有当前卡与预选下一张卡
3. **随机位置**: Engine 用 seeded shuffle-bag 打乱槽位；一轮内每格最多命中一次，跨轮避免连续命中同一格，既随机又不会长期遗漏
4. **单格生命周期**: 全局 deadline 到点 → 旧卡翻到 90° → 侧面不可见时换成已预热的下一张 → 新卡从 -90° 翻回正面 → 预选并预热新的下一张
5. **抽卡启发式**: 下一张卡本身也随机，并尽量避免与邻格、刚下屏的 id / visualKey 立即重复；池小于格子数时允许重复
6. **时间基准**: 使用单调时间（`ContinuousClock` 或等价 uptime），不得用墙钟时间驱动状态机
7. **休眠恢复**: 每次只换一个槽位，下一 deadline 从当前 `now` 重新计时，禁止追赶积压导致连续快闪

默认全局每 **3 秒**翻转一个槽位，单次翻转总时长 **0.8 秒**，首次变化延后 **2 秒**。约 40 个槽位时，每个位置平均约 2 分钟轮换一次。

用户感知：画面缓慢持续变化，但变化位置无扫描顺序，也不是静态墙突然换一批。

## 4. 架构

```text
AmbientCatalogProviding  -->  AmbientGridEngine  -->  壳（快照 → 像素）
        ^                         ^
        |                         |
   App: 读本地库            无 SwiftUI / 无窗口
   屏保: App Group/快照      可单测
```

### 4.1 Core（可测、无 UI）

建议落在独立目录（例如 `Starcat/Features/Ambient/Core/` 或后续可抽 framework），禁止依赖：

- SwiftUI
- 具体 `Database.shared` / App 单例窗口
- Kingfisher（头像解析留在壳或通过协议注入）

核心类型：

| 类型 | 职责 |
|------|------|
| `AmbientSceneKind` | `.repos` / `.owners` |
| `AmbientDensity` | `.minimal` / `.info` / `.rich` |
| `AmbientCardModel` | 稳定 id、visualKey、主标题、artwork 引用、可选副标题 / 元数据 |
| `AmbientGridConfig` | 行列、全局换卡间隔、翻转时长与首次延迟 |
| `AmbientSlotSnapshot` | 当前卡与预选下一张卡，供 UI 展示 / 预热 |
| `AmbientGridEngine` | 纯值槽位状态机：按单调时间与 seeded shuffle-bag 推进、返回下一 deadline；不使用 `@unchecked Sendable` |
| `AmbientCatalogProviding` | 提供 `[AmbientCardModel]`（repos / owners） |

### 4.2 壳 A — App Ambient（本迭代实现）

- `#if DEBUG` 菜单提供「Ambient · Repos」「Ambient · Owners」直达入口，暂不暴露给 Release 用户
- 使用专用 AppKit `NSWindowController` 承载短生命周期媒体窗口；这不是对 Agent 工作台 SwiftUI Scene 的照搬
- 从触发入口所在 key window 的 `screen` 建窗；布局始终读取窗口实际 content geometry，不使用 `NSScreen.main` 推算
- `collectionBehavior` 使用 `.fullScreenPrimary + .fullScreenDisallowsTiling`，禁止 tab；窗口不参与启动恢复
- 进入 / 退出全屏使用显式生命周期状态；任何全屏退出完成后关闭 Ambient，进入失败则关闭并显示可诊断日志
- 相同场景重复打开只激活现有窗口；不同场景入口在同一窗口中切换并取消旧加载任务
- 薄视图按 Engine 快照画无缝网格；单格执行两段式 Y 轴翻转
- artwork 走专用大图视图与现有 Kingfisher 缓存；下一张提前预取；失败使用稳定首字母占位
- Esc / 退出控件离开全屏并关闭 Ambient
- App 不活跃或窗口不可见时暂停调度，不追赶积压；不使用 `caffeinate`，允许系统正常锁屏 / 睡眠

### 4.3 壳 B — 系统屏保（以后）

- 同一 `AmbientGridEngine` + 同一 card model
- `ScreenSaverView` 绘制网格
- 另实现 `AmbientCatalogProviding`（App Group 或导出快照）；**不假设能直连主库**
- 分发更适合 Direct 渠道；App Store 安装系统屏保约束另案评估

## 5. 设置预留

| 项 | v1 | 后续 |
|----|----|------|
| 场景 | Repo / Owner | 同左 |
| 密度 | 仅 `minimal` 生效 | 设置三档 |
| 网格行数 | 固定合理默认（贴近经典多行） | 可调 |
| 轮换间隔 | 全局每 3s 随机翻一格 | 可调 |
| 素材过滤 | 全部 stars | 标签 / 最近等 |

v1 可不做独立设置页；配置用代码默认值即可。枚举与 config 结构先留好，避免以后改 Engine API。

## 6. 数据与兜底

**App Catalog 实现（v1）**

- 进入 Ambient 时对当前库拍快照（不必实时跟随同步增量）
- Repo: 全部 stars → card
- Owner: 对 stars 按 owner 聚合 → card
- Catalog 使用 `async throws` 保留读取失败；UI 必须区分 loading / empty / loaded / failed，禁止把数据库错误伪装成 0 stars
- 场景切换或窗口关闭时取消旧加载；过期结果不得覆盖新场景

**兜底**

| 情况 | 行为 |
|------|------|
| 未登录或 0 stars | 全屏简短说明 + 可退出；不进入空网格空转 |
| Owner 聚合为空 | 同上 |
| 数据库读取失败 | 错误说明 + 重试 + 退出，不进入空网格 |
| 头像缺失 / 加载失败 | 占位 + 标题仍显示，轮换继续 |
| 池 &lt; 格子数 | 允许重复上屏 |
| 中途库变更 | v1 忽略；下次进入再快照 |

## 7. 性能约束

- 常驻展示贴图数量约为行×列；翻转中只保留当前显示面，预取缓存另计但必须有界
- Engine 预选 `nextCard`，壳层只预热每槽下一张，减少闪空且避免无界预取
- Engine 持索引与轻量卡片，不在高频路径深拷全库
- 调度按 `nextDeadline` 事件驱动，禁止 30fps `TimelineView(.animation)` 常驻刷新
- 上千 stars 只影响池大小，不影响在场贴图上限
- `starcatReduceMotion == true` 时展示静态首屏，不创建持续 Timeline / Timer

## 8. 测试计划（Core 优先）

- 首次展示不会立即换卡；正常推进每次只随机更换一个槽位
- 一轮 shuffle-bag 覆盖全部槽位且不按索引顺序，跨轮不会连续命中同一格
- 大时间跳跃 / 睡眠恢复不会追赶积压或连续快闪，下一 deadline 从当前时间重新计算
- 小池 / 空池行为符合 §6
- 抽卡启发式：紧邻 id / visualKey 重复率在可测断言下可接受
- 单卡池不会伪报视觉变化；固定 seed 结果可复现
- `AmbientDensity.minimal` 快照不含 info/rich 必填依赖
- Catalog mock 下 Engine 可纯单元测试（不启动 App）
- Catalog 成功 / 空 / 抛错与场景切换取消均有测试
- 全屏生命周期状态机可脱离真实窗口单测；真实 Space / 多显示器行为走运行时验收

## 9. 实现分期

1. **Core + mock catalog + 单测**（deadline、预选下一张、休眠恢复与抽卡）
2. **App 数据 / artwork**: Catalog 状态、专用大图、预取与稳定占位
3. **App 壳**: 全屏生命周期、极简 Repo / Owner 场景、菜单入口
4. **打磨与验收**: 无缝满铺网格、随机翻转、Reduce Motion、多屏、错误态与性能
5. **以后**: 密度 B/C、设置项、`.saver` 壳与快照管道

## 10. 已锁定默认值与布局边界

- 行数默认 5；tile 为正方形，标题叠在 tile 内，不额外增加行高。
- tile 边长为实际 content height ÷ 5；横纵间距与外边距均为 0，列数按 `ceil(contentWidth / tileSide)` 计算，整墙居中并裁掉左右超出部分。
- 全局换卡间隔 3s、Y 轴翻转总时长 0.8s、首次换卡延后 2s；本轮不实现滚动。
- 菜单文案为「Ambient · 仓库」「Ambient · Owner」；i18n key 采用 `ambient.*`。

## 11. 运行时验收门槛

- Repo / Owner、0 / 1 / 小池 / 大池、数据库错误、缺图 / 慢网 / 断网均可退出且状态正确。
- 相同场景重复打开、场景切换、快速 Esc、全屏进入失败、睡眠恢复不崩溃、不整屏齐换。
- 主屏 / 外接屏 / 窄屏使用窗口真实 geometry；网格无间隙且无黑色外边，左右边缘允许按屏幕裁切 tile；退出全屏后窗口销毁，不在下次启动恢复。
- `starcatReduceMotion` 下静态展示；中英文、系统缩放、VoiceOver 可读逻辑标题与退出按钮。
- 相关单测通过，App Store / Direct 双渠道构建通过；至少一次真实 `.app` 前台运行和 10 分钟 CPU / 内存 / 网络观察。

## 12. 与主进度文档的关系

本功能属 P2 / 品牌氛围向。**未获 dong4j「可以写总览」授权前，不修改 `docs/功能实现总览.md`。** 需要登记时另提勾选文案与 `> 实现:` 草稿。
