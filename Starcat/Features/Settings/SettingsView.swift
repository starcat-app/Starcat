//
//  SettingsView.swift
//  Starcat
//
//  macOS 标准设置窗口（Cmd+,）。
//
//  Week 3 范围：
//  - General 标签：列表密度
//
//  Week 4+ 计划新增：
//  - Sync 标签：自动同步频率、同步范围
//  - AI 标签：BYOK key、模型选择
//  - About 标签：版本、许可、致谢
//
//  设计约束：
//  - 用 macOS 原生 TabView + Form，配 .formStyle(.grouped) 自动获得分组卡片样式
//  - 控件直接绑定到 AppSettings 的 @Observable 属性，写入即落盘
//

import AppKit
import SwiftUI

// MARK: - 跨 Tab 跳转事件
//
// 2026-06-13 Y3/Y5：AISettingsTab 的「管理已生成的上下文 →」按钮需要把
// settings 窗口从 .ai 切到 .storage。SettingsView 当前用 @State 自管
// selectedTab，没有外部入口可以直接改它的值；项目惯例（见 ReadmeViewModel /
// RepoNote）是「跨 View 通信用 Notification.Name」，于是在 settings feature
// 模块内部约定一个事件名：发起方 (AISettingsView) post，接收方 (SettingsView
// .onReceive) 读取 object: String 决定切到哪个 tag。
//
// 关键约束：
//   1. object 用 String 而不是 enum——避免 AISettingsView 反向依赖 SettingsView
//      内部的 SettingsTab（那是 private enum）；
//   2. 未识别的 object 字符串直接忽略，不 crash；
//   3. 名字加 `starcat.` 前缀防止与系统 / 三方框架冲突。
extension Notification.Name {
    /// 跨 Settings Tab 跳转。`object: String` 取值：`"general"` / `"storage"` /
    /// `"pro"` / `"ai"` / `"services"` / `"integrations"`。
    static let starcatJumpToSettingsTab: Notification.Name = .init("starcat.settings.jumpToTab")
}

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies

    @State private var selectedTab: SettingsTab = .general

    /// Settings 各 Tab 的内容尺寸。
    ///
    /// HOM-68 follow-up v12 (dong4j 反馈 2026-06-06 00:32)：
    /// AI 页早期内容铺满（任务模型 4 行 + 模型参数 6 行 + 双 Prompt 编辑区），
    /// 一度需要单独放大到 760×760。v7–v9 把"模型配置 / 已发现模型 / Prompt"
    /// 都改成 DisclosureGroup 默认折叠 + 把"模型参数"迁到 popover 后，AI 页
    /// 折叠态高度已经收回到与通用 / 存储相当，没必要再单独占一档尺寸。统一回
    /// 520×360，与 macOS 设置窗口惯例一致；折叠组展开后 Form 自带垂直滚动，
    /// 不会被裁切。
    private enum SettingsTab: Hashable {
        case general
        case pro
        case ai
        case storage
        /// 2026-06-08 新增：第三方 / 自建后端服务的 URL 配置。
        case services
        /// 直接嵌入 Starcat 的第三方工具，与后端服务配置分开管理。
        case integrations
    }

    /// 统一的内容尺寸——所有 Tab 共用，避免切 Tab 时窗口尺寸跳变。
    /// 2026-06-08 调整：Services Tab 含 3 个服务卡片（每张约 130pt），加 intro 段后
    /// 360pt 已经放不下，提到 460；其它 Tab 在 460 高度下 Form 仍正常显示。
    private static let contentSize = CGSize(width: 540, height: 460)

    var body: some View {
        // HOM-68 follow-up v3 (2026-06-05 22:40 dong4j 反馈)：
        // 把 AI Tab 放到 Storage 之后。AI 是配置项最复杂、最不常碰的 Tab，
        // 放在最后符合"常用在前、复杂在后"的设置面板惯例。
        // 2026-06-08：「服务」Tab 放在最后——也属于"较少调整的进阶配置"类。
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label("settings.general.title", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
                .tabItem {
                    Label("settings.storage.title", systemImage: "internaldrive")
                }
                .tag(SettingsTab.storage)
            ProSettingsTab()
                .tabItem {
                    Label("Pro", systemImage: "crown.fill")
                }
                .tag(SettingsTab.pro)
            AISettingsTab()
                .tabItem {
                    Label("settings.ai.title", systemImage: "sparkles")
                }
                .tag(SettingsTab.ai)
            ServicesSettingsTab()
                .tabItem {
                    Label("settings.services.title", systemImage: "network")
                }
                .tag(SettingsTab.services)
            IntegrationSettingsTab()
                .tabItem {
                    Label("settings.integrations.title", systemImage: "puzzlepiece.extension")
                }
                .tag(SettingsTab.integrations)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .scenePadding()
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
            guard let target = note.object as? String else { return }
            switch target {
            case "general":      selectedTab = .general
            case "storage":      selectedTab = .storage
            case "pro":          selectedTab = .pro
            case "ai":           selectedTab = .ai
            case "services":     selectedTab = .services
            case "integrations": selectedTab = .integrations
            default: break
            }
        }
    }

    private var generalTab: some View {
        @Bindable var settings = settings

        return Form {
            Section("settings.general.appearance") {
                // W4-5 D1:主题切换(dong4j 2026-06-03 需求,默认 .dark)。
                // 用 Label + segmented 让 3 个选项的图标可见(circle.lefthalf / sun.max / moon.fill),
                // 跟 macOS "系统设置 → 外观" 的视觉语言一致,降低用户认知成本。
                //
                // 过渡动画(W4-5 D1 follow-up,2026-06-03):用自定义 binding 把 setter 包到
                // `withAnimation(.easeInOut(0.3))` transaction 里,让依赖 colorScheme 计算的
                // SwiftUI 视图(动态颜色 / 材质 / 文字色)切换时带 0.3s 淡变,而非瞬切。
                //
                // 关键约束:① macOS NSWindow titlebar / chrome 由 AppKit 即时切换,SwiftUI 动画
                // 系统覆盖不到,所以 titlebar 仍是瞬切;② 视图内容区(.background / .foregroundStyle
                // 走动态色的)会跟随 transaction 平滑过渡;③ `@Observable` 属性在 withAnimation
                // 块内修改会被收进 transaction,这与 `@Published` 的行为一致,验证过。
                Picker("settings.general.appearanceMode", selection: Binding(
                    get: { settings.appearanceMode },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.6)) {
                            settings.appearanceMode = newValue
                        }
                    }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("settings.general.appearanceMode.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // R-01 §3.1.1（2026-06-10 P1）：列表密度 Picker 已彻底移除——
                // RepoListDensity 枚举本身也已删除（之前为保签名稳定保留单 case
                // 是「自留技术债」，现在所有 row / skeleton 视图直接用 card 密度）。
            }

            // HOM-SNAKE-MODES 2026-06-05：贡献草坪贪吃蛇玩法。
            // 用 Menu 风格 Picker 而非 segmented——6 个选项 segmented 会过宽，
            // 而且每项都带 SF Symbol，菜单展开形态视觉信息密度更高。
            // 设计取舍：把贪吃蛇配置放在 General 而非新建 "Sidebar" Tab，是因为
            // 当前 Sidebar 可配置项只有这一个，单独开 Tab 显得空；后续若新增
            // sidebar 偏好（如折叠默认态、密度）再拆分。
            Section("settings.snakeStyle.section") {
                Picker(selection: $settings.snakeStyle) {
                    ForEach(SnakeStyle.allCases) { style in
                        Label(LocalizedStringKey(style.displayNameKey),
                              systemImage: style.systemImage)
                            .tag(style)
                    }
                } label: {
                    Text("settings.snakeStyle.title")
                }
                .pickerStyle(.menu)

                Text("settings.snakeStyle.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - W4-4 D4：存储 Tab

/// 缓存统计与清理面板。
///
/// 独立 View 是为了把 CacheCleaner 的生命周期收敛在 Tab 内:
/// - Tab 出现时 onAppear 加载统计
/// - 用户清理后立即重新加载,UI 立刻反映新状态
///
/// 清理操作有 confirmationDialog 兜底,避免误点。
private struct StorageSettingsTab: View {

    let readmeRepository: ReadmeRepository

    @State private var stats: CacheStatistics = .empty
    @State private var isWorking: Bool = false
    /// 当前显示的确认弹窗类型;nil 表示不显示。
    @State private var pendingAction: PendingAction?

    // MARK: - Y5 触点 E：AI 代码上下文产物管理（Mock UI 阶段）
    //
    // 当前是「先看效果」UI 阶段——`@State` 直接持有 mock 数据，让 dong4j 能在
    // 设置 → 存储页看到完整视觉（路径配置 / 4 列统计 / 项目列表 / 一键清除）。
    // W6 落地 `RepoContextStorage` 后，把 `aiContextMockProjects` 换成
    // `@State private var aiContextStorage = RepoContextStorage.shared`，其余
    // body 代码只改字段路径即可（mock struct 的字段命名已和 `RepoContextProject`
    // 提前对齐：owner / repo / commitShortSHA / branch / contextBytes / ...）。
    //
    // 关键约束（与 CodeFlow 模式对齐）：
    //   1. 默认根 URL 用 `FileManager.default.urls(for: .applicationSupportDirectory)`
    //      实时计算，**不读硬盘** —— 即便目录不存在也能显示路径文本；
    //   2. 按钮 action 在 Mock 阶段全部走 `AppLog.ai.debug` 占位，不弹 NSOpenPanel、
    //      不写文件系统；W6 接通后再实际触发；
    //   3. "一键清空" 二次确认 + destructive 角色与 CodeFlow `showsClearConfirmation`
    //      同款模式。
    @State private var aiContextMockProjects: [MockAIContextProject] = MockAIContextProject.samples
    @State private var showsAIContextClearConfirmation: Bool = false

    /// 默认产物目录（与 §0.4 W6 决议：`Application Support/Starcat/repo-context/`）。
    /// Mock 阶段只显示路径文本，目录不一定存在，不调 `createDirectory`。
    private var aiContextDefaultOutputURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return appSupport.appending(path: "Starcat/repo-context", directoryHint: .isDirectory)
    }

    private var aiContextDirectoryDisplayPath: String {
        aiContextDefaultOutputURL.path
    }

    private var aiContextTotalBytes: Int64 {
        aiContextMockProjects.reduce(0) { $0 + $1.contextBytes + $1.metadataBytes }
    }

    private var aiContextTotalGenerations: Int {
        aiContextMockProjects.reduce(0) { $0 + $1.generationCount }
    }

    private var aiContextLatestGeneratedAt: Date? {
        aiContextMockProjects.map(\.generatedAt).max()
    }

    /// 清理操作类型。每种类型有不同的确认文案与执行路径。
    private enum PendingAction: Identifiable {
        case readme, image, all
        var id: String {
            switch self {
            case .readme: return "readme"
            case .image:  return "image"
            case .all:    return "all"
            }
        }
        var confirmTitle: String {
            switch self {
            case .readme: return String(localized: "settings.storage.clearReadme.confirm")
            case .image:  return String(localized: "settings.storage.clearImage.confirm")
            case .all:    return String(localized: "settings.storage.clearAll.confirm")
            }
        }
        var confirmMessageKey: LocalizedStringKey {
            switch self {
            case .readme: return "settings.storage.clearReadme.message"
            case .image:  return "settings.storage.clearImage.message"
            case .all:    return "settings.storage.clearAll.message"
            }
        }
    }

    var body: some View {
        let cleaner = CacheCleaner(readmeRepository: readmeRepository)
        return Form {
            Section("settings.storage.cacheUsage") {
                LabeledContent("settings.storage.readme") {
                    Text(readmeUsageText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("settings.storage.image") {
                    Text(Int64(stats.imageDiskBytes).formattedByteSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("settings.storage.log") {
                    Text("settings.storage.logDescription")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
                .help(Text("settings.storage.logHelp"))
            }

            Section("settings.storage.clear") {
                Button("settings.storage.clearReadme") { pendingAction = .readme }
                    .disabled(isWorking || stats.readmeCount == 0)
                Button("settings.storage.clearImage") { pendingAction = .image }
                    .disabled(isWorking || stats.imageDiskBytes == 0)
                Button("settings.storage.clearAll", role: .destructive) { pendingAction = .all }
                    .disabled(isWorking || stats.totalBytes == 0)
            }

            aiContextSection

            if isWorking {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("settings.storage.clearing")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            stats = await cleaner.loadStatistics()
        }
        .confirmationDialog(
            pendingAction?.confirmTitle ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button("general.clear", role: .destructive) {
                Task { await perform(action: action, using: cleaner) }
            }
            Button("general.cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.confirmMessageKey)
        }
        .alert("ai.context.storage.clearAllConfirm.title", isPresented: $showsAIContextClearConfirmation) {
            Button("general.cancel", role: .cancel) {}
            Button("ai.context.storage.clearAll", role: .destructive) {
                AppLog.ai.debug("[StorageSettings] clear all AI contexts (Mock UI, no-op)")
                aiContextMockProjects.removeAll()
            }
        } message: {
            Text("ai.context.storage.clearAllConfirm.message")
        }
    }

    // MARK: - AI 代码上下文 Section

    /// AI 代码上下文产物管理面板。视觉对照 `IntegrationSettingsView.codeFlowSection`，
    /// 字段命名与未来 `RepoContextProject` 对齐（owner / repo / commitShortSHA / branch /
    /// contextBytes / metadataBytes / generatedAt / generationCount）。
    private var aiContextSection: some View {
        Section("ai.context.storage.section") {
            VStack(alignment: .leading, spacing: 5) {
                Label("ai.context.storage.outputDirectory", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text("ai.context.storage.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(aiContextDirectoryDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("ai.context.storage.choose") {
                    AppLog.ai.debug("[StorageSettings] choose output directory tapped (Mock UI, no-op)")
                }
                Button {
                    AppLog.ai.debug("[StorageSettings] reveal output directory tapped (Mock UI, no-op)")
                } label: {
                    Image(systemName: "folder")
                }
                .help(Text("ai.context.storage.revealHelp"))
                Button {
                    AppLog.ai.debug("[StorageSettings] reset output directory tapped (Mock UI, no-op)")
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(true) // 当前 mock 总是处于 default 目录态，重置按钮 disabled
                .help(Text("ai.context.storage.resetHelp"))
            }

            HStack(spacing: 18) {
                aiContextStat(titleKey: "ai.context.storage.statRepos",
                              value: "\(aiContextMockProjects.count)")
                aiContextStat(titleKey: "ai.context.storage.statBytes",
                              value: ByteCountFormatter.string(fromByteCount: aiContextTotalBytes, countStyle: .file))
                aiContextStat(titleKey: "ai.context.storage.statGenerations",
                              value: String(format: String(localized: "ai.context.storage.statGenerationsFormat"),
                                            aiContextTotalGenerations))
                if let date = aiContextLatestGeneratedAt {
                    aiContextStat(titleKey: "ai.context.storage.statLast",
                                  value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
            }

            if aiContextMockProjects.isEmpty {
                Text("ai.context.storage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(aiContextMockProjects) { project in
                    aiContextProjectRow(project)
                }

                HStack {
                    Spacer()
                    Button("ai.context.storage.clearAll", role: .destructive) {
                        showsAIContextClearConfirmation = true
                    }
                }
            }
        }
    }

    /// 统计列（4 项：repos / size / generations / last generated）。
    /// 视觉与 `IntegrationSettingsView.stat(title:value:)` 对齐（caption2 标题 +
    /// caption.weight(.medium) 数值，左对齐 2pt 行距）。
    private func aiContextStat(titleKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    /// 单个产物行（一个 `<owner>/<repo>` 项目）。
    /// 视觉与 `IntegrationSettingsView.projectRow(_:)` 对齐：左侧两行文本（仓库全名 +
    /// 元信息 caption），右侧 3 个 Button（预览 / 打开 / 删除）。
    private func aiContextProjectRow(_ project: MockAIContextProject) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(project.owner)/\(project.repo)")
                        .font(.callout.weight(.medium))
                    Text("\(project.branch) · \(project.commitShortSHA) · XML \(ByteCountFormatter.string(fromByteCount: project.contextBytes, countStyle: .file)) · \(project.actualTokens) tokens · \(project.keptFileCount) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(project.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("ai.context.storage.menuReveal") {
                    AppLog.ai.debug("[StorageSettings] reveal \(project.owner)/\(project.repo) tapped (Mock UI, no-op)")
                }
                Button("ai.context.storage.menuDelete", role: .destructive) {
                    AppLog.ai.debug("[StorageSettings] delete \(project.owner)/\(project.repo) tapped (Mock UI, no-op)")
                    aiContextMockProjects.removeAll { $0.id == project.id }
                }
            }
        }
    }

    /// 执行清理 + 重新加载统计。UI state 全程在 main actor。
    @MainActor
    private func perform(action: PendingAction, using cleaner: CacheCleaner) async {
        isWorking = true
        switch action {
        case .readme: await cleaner.clearReadmes()
        case .image:  await cleaner.clearImageCache()
        case .all:    await cleaner.clearAll()
        }
        stats = await cleaner.loadStatistics()
        isWorking = false
        pendingAction = nil
    }

    private var readmeUsageText: String {
        String(
            format: String(localized: "settings.storage.readmeUsageFormat"),
            stats.readmeCount,
            stats.readmeBytes.formattedByteSize
        )
    }
}

// MARK: - AI 代码上下文：Mock 数据模型（W6 落地前临时持有 UI 状态）
//
// 设计要点：
//   - 字段命名与未来 `RepoContextProject`（W6 落地）/ `PackMetadata`（已落地，W7
//     扩字段）对齐，便于后续替换时只改 `@State` 持有方而不动 view body；
//   - `Identifiable` 让 `ForEach` 不需要 explicit id；
//   - sample 数据覆盖：常见小仓库（vapor）/ 大型 monorepo（pointfreeco）/ 中等
//     active 维护（krzyzanowskim），3 种典型量级让 dong4j 看效果时能感知 UI 在
//     不同体积下的视觉差异。
private struct MockAIContextProject: Identifiable {

    let id = UUID()
    let owner: String
    let repo: String
    /// commit SHA 短哈希（前 7 字符）。
    let commitShortSHA: String
    let branch: String
    /// `context.xml` 字节数。
    let contextBytes: Int64
    /// `metadata.json` 字节数。
    let metadataBytes: Int64
    /// 最近一次生成时间（`PackMetadata.generatedAt`）。
    let generatedAt: Date
    /// 生成次数（W7 扩字段，每次 pack 后 +1）。
    let generationCount: Int
    /// 用户配置的 token 预算（`PackMetadata.tokenBudget`）。
    let tokenBudget: Int
    /// 校准后的真实 token 数（`PackMetadata.stats.actualTokens`）。
    let actualTokens: Int
    /// 实际保留的文件数（`PackMetadata.stats.keptFileCount`）。
    let keptFileCount: Int

    static let samples: [MockAIContextProject] = [
        .init(
            owner: "vapor",
            repo: "vapor",
            commitShortSHA: "51ab970",
            branch: "main",
            contextBytes: 524_288,
            metadataBytes: 1_536,
            generatedAt: .now.addingTimeInterval(-3_600),
            generationCount: 3,
            tokenBudget: 8_000,
            actualTokens: 7_234,
            keptFileCount: 87
        ),
        .init(
            owner: "pointfreeco",
            repo: "swift-composable-architecture",
            commitShortSHA: "abc1234",
            branch: "main",
            contextBytes: 758_496,
            metadataBytes: 1_684,
            generatedAt: .now.addingTimeInterval(-86_400),
            generationCount: 1,
            tokenBudget: 8_000,
            actualTokens: 7_902,
            keptFileCount: 142
        ),
        .init(
            owner: "gonzalezreal",
            repo: "swift-markdown-ui",
            commitShortSHA: "def5678",
            branch: "main",
            contextBytes: 312_000,
            metadataBytes: 1_490,
            generatedAt: .now.addingTimeInterval(-7 * 86_400),
            generationCount: 5,
            tokenBudget: 12_000,
            actualTokens: 11_250,
            keptFileCount: 56
        )
    ]
}
