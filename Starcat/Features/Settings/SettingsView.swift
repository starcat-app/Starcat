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
    @State private var storageActionError: String?

    // MARK: - Y5b 触点 E：AI 代码上下文产物管理（业务接通版，2026-06-13）
    //
    // 业务接通要点（与 `IntegrationSettingsView.codeFlowSection` 同款模式）：
    //   - `@State private var aiContextStorage = RepoContextStorage.shared` 让 SwiftUI
    //     自动跟踪 @Observable 单例的属性变更；
    //   - 所有按钮 action 实际触发 storage 方法 + NSOpenPanel；
    //   - 错误用 `aiContextActionError` 弹 alert（与 IntegrationSettingsView 同款）。
    //
    // 关键约束：
    //   1. `.task { aiContextStorage.reload() }` 在 Tab 出现时强制重扫描，让用户刚生成
    //      的产物立即可见；
    //   2. `revealProject` / `deleteProject` 都走 storage 内部 security scope 路径，
    //      避免 sandbox 拒绝 NSWorkspace 调用；
    //   3. "一键清除" 仍保留二次确认 alert，destructive 角色防误删。
    @State private var aiContextStorage = RepoContextStorage.shared
    @State private var showsAIContextClearConfirmation: Bool = false
    @State private var aiContextActionError: String?

    // 翻译磁盘缓存（HOM-68 v2 / 2026-06-15）：
    //   - `DiskReadmeTranslationCache.shared` 是 `@MainActor @Observable` 单例，
    //     UI 在用量行直接读 `totalBytes` / `itemCount` / `latestCreatedAt` 即可；
    //   - `showsTranslationCacheClearConfirmation` 控制清空二次确认 alert；
    //   - 不暴露列表 / 选目录 / Reveal 等复杂入口（dong4j 2026-06-15 拍板：只要用量
    //     数字 + 清除按钮），所以也没有 actionError 单独 alert——清除失败极少，
    //     失败时静默由 AppLog 兜底（与摘要 / RepoContext 区别：那两个有自定义目录
    //     bookmark 等额外失败面，翻译只删默认 appSupport 路径，几乎不会失败）。
    @State private var translationCache = DiskReadmeTranslationCache.shared
    @State private var showsTranslationCacheClearConfirmation: Bool = false

    /// 清理操作类型。每种类型有不同的确认文案与执行路径。
    private enum PendingAction: Identifiable {
        case readme, image, archive, all
        var id: String {
            switch self {
            case .readme: return "readme"
            case .image:  return "image"
            case .archive: return "archive"
            case .all:    return "all"
            }
        }
        var confirmTitle: String {
            switch self {
            case .readme: return String(localized: "settings.storage.clearReadme.confirm")
            case .image:  return String(localized: "settings.storage.clearImage.confirm")
            case .archive: return String(localized: "settings.storage.clearArchive.confirm")
            case .all:    return String(localized: "settings.storage.clearAll.confirm")
            }
        }
        var confirmMessageKey: LocalizedStringKey {
            switch self {
            case .readme: return "settings.storage.clearReadme.message"
            case .image:  return "settings.storage.clearImage.message"
            case .archive: return "settings.storage.clearArchive.message"
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
                LabeledContent("settings.storage.archive") {
                    HStack(spacing: 8) {
                        Text(archiveUsageText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button {
                            do {
                                try cleaner.revealArchiveDirectory()
                            } catch {
                                storageActionError = error.localizedDescription
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(Text("settings.storage.archive.revealHelp"))
                    }
                }
                LabeledContent("settings.storage.translation") {
                    Text(translationUsageText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(Text("settings.storage.translation.help"))
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
                Button("settings.storage.clearArchive") { pendingAction = .archive }
                    .disabled(isWorking || stats.archiveCount == 0)
                // HOM-68 v2：清除翻译磁盘缓存。空缓存时 disabled，避免误触发"删空目录"。
                Button("settings.storage.clearTranslation") {
                    showsTranslationCacheClearConfirmation = true
                }
                .disabled(isWorking || translationCache.itemCount == 0)
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
                do {
                    try aiContextStorage.deleteAllProjects()
                } catch {
                    aiContextActionError = error.localizedDescription
                }
            }
        } message: {
            Text("ai.context.storage.clearAllConfirm.message")
        }
        .alert(
            "settings.storage.actionFailed",
            isPresented: Binding(
                get: { storageActionError != nil },
                set: { if !$0 { storageActionError = nil } }
            )
        ) {
            Button("general.ok") { storageActionError = nil }
        } message: {
            Text(storageActionError ?? "")
        }
        // Y5b：storage 操作失败时弹 alert。与 IntegrationSettingsView 同款模式：
        // - storage 内部抛错 → 设置 aiContextActionError → 触发 alert
        // - 用户点"好"清除 aiContextActionError → alert 关闭
        .alert(
            "ai.context.storage.actionFailed",
            isPresented: Binding(
                get: { aiContextActionError != nil },
                set: { if !$0 { aiContextActionError = nil } }
            )
        ) {
            Button("general.ok") { aiContextActionError = nil }
        } message: {
            Text(aiContextActionError ?? "")
        }
        .task {
            // Tab 出现时主动扫描产物目录（首次进入 / 后台跑过 packer 之后回来都能更新）。
            aiContextStorage.reload()
        }
        .task {
            // Tab 出现时刷新翻译磁盘缓存统计（页面打开瞬间用量行有准确数字，不会延迟一帧）。
            translationCache.reload()
        }
        // HOM-68 v2：清除翻译缓存的二次确认 alert。与 ai context 同款 destructive 角色。
        .alert(
            "settings.storage.clearTranslation.confirm",
            isPresented: $showsTranslationCacheClearConfirmation
        ) {
            Button("general.cancel", role: .cancel) {}
            Button("settings.storage.clearTranslation.action", role: .destructive) {
                Task {
                    do {
                        try await translationCache.deleteEverything()
                    } catch {
                        // 失败概率极低（默认 appSupport 路径无权限问题），仍走 alert 入口
                        // 与其它清理操作语义一致。
                        storageActionError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("settings.storage.clearTranslation.message")
        }
    }

    // MARK: - AI 代码上下文 Section

    /// AI 代码上下文产物管理面板。视觉对照 `IntegrationSettingsView.codeFlowSection`。
    /// Y5b 起业务接通 `RepoContextStorage.shared`，所有数据 / CRUD / NSOpenPanel
    /// 都走真实存储层。
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
                Text(aiContextStorage.outputDirectoryDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                Spacer()
                Button("ai.context.storage.choose") {
                    chooseAIContextOutputDirectory()
                }
                .fixedSize()
                Button {
                    revealAIContextOutputDirectory()
                } label: {
                    Image(systemName: "folder")
                }
                .help(Text("ai.context.storage.revealHelp"))
                .fixedSize()
                Button {
                    resetAIContextOutputDirectory()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(!aiContextStorage.hasCustomOutputDirectory)
                .help(Text("ai.context.storage.resetHelp"))
                .fixedSize()
            }

            HStack(spacing: 18) {
                aiContextStat(titleKey: "ai.context.storage.statRepos",
                              value: "\(aiContextStorage.projects.count)")
                aiContextStat(titleKey: "ai.context.storage.statBytes",
                              value: ByteCountFormatter.string(fromByteCount: aiContextStorage.totalBytes, countStyle: .file))
                aiContextStat(titleKey: "ai.context.storage.statGenerations",
                              value: String(format: String(localized: "ai.context.storage.statGenerationsFormat"),
                                            aiContextStorage.totalGenerationCount))
                if let date = aiContextStorage.latestGeneratedAt {
                    aiContextStat(titleKey: "ai.context.storage.statLast",
                                  value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
            }

            // storage 内部抛错（bookmark 失效 / 目录权限丢失等）会反映到 lastErrorMessage
            // 上，扫描时显示给用户。区别于 actionError：actionError 是按钮触发的失败（短暂弹窗），
            // lastErrorMessage 是 reload 失败（持续在界面里）。
            if let message = aiContextStorage.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if aiContextStorage.projects.isEmpty {
                Text("ai.context.storage.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(aiContextStorage.projects) { project in
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

    /// 单个产物行（一个 `<owner>/<repo>` 项目）。Y5b 起绑定 `RepoContextStoredProject`。
    ///
    /// 视觉与 `IntegrationSettingsView.projectRow(_:)` 对齐：左侧两行文本（仓库全名 +
    /// 元信息 caption），右侧 2 个 Button（在 Finder 显示 / 删除）。
    /// 注：与 CodeFlow 不同，本场景没有"预览页面"概念（context.xml 不直接展示给用户看），
    /// 删除 IntegrationSettingsView 的 "预览" 按钮。
    private func aiContextProjectRow(_ project: RepoContextStoredProject) -> some View {
        let metadata = project.metadata
        let commitShortSHA = String(metadata.commitSha.prefix(7))
        let xmlBytesStr = ByteCountFormatter.string(fromByteCount: Int64(metadata.stats.contextXmlBytes), countStyle: .file)
        let actualTokens = metadata.stats.actualTokens
        let totalFiles = metadata.stats.totalFiles
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(metadata.owner)/\(metadata.repo)")
                        .font(.callout.weight(.medium))
                    Text("\(metadata.ref) · \(commitShortSHA) · XML \(xmlBytesStr) · \(actualTokens) tokens · \(totalFiles) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(project.generatedAtDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("ai.context.storage.menuReveal") {
                    revealAIContextProject(project)
                }
                Button("ai.context.storage.menuDelete", role: .destructive) {
                    deleteAIContextProject(project)
                }
            }
        }
    }

    // MARK: - Y5b storage action 入口

    /// 选择新的产物输出目录（与 IntegrationSettingsView 同款 NSOpenPanel）。
    private func chooseAIContextOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "ai.context.storage.choosePanelTitle")
        panel.prompt = String(localized: "ai.context.storage.choosePanelPrompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try aiContextStorage.setCustomOutputDirectory(url)
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func resetAIContextOutputDirectory() {
        do {
            try aiContextStorage.resetOutputDirectory()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func revealAIContextOutputDirectory() {
        do {
            try aiContextStorage.revealOutputRoot()
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func revealAIContextProject(_ project: RepoContextStoredProject) {
        do {
            try aiContextStorage.revealProject(project)
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    private func deleteAIContextProject(_ project: RepoContextStoredProject) {
        do {
            try aiContextStorage.deleteProject(owner: project.metadata.owner, repo: project.metadata.repo)
        } catch {
            aiContextActionError = error.localizedDescription
        }
    }

    /// 执行清理 + 重新加载统计。UI state 全程在 main actor。
    @MainActor
    private func perform(action: PendingAction, using cleaner: CacheCleaner) async {
        isWorking = true
        switch action {
        case .readme: await cleaner.clearReadmes()
        case .image:  await cleaner.clearImageCache()
        case .archive: cleaner.clearArchives()
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

    private var archiveUsageText: String {
        String(
            format: String(localized: "settings.storage.archiveUsageFormat"),
            stats.archiveCount,
            stats.archiveBytes.formattedByteSize
        )
    }

    /// 翻译磁盘缓存用量行文案：`X 项 · YY KB`。
    /// 空缓存时显示"未生成"（不显示"0 项 · 0 字节"，更友好）。
    private var translationUsageText: String {
        if translationCache.itemCount == 0 {
            return String(localized: "settings.storage.translation.empty")
        }
        return String(
            format: String(localized: "settings.storage.translationUsageFormat"),
            translationCache.itemCount,
            translationCache.totalBytes.formattedByteSize
        )
    }
}

// Y5b（2026-06-13）：原 `MockAIContextProject` 已下线，业务接通 `RepoContextStoredProject`。
