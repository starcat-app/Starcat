//
//  ShareCardSheet.swift
//  Starcat
//
//  HOM-173 用户分享卡片：sheet 容器视图。
//
//  这是用户点击 sidebar 头像左侧分享按钮后看到的整个面板，包含：
//  - 顶部标题栏（标题 + 关闭按钮）
//  - 版式选择 + 配色选择（先选结构，再选颜色）
//  - 卡片预览区（实时跟随主题切换）
//  - 三个动作按钮：保存为图片 / 分享到 X / 关闭
//  - 底部品牌注脚（"由 Starcat 生成"，可点击跳到 starcat.ink）
//
//  设计权衡：
//  - 把"主题选择 + 预览 + 动作"放在 sheet 而不是 popover：
//    分享卡需要 ~520pt 高度做完整预览，popover 在 sidebar 旁会被裁切；
//    sheet 居中浮在主窗口上层，体验更接近"导出图前最后确认"的语义。
//  - 选择不持久化：每次打开默认 `.magazine + .githubGreen`（最贴合 GitHub 用户群体），
//    避免引入额外 AppSettings 字段；用户 365 天里调整一次主题的概率远低于
//    "每次都按当前心情选"。
//  - "分享到 X" 按钮触发后**保留 sheet 不关闭**：因为该路径会唤起浏览器，
//    用户可能想回来再点"保存为图片"备份；显式让用户点关闭。
//

import SwiftUI

/// 分享卡 sheet 主视图。
struct ShareCardSheet: View {

    /// 当前登录用户。从 sidebar 调用方传入（已确保 authenticated）。
    let user: GitHubUserDTO

    /// 本地 starred 数量（与 sidebar 同源）。
    let starredCount: Int

    /// 贡献草坪 payload（可能为 nil；nil 时分享卡显示空网格但仍可分享）。
    let contribution: ContributionCalendarPayload?

    /// 用户自己公开仓库的开发语言快照。nil 时卡片显示加载/空态，不再误用 starred 语言分布。
    let developerLanguages: DeveloperLanguageSnapshot?

    /// 当前用户是否为 Pro 用户。Pro 用户头像显示 Pro 标识。
    let isProUser: Bool

    /// 关闭回调。由调用方持有 `@State var showShareSheet`，这里只负责发信号。
    let onClose: () -> Void

    /// HOM-174：导出 Starred 记录需要访问 RepoRepository。
    /// 通过 `@Environment(AppDependencies.self)` 注入（root 在 StarcatApp 已挂上 dependencies）。
    @Environment(AppDependencies.self) private var dependencies

    /// 2026-06-06 A 方案：sheet 打开时静默 force refresh 一次，
    /// 让分享卡 / HTML 导出拿到的 user profile（followers / bio / 头像）尽量新鲜。
    /// 后台拉到后通过 AuthSession.acceptRefreshedUser 反向 emit，
    /// 上层 sidebar 传给 `user: GitHubUserDTO` 参数会自然更新（SwiftUI re-init）。
    @Environment(UserProfileService.self) private var userProfileService

    /// 当前选中的卡片版式。版式负责结构，不再和颜色绑死。
    @State private var selectedStyle: ShareCardStyle = .magazine

    /// 当前选中的卡片配色。原编号 1-5 的主题现在都是 magazine 版式下的颜色。
    @State private var selectedColor: ShareCardColorSet = .githubGreen

    /// 最近一次操作的反馈文案（"已保存到 …" / "已复制到剪贴板…"）。
    /// 不弹系统 alert，仅在 sheet 内顶部 toast-like 提示，3 秒后自动隐藏。
    @State private var lastActionFeedback: String?

    /// 当前正在执行的动作（"保存中…" / "导出中…"），用于禁用按钮防止重复点击。
    @State private var isExporting: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    /// HOM-174 v4：导出进行时显示的进度文案；nil 表示无活动导出。
    /// HTML 导出会经历"读 starred → 拉摘要/标签/头像 → 渲染"几个阶段，单纯禁用按钮
    /// 用户没有可视反馈（尤其 Kingfisher cache miss 时 owner 头像批量下载耗时数秒）。
    ///
    /// **v4 设计迭代（dong4j 2026-06-06 反馈）**：原来用全 sheet 半透明 overlay 太重，
    /// 改为内联 pill —— 与 `lastActionFeedback` 共用反馈区位置，进行时显示带菊花的
    /// progress pill，结束后自动让位给"已导出至 …"反馈 pill；视觉零侵入。
    @State private var exportProgressMessage: String?

