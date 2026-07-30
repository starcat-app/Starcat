//
//  SidebarHeaderView.swift
//  Starcat
//
//  Sidebar 顶部用户信息卡片。
//
//  布局参考用户提供的设计图：
//  - 头像（圆形，56pt）
//  - 显示名 + @login
//  - 三栏统计：本地 Starred / 远程 Followers / 远程 Following
//  - 点击头像 → 跳转 GitHub 主页；左上角"…"按钮 → popover：退出登录；右上角分享按钮 → 分享卡 sheet
//
//  设计约束：
//  - 用 popover 而非 Menu，避免 macOS 26 toolbar 上 Menu(label: custom view)
//    导致的 sizing bug（详情见 docs/工程进度/2026-05-30 评审）
//  - 数据来源：本地 starred 计数走 HomeViewModel.totalCount；
//    Followers/Following 走 AuthSession 的 user 字段（首次 /user 调用时拉到）
//  - 未授权态：不渲染（Sidebar 在登录后才挂载）
//

import SwiftUI
import AppKit

struct SidebarHeaderView: View {

    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var viewModel
    /// 用于打开 macOS 原生设置窗口（SettingsLink 的 programmatic 等效方式）
    @Environment(\.openSettings) private var openSettings
    /// 系统级"减少动效"开关，开启时把"渐变流动"退化为静态版（仍保留四周淡出 + 颜色切换补间）。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    /// HOM-173：分享卡需要消费贡献草坪 payload；ContributionService 已在 AppDependencies 注入。
    @Environment(ContributionService.self) private var contributionService
    /// HOM-174：Pro 用户标识需要从 AppSettings 获取。
    @Environment(AppSettings.self) private var appSettings
    @Environment(AppDependencies.self) private var dependencies
    /// 用户名 Pro 渐变随明暗主题切换：浅色要保证对比度，深色对齐暖色头像环。
    @Environment(\.colorScheme) private var colorScheme
    /// 2026-06-06 A 方案：accountMenu 中"刷新个人信息"项触发 `load(force: true)`，
    /// 同时让贡献草坪和开发语言也跟着刷一下（用户主动刷新时一并更新）。
    @Environment(UserProfileService.self) private var userProfileService
    /// 分享卡 Top Languages 使用用户自有公开仓库语言统计，不使用 starred 项目语言分布。
    @Environment(DeveloperLanguageService.self) private var developerLanguageService

    /// 当前在 Trending 页面选中的 repo（仅在 Trending 页面有效，Manage 页面为 nil）。
    ///
    /// 用于让 sidebar 头像背景的语言色在 Trending 页也能联动：
    /// - Manage 页面：用 `viewModel.selectedRepo?.language`
    /// - Trending 页面：用 `trendingRepo?.language`
    /// `HomeView` 持有真源 `@State selectedTrendingRepo`，通过 `SidebarView` 透传到这里。
    /// 取色优先级：Manage 选中 > Trending 选中 > Activity 选中 > `.accentColor`（系统蓝兜底）。
    var trendingRepo: TrendingRepo?
    /// 当前在 Activity 页面选中卡片的强调色。
    ///
    /// `ActivityItem.accentColor` 已经把“repo 主语言色优先、无语言时分类色兜底”的规则收口，
    /// 这里只消费最终颜色，避免 SidebarHeaderView 反向理解 Activity 的分类 / repo 细节。
    var activityTintColor: Color?

    /// 登录表单 sheet 显示状态。
    @State private var showLoginSheet: Bool = false