    // MARK: - 按钮 hover 状态（v8 follow-up：行动按钮 hover 反馈）
    //
    // 转自定义实现后失去了 native button 的 hover 高亮，必须手动补——给每个按钮
    // 独立的 @State 跟踪 hover，hover 时按钮背景叠一层 10% 白色提亮（mimic
    // macOS native button 标准 hover 反馈，无论 light/dark 都能看到"准备点击"感）。
    //
    // **为什么不用 .pressableHover()**：`PressableHover` 是给"图标 / 头像 / 文字按钮"
    // 设计的（opacity 0.7 + scale 1.06）——行动按钮 400pt 宽、40pt 高的大块，scale
    // 1.06 会撞到周围，opacity 0.7 让按钮"消失感"反而不像可点击。
    @State private var shareToXHovered: Bool = false
    @State private var saveImageHovered: Bool = false
    @State private var exportFileHovered: Bool = false

    /// 行动按钮 hover 反馈的动画时长（秒）。reduceMotion 模式下归零。
    /// 抽出来是为了三个按钮的 hover 动画时长保持一致。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 分享卡 Top Languages 的开发语言服务。sheet 打开时触发一次 TTL 加载，导出时读取最新快照。
    @Environment(DeveloperLanguageService.self) private var developerLanguageService

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 12) {
                themePicker

                cardPreview

                actionButtons
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        // 分享卡本体保持 400×560；这里只裁掉 sheet 早期 820pt 高度留下的底部背景空白。
        // 内容总高低于主窗口运行期最小 content 高度 763pt，初始窗口下不会再向底部凸出。
        .frame(width: 480, height: 760)
        .background {
            // HOM-173 v3：sheet 整体动态背景（Metal `swDotsFlow` 流场）。
            //
            // 为什么这么挂：
            // - 放在 sheet 根 VStack 的 `.background { ... }` 而不是 `cardPreview`
            //   内部——dong4j 明确要求是"窗口背景"，不是卡片背景。
            // - 顶部 `header` 用了 `.background(.bar)` 半透明 material，会透出 flow
            //   细节，是想要的效果；`cardPreview` 的 ShareCardContent 自带不透明
            //   palette 背景，会盖住中间一块矩形（保证卡片本身可读性）；ScrollView
            //   外层无 background，flow 在卡片四周空白处正常流动。
            // - `tint: .accentColor` 让背景跟随系统强调色（且分享卡 5 套主题色相不一，
            //   用品牌色比绑定某一主题色更协调）；`opacity(0.45)` 是经验值——再高
            //   会抢卡片视觉权重，再低基本看不见。
            // - `vignette: 0` 必须关掉，sheet 自身已限定 480×820 边界，再叠 vignette
            //   会让画面塌成中心一团。
            // - `background: .clear` 不传也是默认值，但显式写出来便于排查
            //   "为什么背景被盖住了"——见 DotsFlowBackground.swift 文件头第 3 条约束。
            //
            // 性能：单实例最多 30 FPS 重绘；关闭应用内动画时渲染静态帧，sheet 关闭后
            // `TimelineView` 自动停。不要叠多个。
            //
            // 注意：导出图（performSave / performShareToX 经 ImageRenderer）不会包含
            // 此背景——SwiftUI snapshot 不渲染 Metal shader 帧。这是预期行为：
            // 导出的卡片图保持纯卡片本体，背景仅作为 sheet 浏览时的视觉装饰。
            // HOM-173 v3 最终版（dong4j 2026-06-06 20:42 诊断 B 后修复）：
            //
            // 诊断结果：红色看得见（.background modifier + ScrollView 透明都 OK），
            // 但完全没流动点 → 证明 Metal shader 没被调用。
            // 根因：原版 DotsFlowBackground 默认 `background: .clear`，但 SwiftUI
            // `.colorEffect` 对 `Color.clear` 这种"无像素 view"不触发 fragment
            // shader——必须给一个不透明色才能让 shader 跑起来。详见
            // DotsFlowBackground.swift 文件头第 3 条约束（已踩过的坑 #1）。
            //
            // 修复方案：传不透明 `.black` 底让 shader 正常渲染 → 用
            // `.blendMode(.plusLighter)` 让黑色像素"加 0 = 不变"自动消失，
            // 只把亮的 dot 加到 sheet 原 material 上，形成"亮点流动"叠加效果。
            //
            // v3.1（2026-06-17）明亮主题适配：dark 下 `accentColor + plusLighter` 在
            // material 灰底上对比足够；light 下 accent 偏浅、加亮后几乎融进白底看不见。
            // light 改走 `浅金 tint + multiply`——shader 白底上画金色点，multiply 压暗
            // 浅灰 sheet，纹理可见且仍保持"装饰背景"语义。注意这里不能靠降低
            // brightness 让粒子变淡：shader 内部是 `fg = tint * brightness`，在
            // multiply 下亮度越低越接近黑色，点会反而更深。
            sheetDotsFlowBackground
                // 背景只是装饰，不允许参与 hit-test。主题按钮很小，明确禁用背景命中可避免
                // 用户点到按钮边缘时事件落到背景层，表现成 hover/click 随机失效。
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: exportProgressMessage)
        .task {
            // sheet 打开时强制刷一次 profile（D5-B 决策）。
            // 沉默执行：UserProfileService 内部 inflight 互斥；TTL 内的复用不会阻塞。
            // 拿到新数据后通过 acceptRefreshedUser 回写 AuthSession.state，
            // 调用方 SidebarHeaderView.onChange(of: authSession.state) 会重建 sheet 透传新的 user。
            userProfileService.load(login: user.login, force: true)
            developerLanguageService.load(login: user.login)
        }
        // 2026-06-16 i18n root cause #4：SwiftUI sheet 在 macOS 上 **不会**自动从父
        // scene 继承 `\.locale` environment(实测分享卡 sheet 子树查到的 locale 是
        // `Locale.autoupdatingCurrent` = 系统中文,无视主 scene 注入的 LocaleStore)。
        // `appLocaleEnvironment()` 显式挂回 LocaleStore.shared.selection.effectiveLocale,
        // 让 `Text("key")` / `Label("key", ...)` 等 SwiftUI 路径能拿到正确 locale。
        // 这与 `LocaleStore.swift` 顶部"sheet 自动继承"注释的假设矛盾,该假设已被
        // 实测打脸,需要一并更新。详见 `Starcat/Shared/Utilities/L10n.swift`。
        .appLocaleEnvironment()
    }

    /// sheet 动态背景：dark / light 各走一套 blend，保证两种系统主题下点阵都可见。
    @ViewBuilder
    private var sheetDotsFlowBackground: some View {
        if colorScheme == .dark {
            DotsFlowBackground(
                tint: .accentColor,
                background: .black,
                speed: 0.35,
                brightness: 0.9,
                vignette: 0.0
            )
            .blendMode(.plusLighter)
        } else {
            DotsFlowBackground(
                tint: Color.fromHex6(0xFDE68A),
                background: .white,
                speed: 0.35,
                brightness: 1.0,
                vignette: 0.0
            )
            .blendMode(.multiply)
        }
    }

    /// 保存 / 导出反馈。放在 header 同一行，避免盖住底部按钮。
    @ViewBuilder
    private var feedbackOverlay: some View {
        if let msg = exportProgressMessage {
            progressPill(text: msg)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        } else if let feedback = lastActionFeedback {
            feedbackPill(text: feedback)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        }
    }

    // MARK: - 顶部标题栏

    /// 顶部标题栏：标题 + 同行反馈 + 关闭按钮。
    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
                Text("sharecard.title")
            }
            .font(.system(size: 16, weight: .semibold))

            Spacer()

            feedbackOverlay
                .frame(maxWidth: 270)

            Spacer()

            SheetCloseButton(
                action: onClose,
                helpKey: "sharecard.action.close"
            )
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        // 2026-06-25：加大 top 内边距，避免标题 / 反馈 pill / 关闭钮贴窗口顶缘；
        // 垂直预算从选择器按钮尺寸回收。
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: - 主题选择

    /// 版式 + 配色选择器。
    ///
    /// 2026-06-25：主题被拆成 Style × Color 两个维度。左侧选择版式，右侧只显示
    /// 当前版式支持的颜色。所有按钮都有固定外框和完整 contentShape，优先解决之前
    /// 小色块 hover/click 命中不稳定的问题。
    @ViewBuilder
    private var themePicker: some View {
        HStack(spacing: 8) {
            stylePicker

            Spacer(minLength: 6)

            colorPicker
        }
        // 顶部选择器跟 400pt 卡片本体同宽，左右边缘分别对齐预览卡片。
        .frame(width: 400)
    }

    /// 左侧版式选择：无文字 mini layout 预览，靠 tooltip / accessibility 暴露名称。
    @ViewBuilder
    private var stylePicker: some View {
        HStack(spacing: 4) {
            ForEach(ShareCardStyle.allCases) { style in
                StyleCardButton(
                    style: style,
                    isSelected: selectedStyle == style
                ) {
                    selectStyle(style)
                }
            }
        }
    }

    /// 右侧配色选择：只显示当前版式支持的颜色。
    @ViewBuilder
    private var colorPicker: some View {
        HStack(spacing: 4) {
            ForEach(selectedStyle.supportedColors) { colorSet in
                ColorSwatchButton(
                    colorSet: colorSet,
                    isSelected: selectedColor == colorSet
                ) {
                    selectedColor = colorSet
                }
            }
        }
    }

    /// 切换版式时校正配色，避免 ID 卡版式收到 magazine 配色这类无效组合。
    private func selectStyle(_ style: ShareCardStyle) {
        selectedStyle = style
        if !style.supportedColors.contains(selectedColor) {
            selectedColor = style.defaultColor
        }
    }

    /// 单个版式按钮。按钮外框固定，内部画抽象 wireframe，避免新增图片资源。
    private struct StyleCardButton: View {
        private static let buttonWidth: CGFloat = 22
        private static let buttonHeight: CGFloat = 18

        let style: ShareCardStyle
        let isSelected: Bool
        let action: () -> Void

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.starcatReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(buttonBackgroundColor)

                    stylePreview
                        .padding(2.5)
                }
                .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            borderColor,
                            lineWidth: isSelected ? 1.5 : (isHovered ? 0.8 : 0.5)
                        )
                )
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selectedBackgroundColor)
                )
            }
            // macOS plain Button 在小图标上偶发只按 label 绘制像素命中。
            // 外层重复声明同尺寸矩形命中区，保持现有尺寸不变但让 hover/click 走稳定区域。
            .frame(width: Self.buttonWidth, height: Self.buttonHeight)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(style.localizationKey))
            .accessibilityLabel(Text(style.localizationKey))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                    isHovered = hovering
                }
            }
        }

        /// 抽象版式预览：只表达信息块位置，不承诺最终卡片的像素级细节。
        @ViewBuilder
        private var stylePreview: some View {
            switch style {
            case .magazine:
                VStack(spacing: 1.4) {
                    miniLine(width: 14)
                    miniCircle
                    miniGrid
                }
            case .idCard:
                HStack(spacing: 2) {
                    miniTallBlock
                    VStack(spacing: 2) {
                        miniLine(width: 7)
                        miniLine(width: 8)
                        miniSquare
                    }
                }
            case .social:
                VStack(spacing: 2) {
                    miniCircle
                    HStack(spacing: 1.3) {
                        miniSquare
                        miniSquare
                        miniSquare
                    }
                    miniLine(width: 16)
                }
            case .terminal:
                VStack(alignment: .leading, spacing: 2) {
                    miniLine(width: 14)
                    miniLine(width: 9)
                    miniLine(width: 15)
                }
            case .adventure:
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(adventurePreviewBackgroundColor)
                    VStack(alignment: .leading, spacing: 1.3) {
                        miniCircle
                        miniLine(width: 12)
                        miniGrid
                    }
                }
            }
        }

        private var miniCircle: some View {
            Circle()
                .fill(styleAccentColor)
                .frame(width: 5, height: 5)
        }

        private var miniSquare: some View {
            RoundedRectangle(cornerRadius: 1)
                .fill(styleAccentColor.opacity(colorScheme == .dark ? 0.88 : 0.78))
                .frame(width: 4, height: 4)
        }

        private var miniTallBlock: some View {
            RoundedRectangle(cornerRadius: 1.4)
                .fill(styleAccentColor.opacity(colorScheme == .dark ? 0.84 : 0.72))
                .frame(width: 5, height: 11)
        }

        private var miniGrid: some View {
            HStack(spacing: 0.8) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.7)
                        .fill(styleAccentColor.opacity(index.isMultiple(of: 2) ? strongGridOpacity : weakGridOpacity))
                        .frame(width: 2, height: 2)
                }
            }
        }

        private func miniLine(width: CGFloat) -> some View {
            RoundedRectangle(cornerRadius: 0.8)
                .fill(lineColor)
                .frame(width: width, height: 1.4)
        }

        /// 暗色 sheet 的点阵背景会吃掉低透明度 primary；保持按钮尺寸不变，仅提高 chrome 对比度。
        private var buttonBackgroundColor: Color {
            colorScheme == .dark
                ? Color.white.opacity(isHovered ? 0.18 : 0.12)
                : Color.primary.opacity(isHovered ? 0.10 : 0.06)
        }

        private var selectedBackgroundColor: Color {
            isSelected
                ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.10)
                : Color.clear
        }

        private var borderColor: Color {
            if isSelected {
                return Color.accentColor
            }
            if colorScheme == .dark {
                return Color.white.opacity(isHovered ? 0.48 : 0.30)
            }
            return Color.primary.opacity(isHovered ? 0.34 : 0.18)
        }

        private var lineColor: Color {
            colorScheme == .dark
                ? Color.white.opacity(0.76)
                : Color.primary.opacity(0.52)
        }

        private var styleAccentColor: Color {
            colorScheme == .dark ? Color.accentColor.opacity(0.96) : Color.accentColor
        }

        private var strongGridOpacity: Double {
            colorScheme == .dark ? 0.86 : 0.75
        }

        private var weakGridOpacity: Double {
            colorScheme == .dark ? 0.46 : 0.28
        }

        private var adventurePreviewBackgroundColor: Color {
            Color.orange.opacity(colorScheme == .dark ? 0.30 : 0.18)
        }
    }

    /// 单个配色按钮。固定小尺寸外框，内部用单色表达当前配色的强调色。
    private struct ColorSwatchButton: View {
        private static let buttonWidth: CGFloat = 19
        private static let buttonHeight: CGFloat = 18

        let colorSet: ShareCardColorSet
        let isSelected: Bool
        let action: () -> Void

        @Environment(\.starcatReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(colorSet.pickerSwatch.accent)
                    .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.34 : 0.18),
                                lineWidth: isSelected ? 1.5 : (isHovered ? 0.8 : 0.5)
                            )
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                    )
                    .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(colorSet.localizationKey))
            .accessibilityLabel(Text(colorSet.localizationKey))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                    isHovered = hovering
                }
            }
        }
    }

    // MARK: - 卡片预览

    /// 卡片预览区。直接渲染 `ShareCardContent`（与导出图同源），缩放后嵌在 sheet 里。
    /// sheet 宽 480 - 24×2 padding = 432pt 可用，卡片本体 400pt，自然居中。
    @ViewBuilder
    private var cardPreview: some View {
        ShareCardContent(
            user: user,
            starredCount: starredCount,
            contribution: contribution,
            developerLanguages: developerLanguageService.snapshot ?? developerLanguages,
            style: selectedStyle,
            colorSet: selectedColor,
            isProUser: isProUser
        )
        // 卡片下方加柔和阴影区分 sheet material
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    // MARK: - 动作按钮

    /// HOM-174 follow-up：底部按钮与卡片宽度一致。
    ///
    /// **v6 调整（dong4j 2026-06-06）**：
    /// - 顺序调换："分享到 X"上移到第一行（主行动），保存/导出下移到第二行
    /// - 圆角统一 8：macOS 系统按钮原生圆角约 6-8，渐变按钮跟随；之前 22 偏激
    ///
    /// **v7 调整（dong4j 2026-06-06 20:48 反馈 X 按钮明显比保存按钮矮）**：
    /// - `actionButtonHeight` 从 32 提到 40：v6 注释里写"frame(height:32) 强制"
    ///   是误以为对所有按钮有效，**实测对 native button 只是建议**——SwiftUI
    ///   `.controlSize(.large)` 的 native button intrinsic height ~ 36-38pt，
    ///   会盖过 frame(32) 撑到 38 左右；X 按钮是纯自定义 view 严格遵守 frame
    ///   32 → 视觉上 X 按钮比另两个矮一截。
    /// - v7 修复策略：把 `actionButtonHeight` 提到 40 包络 `.controlSize(.large)`
    ///   实际渲染高度——**结果失败**，见 v8 注释。
    ///
    /// **v8 调整（dong4j 2026-06-06 20:52 反馈 v7 后保存按钮反而最高 ~50pt）**：
    /// v7 提到 40 还是没解决——`.borderedProminent` + `.controlSize(.large)` 在
    /// macOS 上 min padding 是硬规则，`.frame(height:40)` 对 native button **不能
    /// 强制压缩**只能撑大；`.bordered` 与 `.borderedProminent` 的 padding 又不同
    /// → 导出 / 保存看着也不齐。**用 native button 不同 style 永远做不到三按钮
    /// 等高**，根治办法只能全部转自定义。
    /// - 全部三个按钮转 `buttonStyle(.plain)` + HStack + RoundedRectangle 背景，
    ///   `frame(height: actionButtonHeight)` 真正生效（plain style 不带内 padding）。
    /// - 视觉层次靠**填色差异**而不是 padding：主行动（保存为图片）实色
    ///   `Color.accentColor` 填充；次行动（导出 Starred）`.regularMaterial` 半
    ///   透明 + 细边框；X 按钮保留蓝绿渐变。
    /// - 代价：失去 native button 的键盘焦点环 / hover 高亮 / system blue 主题
    ///   联动——分享卡 sheet 主要鼠标操作，影响可接受；按 CLAUDE.md UI 规范
    ///   `.buttonStyle(.plain)` 必须紧跟 `.focusEffectDisabled()`，已遵守。
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 10) {
            // 第一行：分享到 X（主行动，独占一行）
            shareToXButton
                .frame(width: 400)

            // 第二行：保存 + 导出文件
            HStack(spacing: 10) {
                saveImageButton
                exportFileButton
            }
            .frame(width: 400)
        }
    }

    /// 保存为图片按钮（v8：从 `.borderedProminent` 改为自定义实现）。
    /// accentColor 实色填充表达"主行动"，与 X 渐变按钮同一视觉层级（plain style
    /// + frame(actionButtonHeight) 严格等高 40pt）。
    ///
    /// **v8.1（dong4j 2026-06-06 20:59）**：加 hover 反馈，背景叠 10% 白色提亮。
    @ViewBuilder
    private var saveImageButton: some View {
        Button {
            Task { await performSave() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                Text("sharecard.action.save")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: actionButtonHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: actionButtonCornerRadius)
                        .fill(Color.accentColor)
                    // hover 高亮层：叠在实色 fill 之上、文字之下；
                    // 用条件 fill 而不是 if-then-else 让动画过渡平滑。
                    RoundedRectangle(cornerRadius: actionButtonCornerRadius)
                        .fill(Color.white.opacity(saveImageHovered ? 0.10 : 0))
                }
                .shadow(color: .black.opacity(saveImageHovered ? 0.20 : 0.12), radius: 4, y: 1)
            )
            .opacity(isExporting ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isExporting)
        .keyboardShortcut("s", modifiers: .command)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                saveImageHovered = hovering
            }
        }
    }

    /// 三个按钮统一高度（pt）。
    /// **40 是经验值**：包络 `.controlSize(.large)` native button 实际渲染高度
    /// （~ 36-38pt，因 borderedProminent / bordered padding 略不同），既保证
    /// native button 不被压缩，又能让自定义 X 按钮的 frame(40) 与之等高。
    /// 详见 `actionButtons` v7 注释。
    private var actionButtonHeight: CGFloat { 40 }
    /// 三个按钮统一圆角（pt）。8 与 macOS 系统 borderedProminent 默认圆角接近。
    private var actionButtonCornerRadius: CGFloat { 8 }

    /// 导出文件按钮（下拉菜单）。
    /// HOM-174 支持 Starred 导出；PR-9 在同一入口下追加知识库 HTML / Markdown 导出。
    ///
    /// **v8 调整（dong4j 2026-06-06 20:52）**：与 saveImageButton 同款重写为
    /// `Menu` + 自定义 label，表达"次行动"视觉层级。
    ///
    /// **v8.1（dong4j 2026-06-25）**：背景容器放进 label 最外层，并给 Menu 本体
    /// 补 `maxWidth + actionButtonHeight`。关键约束是不能用 `.borderlessButton`：
    /// macOS 会把自定义 label 当成系统默认按钮重画，吃掉背景、边框和 hover。
    /// `.menuStyle(.button)` + `.buttonStyle(.plain)` 才会保留我们自己画的 label。
    @ViewBuilder
    private var exportFileButton: some View {
        Menu {
            Button {
                Task { await performExportRepositories(scope: .starred, format: .html) }
            } label: {
                Label("sharecard.action.export.starred.html", systemImage: "doc.richtext")
            }

            Button {
                Task { await performExportRepositories(scope: .starred, format: .markdown) }
            } label: {
                Label("sharecard.action.export.starred.markdown", systemImage: "doc.text")
            }

            Divider()

            Button {
                Task { await performExportRepositories(scope: .library, format: .html) }
            } label: {
                Label("sharecard.action.export.library.html", systemImage: "heart.text.square")
            }

            Button {
                Task { await performExportRepositories(scope: .library, format: .markdown) }
            } label: {
                Label("sharecard.action.export.library.markdown", systemImage: "heart")
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: actionButtonCornerRadius)
                    .fill(Color.primary.opacity(exportFileHovered ? 0.08 : 0.055))
                RoundedRectangle(cornerRadius: actionButtonCornerRadius)
                    .stroke(Color.secondary.opacity(exportFileHovered ? 0.5 : 0.3), lineWidth: 0.5)

                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.system(size: 13, weight: .medium))
                    Text("sharecard.action.exportToFile")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.leading, 2)
                }
                .foregroundStyle(.primary)
                .opacity(isExporting ? 0.5 : 1.0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: actionButtonHeight)
            .contentShape(RoundedRectangle(cornerRadius: actionButtonCornerRadius))
        }
        .frame(maxWidth: .infinity)
        .frame(height: actionButtonHeight)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isExporting)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                exportFileHovered = hovering
            }
        }
    }

    /// "分享到 X"按钮。
    ///
    /// HOM-174 v5（dong4j 2026-06-06）：按用户提供的参考图改为水平蓝→绿渐变背景。
    /// 设计动机：相比原来的 `.background`（深浅主题各自一片纯色），渐变在两种主题下
    /// 视觉一致、亮度足够、辨识度高；同时跳出"另一个白卡片"的同质化感受。
    /// - 渐变两端取色：左 `#4FC3F7`（Material Light Blue 300）/ 右 `#76FF03`（Light Green A700）
    /// - 文字 + logo 强制 `.black`：因为渐变两端都是亮色，黑字在 dark/light 主题下都能看清
    ///
    /// **v6 调整（dong4j 2026-06-06）**：
    /// - 圆角 22 → `actionButtonCornerRadius`（8），与同行的保存/导出系统按钮一致
    /// - 内部布局改为：xLogo + 主文案（"分享到 X"） + Spacer + hint 文案右对齐
    ///   （hint = "把图片粘贴到推文里"，告诉用户操作流程：先复制图，再去 X 粘贴）
    /// - 显式 `frame(height: actionButtonHeight)` 与系统按钮等高
    ///
    /// **v7 调整（dong4j 2026-06-06 20:48）**：actionButtonHeight 32 → 40，
    /// 让 X 按钮真正与 `.controlSize(.large)` native button 同高（详见
    /// `actionButtons` 上的 v7 注释）。
    @ViewBuilder
    private var shareToXButton: some View {
        Button {
            Task { await performShareToX() }
        } label: {
            HStack(spacing: 10) {
                xLogo

                Text("sharecard.action.shareToX")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)

                Spacer()

                // hint 文案：右对齐告诉用户操作流程（"把图片粘贴到推文里"）。
                // 半透明黑（opacity 0.65）让 hint 视觉权重低于主文案，但在亮渐变上仍可读。
                Text("sharecard.action.shareToX.hint")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.65))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: actionButtonHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: actionButtonCornerRadius)
                        .fill(shareToXGradient)
                    // hover 高亮层：渐变之上叠 10% 白色提亮
                    RoundedRectangle(cornerRadius: actionButtonCornerRadius)
                        .fill(Color.white.opacity(shareToXHovered ? 0.12 : 0))
                }
                .shadow(color: .black.opacity(shareToXHovered ? 0.20 : 0.12), radius: 4, y: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isExporting)
        .help(Text("sharecard.action.shareToX.help"))
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                shareToXHovered = hovering
            }
        }
    }

    /// "分享到 X"按钮的渐变背景。水平方向，左清亮蓝 → 右亮绿。
    /// 取色参考 dong4j 2026-06-06 提供的截图。
    private var shareToXGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 79.0/255.0,  green: 195.0/255.0, blue: 247.0/255.0),  // #4FC3F7
                Color(red: 118.0/255.0, green: 255.0/255.0, blue: 3.0/255.0)     // #76FF03
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// X 品牌 logo 的本地拼写。
    /// v5：背景改渐变后，logo 固定 `.black`（亮色渐变上黑字 / 黑 logo 始终可读，
    /// 不再需要 `.primary` 跟随主题切换）。
    /// v6：按钮整体高度收为 32pt，logo 从 18pt/26x26 缩到 14pt/20x20，避免撑高按钮。
    @ViewBuilder
    private var xLogo: some View {
        Text("𝕏")
            .font(.system(size: 14, weight: .black, design: .default))
            .foregroundStyle(.black)
            .frame(width: 20, height: 20)
            .accessibilityLabel(Text("X"))
    }

    /// 反馈提示气泡（"已保存到 …" / "已复制图片到剪贴板…"）。
    /// 浅胶囊，带绿色对勾——3 秒后自动消失。
    @ViewBuilder
    private func feedbackPill(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.tertiary)
        )
        .frame(maxWidth: 270)
    }

    // MARK: - 动作执行

    /// 执行保存。
    /// 主线程同步走 NSSavePanel；用户取消时静默返回，不显示反馈。
    @MainActor
    private func performSave() async {
        isExporting = true
        defer { isExporting = false }
        let content = currentContent
        if let url = ShareCardExporter.saveImage(
            content: content,
            userLogin: user.login
        ) {
            showFeedback(String(format: String.l10n("sharecard.feedback.saved"), url.lastPathComponent))
        }
    }

    /// 执行分享到 X。
    /// 复制到剪贴板 + 打开 X 推文撰写页（用户在浏览器里 Cmd+V）。
    @MainActor
    private func performShareToX() async {
        isExporting = true
        defer { isExporting = false }
        let content = currentContent
        let ok = ShareCardExporter.shareToX(content: content, userLogin: user.login)
        if ok {
            showFeedback(String.l10n("sharecard.feedback.sharedToX"))
        }
    }

    /// 执行仓库文件导出。
    /// HOM-174 支持 Starred；PR-9 增加知识库导出，二者共用保存面板与反馈机制。
    ///
    /// 流程：
    /// 1. 按 scope fetch repos（Starred 只取 GitHub starred；Library 取 `libraryState == .inLibrary`）
    /// 2. 走 `StarredExporter.export` 渲染 + NSSavePanel + 写文件
    /// 3. 成功 → 显示反馈；失败 / 用户取消 → 沉默（不打扰）
    ///
    /// 失败原因（DB 读异常）映射为 `sharecard.feedback.exportFailed` 提示，
    /// 而不是 alert——分享卡 sheet 体验上沿用 toast-like feedback。
    @MainActor
    private func performExportRepositories(scope: RepositoryExportScope, format: StarredExportFormat) async {
        isExporting = true
        // HOM-174 v4：进度文案分阶段更新，给用户清晰的"App 在做什么"反馈。
        // 阶段一：fetching → 阶段二：渲染（HTML 含拉摘要/标签/头像，最耗时；
        // markdown 渲染瞬时）。defer 兜底确保任何返回路径都清掉 overlay。
        exportProgressMessage = String.l10n(scope == .library
            ? "sharecard.export.loading.fetchingLibrary"
            : "sharecard.export.loading.fetching")
        defer {
            isExporting = false
            exportProgressMessage = nil
        }

        let repos: [Repo]
        do {
            repos = try await fetchExportRepos(scope: scope)
        } catch {
            AppLog.ui.error("performExportRepositories: fetch repos failed: \(error.localizedDescription, privacy: .public)")
            showFeedback(String.l10n("sharecard.feedback.exportFailed"))
            return
        }

        guard !repos.isEmpty else {
            showFeedback(String.l10n(scope == .library
                ? "sharecard.feedback.exportLibraryEmpty"
                : "sharecard.feedback.exportEmpty"))
            return
        }

        // 阶段二文案：按格式区分（HTML 显式提示有摘要/标签/头像拉取，
        // 防止用户在数秒内以为 App 卡死；Markdown 文案简短）
        exportProgressMessage = String.l10n(format == .html
            ? "sharecard.export.loading.html"
            : "sharecard.export.loading.markdown")

        if let url = await StarredExporter.export(
            repos: repos,
            user: user,
            format: format,
            scope: scope,
            dependencies: dependencies
        ) {
            showFeedback(String(format: String.l10n("sharecard.feedback.exported"), url.lastPathComponent))
        }
        // 用户取消保存面板 → 不弹反馈，保持沉默体验，对齐 `performSave` 的同款行为
    }

    private func fetchExportRepos(scope: RepositoryExportScope) async throws -> [Repo] {
        switch scope {
        case .starred:
            return try await dependencies.repoRepository.fetchAllStarred()
        case .library:
            return try await dependencies.repoRepository.fetchKnowledgeRepos()
        }
    }

    // MARK: - 导出进度 pill（HOM-174 v4，dong4j 反馈后改 inline）

    /// 导出进行中的内联指示器：与 `feedbackPill` 同款胶囊外观，只是把对勾换成菊花。
    ///
    /// 设计取舍（dong4j 2026-06-06 反馈"全屏 overlay 太重"后调整）：
    /// - 不再用全 sheet 的半透明 backdrop（按钮已 `disabled(isExporting)`，无需视觉
    ///   再次强调"禁用"）；
    /// - 完全沿用 feedbackPill 的尺寸 / 圆角 / 背景，让"进行中 → 完成"是同位置同形态
    ///   的内容切换，视觉零位移；
    /// - 仅用菊花 + 文案，3 行高度上限，足够说明"App 在做事不是卡死了"。
    @ViewBuilder
    private func progressPill(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)  // 把 small ProgressView 再压小一点，与对勾视觉权重持平
                .frame(width: 16, height: 16)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.tertiary)
        )
        .frame(maxWidth: 270)
    }

    /// 当前要渲染的卡片内容（主题切换不重新构造卡片实例，但导出时要用最新值）。
    private var currentContent: ShareCardContent {
        ShareCardContent(
            user: user,
            starredCount: starredCount,
            contribution: contribution,
            developerLanguages: developerLanguageService.snapshot ?? developerLanguages,
            style: selectedStyle,
            colorSet: selectedColor,
            isProUser: isProUser
        )
    }

    /// 显示反馈提示，3 秒后自动隐藏。
    /// 用 Task.sleep 在主线程异步隐藏；多次调用以最近一次为准（前一次 task 自动 cancel
    /// 不会发生，因为我们没存它——但反馈语义本就是"显示最新"，覆盖即可）。
    private func showFeedback(_ text: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            lastActionFeedback = text
        }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                lastActionFeedback = nil
            }
        }
    }
}

// MARK: - Preview

// 注：此 preview 不注入 AppDependencies；导出 Starred 按钮在 preview 中点击会触发 @Environment
// 未注入 fatal——这是有意的，preview 用于 UI 排版调试，导出路径要在 app 实际运行时才验证。
#Preview {
    let mockUser = GitHubUserDTO(
        id: 1, login: "dong4j", name: "DONG Jianjun",
        avatarUrl: "https://avatars.githubusercontent.com/u/3380083?v=4",
        publicRepos: 48, followers: 236, following: 100,
        bio: "用代码解决真正的问题。", company: nil,
        location: "Shanghai", email: nil, blog: nil,
        twitterUsername: nil, htmlUrl: "https://github.com/dong4j"
    )
    return ShareCardSheet(
        user: mockUser,
        starredCount: 4823,
        contribution: nil,
        developerLanguages: nil,
        isProUser: false,
        onClose: {}
    )
    .environment(try! AppDependencies())
}