    /// HOM-173：分享卡 sheet 显示状态。
    /// 点击头像左侧分享图标时打开；sheet 关闭回调置回 false。
    @State private var showShareCardSheet: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            switch authSession.state {
            case .authenticated(let user):
                avatarRow(user: user)
                identity(user: user)
                // HOM-PROFILE 2026-06-05：bio + 个人主页快捷链接图标行；
                // 全部字段为空时该 view 自身不渲染内容，不会浪费垂直空间。
                ProfileLinksRow(user: user)
                statsRow(user: user)
            case .unauthenticated, .awaitingUserCode, .awaitingWebCallback:
                // 2026-06-29：把 .awaitingWebCallback 也归到 unauthenticated 显示分支
                // ——sidebar 头像卡不需要区分"正在走哪个 flow"，反正都是未登录态
                unauthenticatedAvatarRow()
                unauthenticatedIdentity()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(alignment: .top) { sidebarTintBackground }
        // HOM-175：防御性兜底，强制整张头像卡严格按内容尺寸（垂直方向不被拉伸）。
        // 即便未来子视图（avatarRow / ProfileLinksRow / statsRow）再次引入垂直
        // flexible 元素（Spacer / .frame(maxHeight: .infinity) 等），SidebarHeaderView
        // 整体高度依然由 ideal size 决定，不会与同栏的 sidebarList 抢占可用高度。
        // 水平方向继续随父级宽度扩展（保持 sidebar 240~320pt 范围内填满）。
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
                .appLocaleEnvironment()
        }
        // HOM-173：分享卡 sheet。仅在登录态可触发（按钮本身只在 authenticated 行渲染）。
        // 闭包里取 user 是为了避开 SwiftUI sheet 闭包捕获 outer state 的延迟问题——
        // sheet 内部不再读 authSession.state，避免登出态飘进卡片导致空内容。
        .sheet(isPresented: $showShareCardSheet) {
            if case .authenticated(let user) = authSession.state {
                ShareCardSheet(
                    user: user,
                    starredCount: viewModel.totalCount,
                    contribution: contributionService.payload,
                    developerLanguages: developerLanguageService.snapshot,
                    isProUser: appSettings.isProUser,
                    onClose: { showShareCardSheet = false }
                )
                .environment(dependencies.userProfileService)
                .appSheetRootEnvironment(dependencies)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gettingStartedOpenShareCardRequested)) { _ in
            guard case .authenticated = authSession.state else { return }
            showShareCardSheet = true
            NotificationCenter.default.post(name: .gettingStartedDidShareProfile, object: nil)
        }
        .onChange(of: authSession.state) { _, newState in
            if newState.isAuthenticated {
                showLoginSheet = false
            } else {
                // 登出时强制关闭分享卡（防止后台 sheet 残留显示旧用户信息）
                showShareCardSheet = false
            }
        }
    }

    // MARK: - 选中 repo 语言色背景

    /// 当前选中 repo 的语言色 → 头像卡区主题色。
    ///
    /// 取色优先级（沿用 `LanguageColor.color(for:)` 单一信任源，与列表 row / 详情页 hero 同源）：
    /// 1. Manage 页面选中 repo 的 `language`（`viewModel.selectedRepo?.language`）
    /// 2. Trending 页面选中 repo 的 `language`（`trendingRepo?.language`，2026-06-02 21:38 接入）
    /// 3. Activity 页面选中卡片的 `accentColor`（2026-06-05 接入；repo 语言色优先，分类色兜底）
    /// 4. 都没选中 → `.accentColor`（系统蓝兜底）
    ///
    /// 设计上 Manage / Trending 同时只能有一个选中：
    /// - 切到 Trending 页面时 `HomeView.onChange(of: selectedSidebarPage)` 会清掉 Manage 选中
    /// - 反之亦然
    /// 所以"优先 Manage"的顺序在正常状态下不会有歧义；保留这个顺序仅作防御性兜底。
    private var sidebarTintColor: Color {
        if let language = viewModel.selectedRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let language = trendingRepo?.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        if let activityTintColor {
            return activityTintColor
        }
        return .accentColor
    }

    /// 头像卡背景：双层 LinearGradient mask 组合成椭圆 vignette，4 个角 + 4 个边中点
    /// alpha 都自然淡出至 0，从根本上消除"色块硬边"。
    ///
    /// 演进史（**不要回退到 v2/v3 实现**）：
    /// - **v1（LinearGradient 顶到底）**：dong4j 反馈左右底硬边突兀。
    /// - **v2（RadialGradient + 2-stop）**：四周稍柔但仍有硬边可见。
    /// - **v3（RadialGradient + 大 endRadius + 高中段 stops）**：反而更糟——
    ///   中段 stops 太亮（0.55→45% / 0.85→12%）让 view 内大部分点都是高 alpha，
    ///   view 边界外突然 alpha=0（被 clip），高 alpha → 0 alpha 对比让硬边更显眼。
    /// - **v4（当前）**：双层 LinearGradient mask 相乘形成 vignette，物理上保证
    ///   view 边界 alpha=0（无硬切），同时中部聚焦保留色块存在感。
    ///
    /// 物理根因（v3 教训）：圆形径向 mask 在矩形 view 内，要么 alpha=0 区域超出
    /// view 边界（被 clip 出硬边），要么完全内嵌（只覆盖中心小区域），两难。
    /// 横纵向独立控制 alpha（vignette 思路）才能让矩形 view 4 边都自然淡出。
    ///
    /// 双层 mask 设计：
    /// - **`verticalFadeMask`**：顶部 alpha 100% → 底部 alpha 0%（保留 v1 顶亮底淡形态）
    /// - **`horizontalFadeMask`**：左右两侧 alpha 0% → 中部 alpha 100%（左右淡出）
    /// - **相乘** = 中部聚焦的椭圆 vignette：所有 view 边界点 alpha 接近 0。
    ///
    /// 持续流动动效：两层 mask 的关键 stops 位置随时间正弦漂移，周期解耦
    /// （vertical 16s / horizontal 13s）形成 Lissajous-like 自然呼吸轨迹。
    /// `@Environment(\.starcatReduceMotion)` 开启时退化为静态 stops 避免前庭不适。
    ///
    /// 关键技术铁律（已踩坑，**不要再犯**）：
    /// SwiftUI 的 `LinearGradient(colors:)` / `RadialGradient(colors:)` 中 colors 数组
    /// 不是 animatable property，直接套 `.animation(value:)` 切颜色是瞬切、没有补间。
    /// 必须把"颜色"和"形态"分开：颜色交给 `Shape.fill(_: Color)`，形态/动画交给 mask。
    ///
    /// `opacity(0.35)` 比 v3 (0.32) 略提：vignette 让大部分 view 已是低 alpha 区，
    /// 中心区需要提一档保证视觉存在感。`.allowsHitTesting(false)` 不挡上层按钮点击。
    private var sidebarTintBackground: some View {
        Group {
            if reduceMotion {
                sidebarTintFrame(time: 0)
            } else {
                // 横纵两层 mask 共用同一个时钟。旧实现建了两个 30 FPS
                // TimelineView，每帧各自使整个 header 重新求值；慢呼吸动画
                // 收敛到单个 12 FPS 时钟后视觉节奏不变；12 能整除 60/120 Hz，
                // 且对 9~15 秒周期的慢渐变足够连续。
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    sidebarTintFrame(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .animation(
            reduceMotion || dependencies.sidebarAnimationCoordinator.suppressSidebarTintAnimation
                ? nil
                : .easeInOut(duration: 0.45),
            value: sidebarTintColor
        )
        .allowsHitTesting(false)
    }

    private func sidebarTintFrame(time: TimeInterval) -> some View {
        Rectangle()
            .fill(sidebarTintColor.opacity(0.35))
            .mask(verticalFadeMask(time: time))
            .mask(horizontalFadeMask(time: time))
            // HomeView 的 toolbar 背景透明后，把光晕继续绘制到标题栏区域；只忽略
            // 顶部 safe area，避免改变 SidebarHeaderView 自身的布局尺寸和命中区域。
            .ignoresSafeArea(edges: .top)
    }

    /// 头像卡背景的 alpha mask：径向"中心亮 → 四周柔和淡出"形态，并按时间做"漂移 + 呼吸"。
    ///
    /// **消除四周分界线的两个关键设计**（dong4j 2026-06-02 21:07 反馈"四周还是有明显颜色分界"修正）：
    /// 1. **`endRadius` 大幅扩大到 ~320pt**（远大于 sidebar header 区对角线约 270~300pt），
    ///    让 alpha=0 的位置落在 view 边界**之外**——边界处 alpha 已经接近 0，
    ///    色块自然融入周围 `.bar` material，看不出截断硬边。
    /// 2. **`Gradient(stops:)` 多档非线性过渡**（4 个 stop 模拟 ease-out 衰减曲线）：
    ///    - 0% 全黑（中心最亮），25% 还保留 88% alpha（中心区聚焦），
    ///    - 55% 衰到 45% alpha（中段平滑），85% 衰到 12% alpha（边缘很淡），100% 完全透明。
    ///    比 2-stop 线性 black → transparent 的淡出尾巴长一倍，肉眼几乎看不到"色块结束"。
    ///
    /// reduceMotion 开启 → 静态径向 mask（center 居中、固定 endRadius=320），同样套用多档 stops。
    /// reduceMotion 关闭 → 与横向渐变共享同一个 12 FPS `TimelineView` 驱动：
    /// - center 在 [0.32, 0.68] × [0.30, 0.60] 范围内正弦漂移（x/y 周期解耦，约 11s / 15s，
    ///   形成无规律 Lissajous 轨迹，更像"自然呼吸"而非简单往复）；
    /// - endRadius 在 [260, 380]pt 内呼吸（约 9s 周期，base 320 ± 60）。
    ///
    /// 12 FPS 对这种慢呼吸足够流畅，并避免两个 mask 各自创建刷新时钟。
    /// 振幅刻意保守（中心点 ±18%、半径 ±60pt），让色块"飘"而不是"飞"，不抢 sidebar 列表注意力。
    /// 第一层 mask：中部最饱和、上下都淡出的纵向 vignette。
    ///
    /// **22:27 改动**（dong4j 反馈"顶部分界线还是太明显"）：
    /// 之前顶部 stop 是 `Color.black, location: 0.00`（alpha=1.0），意味着视图顶部
    /// 就是 100% 满饱和——直接和 titlebar 形成硬色边。修复：把顶部 stop 改为
    /// `Color.black.opacity(0.00)`，让 `0.00 → peakPosition` 这段成为"线性淡入区"。
    /// 按头像区 ~200pt 高度算，淡入区覆盖 36~84pt（视 peakPosition 飘移而定），
    /// 顶部 30pt 内 alpha 从 0 缓慢爬升，肉眼不再有硬分界。
    ///
    /// 设计权衡：损失一点"顶部色块感"（前 30pt 几乎看不到 tint），但换来与 titlebar
    /// 的无缝过渡，符合"四周都渐变"的需求。如果以后又想加强顶部，可以把 0.00 处的
    /// opacity 从 0 调到 0.10~0.15 之间——保留极弱底色但仍无硬边。
    ///
    /// reduceMotion → 静态 stops（peakPosition 固定 0.18）；动效模式下 peakPosition
    /// 在 [0.10, 0.26] 漂移（约 16s 周期），让"高亮区"在头像上下缓慢游走，形成呼吸感。
    /// 顶部 0.0 和底部 1.0 处始终 alpha=0，保证上下边界淡出干净（无硬切）。
    ///
    /// **2026-06-05 调整**（HOM-PROFILE follow-up，dong4j 反馈）：
    /// 新增 `ProfileLinksRow` 后整个 header view 高度从 ~170pt 涨到 ~210pt，
    /// 之前 peakPosition 0.30 在新高度下落到 ~63pt（identity 行附近，已经过头像底部），
    /// 视觉上"渐变背景偏下了"。把 peakPosition 从 0.30 → 0.18（约 38pt 位置，
    /// 落在头像中部）；同时让中段衰减 stop 提前（0.80 → 0.62），让色块上移聚焦头像，
    /// 链接行和 stats 区域所在的下半部分尽量透明，不与下方草坪/导航栏抢色。
    /// 漂移振幅相应收窄 0.12 → 0.08，避免下移时又落到 identity 行。
    private func verticalFadeMask(time: TimeInterval) -> some View {
        let peakPosition = 0.18 + sin(time * 0.38) * 0.08
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.black.opacity(0.00), location: 0.00),
                .init(color: Color.black, location: peakPosition),
                .init(color: Color.black.opacity(0.30), location: 0.62),
                .init(color: Color.black.opacity(0.00), location: 1.00)
            ]),
            startPoint: .top, endPoint: .bottom
        )
    }

    /// 第二层 mask：左右淡出（左右边界 alpha=0、中部 alpha=100%），消除"左右两条硬色边"。
    ///
    /// reduceMotion → 静态 stops（左右各 28% 区域是淡出区，中部 44% 是全亮区）；
    /// 动效模式下中心点在 [-0.10, 0.10] 横向漂移（约 13s 周期，与垂直周期 16s 解耦避免同步往复），
    /// 让色块的"水平亮度中心"轻微左右浮动，配合 vertical mask 形成 Lissajous-like 自然呼吸轨迹。
    private func horizontalFadeMask(time: TimeInterval) -> some View {
        let centerOffset = sin(time * 0.48) * 0.10
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.black.opacity(0.00), location: 0.00),
                .init(color: Color.black, location: 0.28 + centerOffset),
                .init(color: Color.black, location: 0.72 + centerOffset),
                .init(color: Color.black.opacity(0.00), location: 1.00)
            ]),
            startPoint: .leading, endPoint: .trailing
        )
    }

    // MARK: - 未登录态

    private func unauthenticatedAvatarRow() -> some View {
        ZStack(alignment: .topTrailing) {
            UserAvatar(
                isLoggedIn: false,
                avatarUrl: nil,
                login: nil,
                onLoginTapped: { showLoginSheet = true }
            )
            .gettingStartedAnchor(.signIn)
        }
    }

    private func unauthenticatedIdentity() -> some View {
        VStack(spacing: 2) {
            Text("auth.unauthenticated")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
    }

    // MARK: - 头像行（含账户菜单入口）

    private func avatarRow(user: GitHubUserDTO) -> some View {
        // 头像 + 左右两个浮动按钮。
        // - 左上角：分享卡按钮
        // - 右上角：账户菜单
        // 两按钮垂直对齐，share 与 ellipsis 都用 16pt SF Symbol 保持高度一致。
        // 之所以用 ZStack 而非把按钮塞在 UserAvatar 内：
        // ① UserAvatar 是 Button（点击跳 GitHub 主页），把另一个 Button 嵌进它的 label 里
        //    会产生嵌套 Button 的命中冲突；外层 ZStack 让两个按钮各自独立可点。
        // ② 与右上角已有的 accountMenu() 处理方式保持一致。
        //
        // **HOM-175 2026-06-06 修复（dong4j 反馈：窗口最大化时头像区域被拉长）**：
        // 之前用两个 `VStack { HStack {...}; Spacer() }` 把按钮推到顶部。
        // `Spacer()` 在垂直方向是无限灵活的（min 0、max ∞），
        // 让两个 VStack 的 ideal 高度变成"想要无限大"，
        // 进而让 ZStack 的 ideal 高度也变成"想要无限大"。
        // 这条灵活性传染到外层 `VStack(spacing: 10)`、`SidebarHeaderView`、
        // `SidebarView` 最外层 `VStack(spacing: 0) { sidebarFixedHeader; sidebarList }`，
        // 与 `sidebarList`（List 本身也 flexible）一起变成"按比例分配可用高度"，
        // 窗口越高 → sidebarFixedHeader 越被拉长 → ZStack 内 UserAvatar 居中显示，
        // profile links 行和 stats 区域之间凭空多出一段空白。
        //
        // 修复：用 `ZStack(alignment: .top)` 让所有子项顶部对齐，
        // 并把两个独立 VStack 合并成一条 HStack（左按钮 + Spacer + 右按钮）。
        // 此时 ZStack ideal 高度 = max(UserAvatar 高 62pt, HStack 高 22pt) = 62pt，
        // 不再含 Spacer → 不再 flexible → 不再传染拉伸。
        // HStack 内部水平方向上的 `Spacer()` 不影响垂直 ideal 高度，是合法用法。
        //
        // 视觉上完全等效：原方案中按钮也是顶对齐（VStack 顶部 = ZStack 顶部 = 头像顶部）。
        ZStack(alignment: .top) {
            // 头像（最底层）
            UserAvatar(
                isLoggedIn: true,
                avatarUrl: user.avatarUrl,
                login: user.login,
                status: user.activeStatus,
                avatarCacheVersion: user.updatedAt,
                onLoginTapped: { showLoginSheet = true }
            )
            .gettingStartedAnchor(.signIn)

            // 顶部浮动按钮行：左侧分享卡入口、右侧账户菜单。
            HStack {
                shareCardButton()
                Spacer()
                accountMenu()
            }
        }
    }

    /// HOM-173：分享卡入口按钮。
    /// 头像右侧的浮动图标（2026-06-06 由左侧调换至右侧），
    /// 与左侧"…"账户菜单图标垂直对齐（同样 16pt）。
    /// 点击打开 `ShareCardSheet`，导出当前登录用户的"星际杂志卡 v2"。
    @ViewBuilder
    private func shareCardButton() -> some View {
        Button {
            showShareCardSheet = true
            NotificationCenter.default.post(name: .gettingStartedDidShareProfile, object: nil)
        } label: {
            Image(systemName: "square.and.arrow.up.circle")
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .gettingStartedAnchor(.shareProfile)
        .help(Text("sharecard.button.help"))
        .accessibilityLabel(Text("sharecard.button.help"))
    }

    /// 账户操作菜单。使用 SwiftUI 原生 Menu 组件，自带圆角、hover 反馈等系统样式。
    @ViewBuilder
    private func accountMenu() -> some View {
        Menu {
            Button {
                openSettings()
            } label: {
                Label("settings.general.title", systemImage: "gearshape")
            }

            // 2026-06-06 A 方案 D5-B：手动刷新个人信息入口。
            // 触发 UserProfileService / ContributionService / DeveloperLanguageService 同时 force refresh。
            // GitHub Stars List 属于当前账号的远端资料；用户主动刷新个人信息时也顺手同步一次。
            // 拉到后 profile service 反向 push 给 AuthSession.state，sidebar 自然更新；分享卡数据用 service 快照更新。
            if let login = authSession.state.user?.login {
                Button {
                    userProfileService.load(login: login, force: true)
                    contributionService.load(login: login, force: true)
                    developerLanguageService.load(login: login, force: true)
                    Task { await refreshGitHubStarLists(login: login) }
                } label: {
                    Label("sidebar.account.refreshProfile", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                // signOut 改 async（2026-06-12 多账号 DB 隔离要 await DB 切换完成），
                // SwiftUI Button action 是同步闭包，包 Task 触发即可。
                Task { await authSession.signOut() }
            } label: {
                Label("auth.signOut", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("sidebar.account"))
    }

    // MARK: - 显示名 + login

    /// 显示用户身份信息：有 name 时显示 name，无 name 时显示 login
    /// 避免 name 与 login 相同时显示两个重复项
    @ViewBuilder
    private func identity(user: GitHubUserDTO) -> some View {
        VStack(spacing: 2) {
            if let name = user.name, !name.isEmpty {
                identityNameText(name)
            } else {
                identityNameText(user.login)
            }
        }
    }

    @ViewBuilder
    private func identityNameText(_ value: String) -> some View {
        let text = Text(value)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)

        if appSettings.isProUser {
            // Pro 用户名渐变分主题：浅色走冷色可读谱，深色走暖色头像环谱。
            text.foregroundStyle(proIdentityNameGradient)
        } else {
            text
        }
    }

    /// 侧栏 Pro 用户名渐变（随 `colorScheme` 切换）。
    ///
    /// - **深色**：对齐 `UserAvatar.proAvatarRing` 暗色暖环（粉 → 橙 → 金），短 login 不去冷蓝起手。
    /// - **浅色**：对齐浅色头像环的冷色家族（紫 → 靛 → 蓝），但全部用更深一档的色值；
    ///   环上的 `#B8D7FF` / 暖金 `#FDE68A` 在浅底上对比度不够，不能直接当文字色。
    private var proIdentityNameGradient: LinearGradient {
        let stops: [Gradient.Stop] = if colorScheme == .dark {
            [
                .init(color: Color.fromHex6(0xE879F9), location: 0.0),
                .init(color: Color.fromHex6(0xF472B6), location: 0.38),
                .init(color: Color.fromHex6(0xFB923C), location: 0.70),
                .init(color: Color.fromHex6(0xFDE68A), location: 1.0),
            ]
        } else {
            [
                .init(color: Color.fromHex6(0x7C3AED), location: 0.0),  // deep violet
                .init(color: Color.fromHex6(0x6366F1), location: 0.40), // indigo
                .init(color: Color.fromHex6(0x2563EB), location: 0.72), // blue
                .init(color: Color.fromHex6(0x0284C7), location: 1.0),  // sky，仍深于浅底
            ]
        }

        return LinearGradient(
            stops: stops,
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - 三栏统计

    /// 构建三栏统计数据行，每项均可点击并跳转到对应 GitHub 页面。
    /// - Starred → https://github.com/{username}?tab=stars
    /// - Followers → https://github.com/{username}?tab=followers
    /// - Following → https://github.com/{username}?tab=following
    private func statsRow(user: GitHubUserDTO) -> some View {
        HStack(spacing: 0) {
            StatCell(
                value: viewModel.totalCount,
                label: "sidebar.stats.starred",
                helpText: String.l10n("sidebar.openGithubStarred"),
                url: GitHubURLs.userStarsTab(login: user.login)
            )
            Divider().frame(height: 26)
            StatCell(
                value: user.followers ?? 0,
                label: "sidebar.stats.followers",
                helpText: String.l10n("sidebar.openGithubFollowers"),
                url: GitHubURLs.userFollowersTab(login: user.login)
            )
            Divider().frame(height: 26)
            StatCell(
                value: user.following ?? 0,
                label: "sidebar.stats.following",
                helpText: String.l10n("sidebar.openGithubFollowing"),
                url: GitHubURLs.userFollowingTab(login: user.login)
            )
        }
        .padding(.top, 4)
    }

    private func openGitHubProfile(login: String) {
        NSWorkspace.shared.open(GitHubURLs.userProfile(login: login))
    }

    private func refreshGitHubStarLists(login: String) async {
        await dependencies.githubStarListSyncService.sync(login: login)
        await viewModel.refreshSidebar()
        if viewModel.selection.isGitHubStarListContext {
            await viewModel.reloadItems(forceRefresh: true)
        }
    }
}

// MARK: - 子组件

/// 单个统计列（数字 + 标签）。
///
/// - Parameters:
///   - value: 要显示的数字
///   - label: 统计标签（Starred / Followers / Following）
///   - url: 可选链接；传入时数字会变为可点击链接，点击后在新标签页打开对应 GitHub 页面
private struct StatCell: View {
    let value: Int
    let label: LocalizedStringKey
    let helpText: String
    let url: URL?

    var body: some View {
        // 2026-06-05 dong4j 反馈：数字与 label 字号差太小，视觉上几乎一样大。
        // 改为数字 19pt/.bold（约为 caption2 的 ~1.7x），形成明显的"主-辅"层级。
        // 间距 2 → 3：字号放大后保持 baseline 视觉呼吸。
        VStack(spacing: 3) {
            if let url = url {
                // 2026-06-02 dong4j 要求统一 hover 反馈：sidebar 三栏统计数据
                // （Starred / Followers / Following）加 `.pressableHover()`，
                // 与详情页 Stats 按钮保持同款交互反馈。
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(value, format: .number)
                        .font(.system(size: 19, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover()
                .help(helpText)
            } else {
                Text(value, format: .number)
                    .font(.system(size: 19, weight: .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
