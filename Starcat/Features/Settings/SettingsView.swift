//
//  SettingsView.swift
//  Starcat
//
//  macOS 系统设置风格的独立窗口（Cmd+,）。
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
//  - 用原生 NavigationSplitView + Sidebar List + Form 组成系统设置式左右布局
//  - 控件直接绑定到 AppSettings 的 @Observable 属性，写入即落盘
//

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
    /// `"pro"` / `"ai"` / `"ai.chat"` / `"ai.embedding"` / `"ai.repoContext"` / `"services"` / `"integrations"` /
    /// `"integrations.agentRuntime"` / `"integrations.localAPIKey"` / `"integrations.externalSearch"` /
    /// `"integrations.codebaseMemory"` / `"diagnostics"`。
    static let starcatJumpToSettingsTab: Notification.Name = .init("starcat.settings.jumpToTab")
    /// SettingsView 切到 AI Tab 并完成一轮布局后，再通知 AISettingsView 展开并定位。
    static let starcatJumpToAIRepoContextSection: Notification.Name = .init(
        "starcat.settings.jumpToAIRepoContextSection"
    )
    /// 知识库索引入口需要直达「模型配置 → 向量化」，不能只把用户丢在 AI Tab 顶部。
    static let starcatJumpToAIEmbeddingSection: Notification.Name = .init(
        "starcat.settings.jumpToAIEmbeddingSection"
    )
    /// 工作台入口缺少有效模型时，直达「模型配置 → 对话」。
    static let starcatJumpToAIChatModelSection: Notification.Name = .init(
        "starcat.settings.jumpToAIChatModelSection"
    )
}

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    /// 2026-06-15:用于在主题切换的 withAnimation 处兜底跳过动画。
    /// 系统「减少动态效果」或用户「关闭应用内动画」任一为真时生效
    /// (root view 的 `AnimationOverrideModifier` 已 OR 合并)。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 2026-06-15 dong4j 需求:用户面向的语言切换状态容器。
    /// `LocaleStore` 是 `@MainActor @Observable` 单例,主窗口与 Settings 共享同一份;
    /// `@Bindable` 让下方 Picker 可以直接 `$localeStore.selection` 双向绑定。
    @State private var localeStore = LocaleStore.shared

    @State private var selectedTab: SettingsTab = .general
    @State private var currentLocation = SettingsLocation(tab: .general)
    @State private var backwardHistory: [SettingsLocation] = []
    @State private var forwardHistory: [SettingsLocation] = []
    @State private var settingsSearchText = ""
    @State private var isRedispatchingSettingsJump = false
    /// 快捷键录制失败时只在 General 页就地提示，不修改已保存配置。
    @State private var shortcutValidationError: KeyboardShortcutConfiguration.ValidationError?

    /// 六个可配置应用命令的设置页标识。
    /// 这里只负责冲突矩阵和“恢复默认”级联，不参与菜单动作路由。
    private enum ConfigurableShortcutAction: CaseIterable, Hashable {
        case globalSearch
        case regularSearch
        case readmeFind
        case refreshCurrentContent
        case knowledgeRAG
        case selectedRepoAI

        var defaultShortcut: KeyboardShortcutConfiguration {
            switch self {
            case .globalSearch:
                return .globalSearchDefault
            case .regularSearch:
                return .regularSearchDefault
            case .readmeFind:
                return StarcatShortcutCatalog.readmeFindDefault
            case .refreshCurrentContent:
                return StarcatShortcutCatalog.refreshCurrentContentDefault
            case .knowledgeRAG:
                return StarcatShortcutCatalog.openKnowledgeRAGDefault
            case .selectedRepoAI:
                return StarcatShortcutCatalog.openSelectedRepoAIDefault
            }
        }
    }

    private enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
        case general
        case pro
        case ai
        case mcp
        /// 2026-06-08 新增：第三方 / 自建后端服务的 URL 配置。
        case services
        /// 直接嵌入 Starcat 的第三方工具，与后端服务配置分开管理。
        case integrations
        /// 原 RAG 独立窗口的三个分类直接提升为主设置一级侧栏条目。
        case ragInference
        case ragPrompts
        case ragRetrieval
        case storage
        case diagnostics

        var id: String { rawValue }

        var titleKeyString: String {
            switch self {
            case .general:      return "settings.general.title"
            case .pro:          return "Pro"
            case .ai:           return "settings.ai.title"
            case .mcp:          return "settings.mcp.title"
            case .services:     return "settings.services.title"
            case .integrations: return "settings.integrations.title"
            case .ragInference: return "rag.workspace.settings.section.inference"
            case .ragPrompts:   return "rag.workspace.settings.section.prompts"
            case .ragRetrieval: return "rag.workspace.settings.section.retrieval"
            case .storage:      return "settings.storage.title"
            case .diagnostics:  return "settings.diagnostics.title"
            }
        }

        var titleKey: LocalizedStringKey {
            LocalizedStringKey(titleKeyString)
        }

        var systemImage: String {
            switch self {
            case .general:      return "gearshape"
            case .pro:          return "crown.fill"
            case .ai:           return "sparkles"
            case .mcp:          return "point.3.connected.trianglepath.dotted"
            case .services:     return "network"
            case .integrations: return "puzzlepiece.extension"
            case .ragInference: return RAGSettingsSection.inference.systemImage
            case .ragPrompts:   return RAGSettingsSection.prompts.systemImage
            case .ragRetrieval: return RAGSettingsSection.retrieval.systemImage
            case .storage:      return "internaldrive"
            case .diagnostics:  return "stethoscope"
            }
        }

        /// 仅供三个 RAG 主侧栏条目把 selection 传给共用的设置内容。
        var ragSettingsSection: RAGSettingsSection {
            switch self {
            case .ragInference: return .inference
            case .ragPrompts:   return .prompts
            case .ragRetrieval: return .retrieval
            default:
                preconditionFailure("Only RAG settings tabs have a RAG section")
            }
        }

    }

    /// 历史记录保存“分类 + 目标区块”，让搜索结果与跨模块入口也能正常后退 / 前进。
    private struct SettingsLocation: Equatable {
        let tab: SettingsTab
        var target: String?

        init(tab: SettingsTab, target: String? = nil) {
            self.tab = tab
            self.target = target
        }
    }

    /// 搜索条目只保存已有本地化 key；关键词补充用户常用的中英文技术术语。
    /// 有既有深链的条目会定位到具体区块，其余条目至少准确进入对应设置页。
    private struct SettingsSearchItem: Identifiable {
        let id: String
        let titleKey: String
        let tab: SettingsTab
        let target: String?
        let keywords: [String]

        init(
            _ id: String,
            titleKey: String,
            tab: SettingsTab,
            target: String? = nil,
            keywords: [String] = []
        ) {
            self.id = id
            self.titleKey = titleKey
            self.tab = tab
            self.target = target
            self.keywords = keywords
        }
    }

    /// 设置窗口固定使用当前验收尺寸；Scene 同时声明 `.contentSize`，让 AppKit
    /// 禁用边缘缩放和绿色缩放按钮，而不是只给一个仍可继续放大的最小值。
    private static let contentSize = CGSize(width: 800, height: 600)

    var body: some View {
        // NavigationSplitView + sidebar List 使用 macOS 原生选中态、材质和分隔线。
        // 固定 columnVisibility 可避免设置分类被误折叠，也不会再出现自绘窗口留下的底栏。
        NavigationSplitView(columnVisibility: .constant(.all)) {
            settingsSidebar
        } detail: {
            settingsPage(selectedTab)
                .contentMargins(.top, 8, for: .scrollContent)
                // `navigationTitle(LocalizedStringKey)` 由系统 toolbar 单独解析，曾绕过
                // App 内 LocaleStore，导致侧栏已是英文而这里仍显示中文。先通过
                // LocalizedBundle 解析成当前应用语言的 String，toolbar 就不会回退系统语言。
                .navigationTitle(String.l10n(selectedTab.titleKeyString))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            width: Self.contentSize.width,
            height: Self.contentSize.height
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(action: goBack) {
                        Label("settings.navigation.back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(backwardHistory.isEmpty)

                    Button(action: goForward) {
                        Label("settings.navigation.forward", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(forwardHistory.isEmpty)
                }
                .controlGroupStyle(.navigation)
            }

        }
        .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
            // 搜索结果和历史导航需要复用既有 Integration 深链通知；同步标记可避免
            // SettingsView 把自己发出的通知再次写进历史形成循环。
            guard !isRedispatchingSettingsJump else { return }
            guard let target = note.object as? String else { return }
            defer { AppDelegate.acknowledgeSettingsTarget(target) }
            if let location = settingsLocation(for: target) {
                navigate(to: location)
            }
        }
        .onAppear {
            dependencies.telemetryManager.track(.settingsOpened)
            // 第一次打开 Window 时通知可能早于 View 安装订阅；消费 AppDelegate
            // 暂存的目标，保证独立窗口入口首次也能准确定位到目标页/区块。
            if let target = AppDelegate.consumePendingSettingsTarget(),
               let location = settingsLocation(for: target) {
                navigate(to: location)
            }
        }
        .task(id: dependencies.databaseScopeRevision) {
            await dependencies.dataContributionSettings.reload(
                accountID: dependencies.database.currentUserId
            )
        }
    }

    /// 把系统 Sidebar List 的选择写入历史，而不是另做一套选中态。
    private var settingsTabSelection: Binding<SettingsTab> {
        Binding(
            get: { selectedTab },
            set: { navigate(to: SettingsLocation(tab: $0)) }
        )
    }

    private var settingsSidebar: some View {
        List(selection: settingsTabSelection) {
            Section("settings.sidebar.group.basic") {
                settingsSidebarRow(.general)
                settingsSidebarRow(.pro)
            }

            Section("settings.sidebar.group.intelligence") {
                settingsSidebarRow(.ai)
                settingsSidebarRow(.mcp)
                settingsSidebarRow(.services)
                settingsSidebarRow(.integrations)
            }

            // 原独立窗口的三项导航直接并入主设置 Sidebar；RAG 是与「基础」
            // 等并列的分组标题，不再额外增加「RAG 工作台」占位条目或二级侧栏。
            Section("RAG") {
                settingsSidebarRow(.ragInference)
                settingsSidebarRow(.ragPrompts)
                settingsSidebarRow(.ragRetrieval)
            }

            Section("settings.sidebar.group.maintenance") {
                settingsSidebarRow(.storage)
                settingsSidebarRow(.diagnostics)
            }
        }
        .listStyle(.sidebar)
        // Apple 要求把默认项移除声明挂在产生它的 Sidebar column 上；挂在 SplitView
        // 根部时 macOS 26 仍可能在窗口重建 Toolbar 后重新注入折叠按钮。
        .toolbar(removing: .sidebarToggle)
        // 系统设置采用稳定的分类栏宽度；固定值也能覆盖旧窗口保存的过窄 divider 位置。
        .navigationSplitViewColumnWidth(240)
        .searchable(
            text: $settingsSearchText,
            placement: .sidebar,
            prompt: Text("settings.sidebar.search.placeholder")
        )
        .searchSuggestions {
            ForEach(filteredSearchItems) { item in
                Button {
                    settingsSearchText = ""
                    navigate(to: SettingsLocation(tab: item.tab, target: item.target))
                } label: {
                    Label(LocalizedStringKey(item.titleKey), systemImage: item.tab.systemImage)
                }
            }
        }
    }

    private func settingsSidebarRow(_ tab: SettingsTab) -> some View {
        Label(tab.titleKey, systemImage: tab.systemImage)
            .tag(tab)
    }

    /// 只构造当前页，避免旧版 ZStack 让所有访问过的重型 Form 一直参与布局与刷新。
    @ViewBuilder
    private func settingsPage(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            generalTab
        case .pro:
            ProSettingsTab()
        case .ai:
            AISettingsTab()
        case .mcp:
            MCPSettingsTab()
        case .services:
            ServicesSettingsTab()
        case .integrations:
            IntegrationSettingsTab()
        case .ragInference, .ragPrompts, .ragRetrieval:
            RAGWorkspaceSettingsView(
                settings: settings,
                presentation: .embeddedInMainSettings(section: tab.ragSettingsSection)
            )
        case .storage:
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
        case .diagnostics:
            DiagnosticsSettingsTab()
        }
    }

    private var settingsSearchItems: [SettingsSearchItem] {
        [
            SettingsSearchItem("general", titleKey: "settings.general.title", tab: .general,
                               keywords: ["通用", "general", "偏好", "preferences"]),
            SettingsSearchItem("general.appearance", titleKey: "settings.general.appearance", tab: .general,
                               keywords: ["主题", "浅色", "深色", "theme", "appearance", "font", "字号"]),
            SettingsSearchItem("general.language", titleKey: "settings.general.language", tab: .general,
                               keywords: ["语言", "locale", "language"]),
            SettingsSearchItem("general.shortcuts", titleKey: "settings.general.shortcuts", tab: .general,
                               keywords: ["快捷键", "keyboard", "shortcut"]),
            SettingsSearchItem("general.notifications", titleKey: "settings.notifications.title", tab: .general,
                               keywords: ["通知", "notification", "提醒"]),
            SettingsSearchItem("general.accessibility", titleKey: "settings.general.accessibility", tab: .general,
                               keywords: ["动画", "无障碍", "accessibility", "motion"]),
            SettingsSearchItem("pro", titleKey: "Pro", tab: .pro,
                               keywords: ["订阅", "授权", "激活", "license", "subscription", "purchase"]),
            SettingsSearchItem("ai", titleKey: "settings.ai.title", tab: .ai,
                               keywords: ["人工智能", "模型", "provider", "model", "api key"]),
            SettingsSearchItem("ai.provider", titleKey: "settings.ai.provider.sectionTitle", tab: .ai,
                               keywords: ["服务商", "provider", "api key"]),
            SettingsSearchItem("ai.chat", titleKey: "settings.ai.taskModels.title", tab: .ai, target: "ai.chat",
                               keywords: ["对话", "任务模型", "chat", "model"]),
            SettingsSearchItem("ai.prompt", titleKey: "settings.ai.prompt.title", tab: .ai,
                               keywords: ["提示词", "prompt", "system", "user"]),
            SettingsSearchItem("ai.embedding", titleKey: "settings.aiIndex.section", tab: .ai, target: "ai.embedding",
                               keywords: ["向量", "向量化", "索引", "embedding", "vector"]),
            SettingsSearchItem("ai.repoContext", titleKey: "ai.context.settings.title", tab: .ai, target: "ai.repoContext",
                               keywords: ["代码上下文", "仓库上下文", "context", "token"]),
            SettingsSearchItem("mcp", titleKey: "settings.mcp.title", tab: .mcp,
                               keywords: ["model context protocol", "server", "端口", "隐私"]),
            SettingsSearchItem("services", titleKey: "settings.services.title", tab: .services,
                               keywords: ["服务地址", "trending", "weekly", "api", "endpoint", "状态"]),
            SettingsSearchItem("integrations", titleKey: "settings.integrations.title", tab: .integrations,
                               keywords: ["集成", "integration", "工具"]),
            SettingsSearchItem("integrations.agentRuntime", titleKey: "settings.integration.agentRuntime.title",
                               tab: .integrations, target: "integrations.agentRuntime",
                               keywords: ["agent runtime", "codex", "deepseek"]),
            SettingsSearchItem("integrations.localAPIKey", titleKey: "settings.integration.localAPIKey.title",
                               tab: .integrations, target: "integrations.localAPIKey",
                               keywords: ["本地 api key", "local api key", "鉴权"]),
            SettingsSearchItem("integrations.browserPlugin", titleKey: "settings.integration.browserPlugin.title",
                               tab: .integrations, target: "integrations.browserPlugin",
                               keywords: ["浏览器", "chrome", "safari", "extension", "plugin"]),
            SettingsSearchItem("integrations.externalSearch", titleKey: "settings.externalSearch.section",
                               tab: .integrations, target: "integrations.externalSearch",
                               keywords: ["外部搜索", "anysearch", "search api"]),
            SettingsSearchItem("integrations.codebaseMemory", titleKey: "settings.integrations.title",
                               tab: .integrations, target: "integrations.codebaseMemory",
                               keywords: ["codebase memory", "codebasememory", "代码索引"]),
            SettingsSearchItem("rag.inference", titleKey: "rag.workspace.settings.section.inference", tab: .ragInference,
                               keywords: ["推理", "后端", "inference", "backend", "codex", "claude"]),
            SettingsSearchItem("rag.prompts", titleKey: "rag.workspace.settings.section.prompts", tab: .ragPrompts,
                               keywords: ["提示词", "模板", "prompt", "system", "user"]),
            SettingsSearchItem("rag.retrieval", titleKey: "rag.workspace.settings.section.retrieval", tab: .ragRetrieval,
                               keywords: ["检索", "重排", "向量", "retrieval", "rerank", "vector"]),
            SettingsSearchItem("storage", titleKey: "settings.storage.title", tab: .storage,
                               keywords: ["存储", "缓存", "数据库", "清理", "导出", "storage", "cache", "database"]),
            SettingsSearchItem("diagnostics", titleKey: "settings.diagnostics.title", tab: .diagnostics,
                               keywords: ["诊断", "日志", "遥测", "网络", "diagnostics", "logs", "telemetry"]),
        ]
    }

    private var filteredSearchItems: [SettingsSearchItem] {
        let tokens = normalizedSearchText(settingsSearchText)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return [] }

        return settingsSearchItems.filter { item in
            let title = String.l10n(item.titleKey)
            let tabTitle = String.l10n(item.tab.titleKeyString)
            let haystack = normalizedSearchText(
                ([title, tabTitle] + item.keywords).joined(separator: " ")
            )
            return tokens.allSatisfy(haystack.contains)
        }
    }

    private func normalizedSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func settingsLocation(for target: String) -> SettingsLocation? {
        switch target {
        case "general":
            return SettingsLocation(tab: .general)
        case "pro":
            return SettingsLocation(tab: .pro)
        case "ai", "ai.chat", "ai.embedding", "ai.repoContext":
            return SettingsLocation(tab: .ai, target: target == "ai" ? nil : target)
        case "mcp":
            return SettingsLocation(tab: .mcp)
        case "services":
            return SettingsLocation(tab: .services)
        case "integrations", "integrations.agentRuntime", "integrations.localAPIKey",
             "integrations.browserPlugin", "integrations.externalSearch", "integrations.codebaseMemory":
            return SettingsLocation(tab: .integrations, target: target == "integrations" ? nil : target)
        case "rag", "rag.inference":
            return SettingsLocation(tab: .ragInference)
        case "rag.prompts":
            return SettingsLocation(tab: .ragPrompts)
        case "rag.retrieval":
            return SettingsLocation(tab: .ragRetrieval)
        case "storage":
            return SettingsLocation(tab: .storage)
        case "diagnostics":
            return SettingsLocation(tab: .diagnostics)
        default:
            return nil
        }
    }

    private func navigate(to location: SettingsLocation, recordHistory: Bool = true) {
        if location != currentLocation {
            if recordHistory {
                backwardHistory.append(currentLocation)
                forwardHistory.removeAll()
            }
            currentLocation = location
            selectedTab = location.tab
        }

        reveal(location)
    }

    private func reveal(_ location: SettingsLocation) {
        guard let target = location.target else { return }

        // 新页面要先进入视图树并安装 onReceive，再发送区块定位事件。
        DispatchQueue.main.async {
            switch target {
            case "ai.chat":
                NotificationCenter.default.post(name: .starcatJumpToAIChatModelSection, object: nil)
            case "ai.embedding":
                NotificationCenter.default.post(name: .starcatJumpToAIEmbeddingSection, object: nil)
            case "ai.repoContext":
                NotificationCenter.default.post(name: .starcatJumpToAIRepoContextSection, object: nil)
            case "integrations.agentRuntime", "integrations.localAPIKey", "integrations.browserPlugin",
                 "integrations.externalSearch", "integrations.codebaseMemory":
                isRedispatchingSettingsJump = true
                NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: target)
                isRedispatchingSettingsJump = false
            default:
                break
            }
        }
    }

    private func goBack() {
        guard let destination = backwardHistory.popLast() else { return }
        forwardHistory.append(currentLocation)
        currentLocation = destination
        selectedTab = destination.tab
        reveal(destination)
    }

    private func goForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backwardHistory.append(currentLocation)
        currentLocation = destination
        selectedTab = destination.tab
        reveal(destination)
    }

    private var generalTab: some View {
        @Bindable var settings = settings
        // 2026-06-15:`@State` 持有的 `@Observable` 单例需要 `@Bindable` 局部转换,
        // 才能用 `$localeStore.selection` 的双向 binding 写法,与上面 settings 同款。
        @Bindable var localeStore = localeStore

        return Form {
            Section {
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
                        // 2026-06-15:reduceMotion 兜底——主题切换的颜色淡变在
                        // 关动画时改为瞬切。`withAnimation(nil)` 让 binding 写入
                        // 不挂任何 transaction,@Observable 属性变化按默认无包裹路径。
                        if reduceMotion {
                            settings.appearanceMode = newValue
                        } else {
                            withAnimation(.easeInOut(duration: 0.6)) {
                                settings.appearanceMode = newValue
                            }
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

                Picker("settings.general.interfaceScale", selection: $settings.interfaceScale) {
                    ForEach(InterfaceScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)

                Text("settings.general.interfaceScale.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // R-01 §3.1.1（2026-06-10 P1）：列表密度 Picker 已彻底移除——
                // RepoListDensity 枚举本身也已删除（之前为保签名稳定保留单 case
                // 是「自留技术债」，现在所有 row / skeleton 视图直接用 card 密度）。
            } header: {
                SettingsSectionHeader(
                    "settings.general.appearance",
                    systemImage: "paintbrush.fill",
                    style: .prominent
                )
            }

            // 2026-06-15 dong4j 需求：用户面向的语言切换。
            //
            // 设计要点：
            // 1. `LocaleStore` 是 `@MainActor @Observable` 单例，主窗口与 Settings
            //    两个 scene 共享同一份选择；切换后由 `StarcatApp` 在 `.environment(\.locale, _)`
            //    + `.id(...)` 配合下整棵 view 树立刻重建，不需要重启 App。
            // 2. 默认 `system`：跟随系统设置，`Locale.autoupdatingCurrent` 让
            //    macOS Language & Region 改变时 Starcat 自动同步。
            // 3. 跟随系统用 🌐、其余 18 种语言用“国旗 + 母语名称”。具体语言故意
            //    不跟随当前 UI locale 翻译，与 macOS Language & Region 列出语言时
            //    的惯例一致——哪怕用户误切到看不懂的语言，也能从国旗和母语写法
            //    找回入口。
            // 4. 已知局限（与 DEBUG 菜单 picker 一致，写在 `LocaleStore.swift`
            //    顶部注释里）：`.environment(\.locale, _)` 只覆盖 SwiftUI 视图层
            //    `Text("key")` 等查表行为；macOS 顶部菜单栏 NSMenu 与部分
            //    AppKit 弹窗的字符串走 `Bundle.main.localized*` 在 App 启动时
            //    一次性加载，**不**会跟随 environment 切换刷新。如果用户期望连
            //    菜单栏一起切，必须重启 App（说明文字里已提示）。
            // 5. 放在「外观」后作为第二分组：显示语言与主题同属启动即感知的界面偏好。
            Section {
                Picker(selection: $localeStore.selection) {
                    ForEach(AppLocale.allCases) { option in
                        option.menuTitle.tag(option)
                    }
                } label: {
                    Text("settings.general.language.label")
                }
                .pickerStyle(.menu)

                Text("settings.general.language.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(
                    "settings.general.language",
                    systemImage: "globe",
                    style: .prominent
                )
            }

            Section {
                Text("settings.general.oauthScopes.summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AppConstants.githubOAuthScopes, id: \.self) { scope in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(scope)
                            .font(.body.monospaced())

                        Spacer(minLength: 16)

                        Text(githubOAuthScopeDescriptionKey(for: scope))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Text("settings.general.oauthScopes.organizationHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(
                    "settings.general.oauthScopes.section",
                    systemImage: "lock.shield.fill",
                    style: .prominent
                )
            }

            // 数据贡献严格默认关闭且按 GitHub 账号隔离。这里只展示一个授权开关；
            // 上传数量、时间、失败和重试均属于后台旁路状态，不进入用户界面。
            Section {
                Toggle(isOn: Binding(
                    get: { dependencies.dataContributionSettings.isEnabled },
                    set: { newValue in
                        guard let accountID = dependencies.database.currentUserId else { return }
                        Task {
                            await dependencies.dataContributionSettings.setEnabled(
                                newValue,
                                accountID: accountID
                            )
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.dataContribution.title")
                        Text("settings.general.dataContribution.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(dependencies.database.currentUserId == nil)
            } header: {
                SettingsSectionHeader(
                    "settings.general.dataContribution.section",
                    systemImage: "hand.raised.fill",
                    style: .prominent
                )
            }

            // HOM-SNAKE-MODES 2026-06-05：贡献草坪贪吃蛇玩法。
            // 用 Menu 风格 Picker 而非 segmented——6 个选项 segmented 会过宽，
            // 而且每项都带 SF Symbol，菜单展开形态视觉信息密度更高。
            // 设计取舍：把贪吃蛇配置放在 General 而非新建 "Sidebar" Tab，是因为
            // 当前 Sidebar 可配置项只有这一个，单独开 Tab 显得空；后续若新增
            // sidebar 偏好（如折叠默认态、密度）再拆分。
            Section {
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
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(
                    "settings.snakeStyle.section",
                    systemImage: "arcade.stick.console.fill",
                    style: .prominent
                )
            }

            Section {
                Toggle(isOn: $settings.openFirstDetailOnCategoryChange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.openFirstDetailOnCategoryChange.title")
                        Text("settings.general.openFirstDetailOnCategoryChange.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.openRepositoryMarkdownInApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.openRepositoryMarkdownInApp.title")
                        Text("settings.general.openRepositoryMarkdownInApp.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.general.detailBehavior",
                    systemImage: "sidebar.left",
                    style: .prominent
                )
            }

            InterestedLanguagesSettingsSection(languages: $settings.interestedLanguages)

            // 快捷键偏好集中在 General，都是本机交互习惯，不属于 AI 模型配置。
            Section {
                Toggle(isOn: $settings.aiChatRequiresCommandReturn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.shortcuts.aiCommandReturn.title")
                        Text(
                            settings.aiChatRequiresCommandReturn
                                ? "settings.general.shortcuts.aiCommandReturn.description.on"
                                : "settings.general.shortcuts.aiCommandReturn.description.off"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 应用命令快捷键总开关只控制键盘触发；AI 输入发送方式是独立偏好，
                // 因此保留在总开关上方且不会被 `.disabled(...)` 连带关闭。
                Toggle(isOn: $settings.keyboardShortcutsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.shortcuts.enabled.title")
                        Text("settings.general.shortcuts.enabled.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ConfigurableShortcutSettingRow(
                    titleKey: "settings.general.shortcuts.search.title",
                    shortcut: $settings.globalSearchShortcut,
                    defaultShortcut: ConfigurableShortcutAction.globalSearch.defaultShortcut,
                    isEnabled: $settings.globalSearchShortcutEnabled,
                    onValidationError: { shortcutValidationError = $0 },
                    conflictingShortcuts: conflictingShortcuts(excluding: .globalSearch),
                    helpKey: "settings.general.shortcuts.search.help",
                    onShortcutChanged: { shortcutValidationError = nil },
                    onRestoreDefault: { restoreShortcutDefault(.globalSearch) }
                )
                .disabled(!settings.keyboardShortcutsEnabled)

                ConfigurableShortcutSettingRow(
                    titleKey: "settings.general.shortcuts.regularSearch.title",
                    shortcut: $settings.regularSearchShortcut,
                    defaultShortcut: ConfigurableShortcutAction.regularSearch.defaultShortcut,
                    isEnabled: $settings.regularSearchShortcutEnabled,
                    onValidationError: { shortcutValidationError = $0 },
                    conflictingShortcuts: conflictingShortcuts(excluding: .regularSearch),
                    helpKey: "settings.general.shortcuts.regularSearch.help",
                    onShortcutChanged: { shortcutValidationError = nil },
                    onRestoreDefault: { restoreShortcutDefault(.regularSearch) }
                )
                .disabled(!settings.keyboardShortcutsEnabled)

                ConfigurableShortcutSettingRow(
                    titleKey: "settings.general.shortcuts.readmeFind.title",
                    shortcut: $settings.readmeFindShortcut,
                    defaultShortcut: ConfigurableShortcutAction.readmeFind.defaultShortcut,
                    isEnabled: $settings.readmeFindShortcutEnabled,
                    onValidationError: { shortcutValidationError = $0 },
                    conflictingShortcuts: conflictingShortcuts(excluding: .readmeFind),
                    helpKey: "settings.general.shortcuts.readmeFind.help",
                    onShortcutChanged: { shortcutValidationError = nil },
                    onRestoreDefault: { restoreShortcutDefault(.readmeFind) }
                )
                .disabled(!settings.keyboardShortcutsEnabled)

                ConfigurableShortcutSettingRow(
                    titleKey: "settings.general.shortcuts.refreshCurrentContent.title",
                    shortcut: $settings.refreshCurrentContentShortcut,
                    defaultShortcut: ConfigurableShortcutAction.refreshCurrentContent.defaultShortcut,
                    isEnabled: $settings.refreshCurrentContentShortcutEnabled,
                    onValidationError: { shortcutValidationError = $0 },
                    conflictingShortcuts: conflictingShortcuts(excluding: .refreshCurrentContent),
                    helpKey: "settings.general.shortcuts.refreshCurrentContent.help",
                    onShortcutChanged: { shortcutValidationError = nil },
                    onRestoreDefault: { restoreShortcutDefault(.refreshCurrentContent) }
                )
                .disabled(!settings.keyboardShortcutsEnabled)

                ConfigurableShortcutSettingRow(
                    titleKey: "settings.general.shortcuts.knowledgeRAG.title",
                    shortcut: $settings.knowledgeRAGShortcut,
                    defaultShortcut: ConfigurableShortcutAction.knowledgeRAG.defaultShortcut,
                    isEnabled: $settings.knowledgeRAGShortcutEnabled,
                    onValidationError: { shortcutValidationError = $0 },
                    conflictingShortcuts: conflictingShortcuts(excluding: .knowledgeRAG),
                    helpKey: "settings.general.shortcuts.knowledgeRAG.help",
                    onShortcutChanged: { shortcutValidationError = nil },
                    onRestoreDefault: { restoreShortcutDefault(.knowledgeRAG) }
                )
                .disabled(!settings.keyboardShortcutsEnabled)

                ConfigurableShortcutSettingRow(
                    titleKey: "settings.general.shortcuts.selectedRepoAI.title",
                    shortcut: $settings.selectedRepoAIShortcut,
                    defaultShortcut: ConfigurableShortcutAction.selectedRepoAI.defaultShortcut,
                    isEnabled: $settings.selectedRepoAIShortcutEnabled,
                    onValidationError: { shortcutValidationError = $0 },
                    conflictingShortcuts: conflictingShortcuts(excluding: .selectedRepoAI),
                    helpKey: "settings.general.shortcuts.selectedRepoAI.help",
                    onShortcutChanged: { shortcutValidationError = nil },
                    onRestoreDefault: { restoreShortcutDefault(.selectedRepoAI) }
                )
                .disabled(!settings.keyboardShortcutsEnabled)

                if let shortcutValidationError {
                    Text(shortcutValidationMessageKey(shortcutValidationError))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("settings.general.shortcuts.configuration.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(
                    "settings.general.shortcuts",
                    systemImage: "keyboard",
                    style: .prominent
                )
            }

            // 2026-06-20：系统通知策略入口。
            // 通知只用于「用户离开 App 后需要回来处理」的低频事件；普通状态变化继续留在
            // toolbar 状态面板，避免把通知中心变成运行日志。
            Section {
                Toggle(isOn: $settings.notificationsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.notifications.enabled.title")
                        Text("settings.notifications.enabled.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("settings.notifications.release.title", isOn: $settings.releaseNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.githubInbox.title", isOn: $settings.githubInboxNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.batchAI.title", isOn: $settings.batchAINotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.syncIssues.title", isOn: $settings.syncIssueNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
                Toggle("settings.notifications.mcpIssues.title", isOn: $settings.mcpIssueNotificationsEnabled)
                    .disabled(!settings.notificationsEnabled)
            } header: {
                SettingsSectionHeader(
                    "settings.notifications.title",
                    systemImage: "bell",
                    style: .prominent
                )
            }

            Section {
                Toggle(isOn: $settings.githubIssueEventTimelineEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.activity.issueEvents.title")
                        Text("settings.activity.issueEvents.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.activity.section",
                    systemImage: "list.bullet.rectangle",
                    style: .prominent
                )
            }

            // 2026-06-15 dong4j 需求：无障碍 / 动画偏好。
            //
            // 单独起一个 Section 而不是夹在「外观」里——「关闭应用内动画」
            // 是无障碍语义（与系统「辅助功能 → 减少动态效果」同源），与外观
            // 主题（视觉偏好）属于不同维度；后续若新增其它无障碍配置
            // （如字号缩放、对比度增强），都归在本 Section。
            //
            // 实现机制：toggle ON 时由 `AnimationOverrideModifier` 在 root view
            // 上覆盖 `accessibilityReduceMotion` 环境值，全工程 30+ 个已实现
            // reduceMotion 兜底路径的视图自动尊重新偏好（与系统级减少动态
            // 效果走同一套代码路径）。详见 `Shared/Components/AnimationOverrideModifier.swift`。
            Section {
                Toggle(isOn: $settings.disableAnimations) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.disableAnimations.title")
                        Text("settings.general.disableAnimations.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.general.accessibility",
                    systemImage: "figure.roll",
                    style: .prominent
                )
            }

            Section {
                Toggle(isOn: $settings.hideDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.hideDockIcon.title")
                        Text("settings.general.hideDockIcon.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.spotlightSearchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.general.spotlightSearch.title")
                        Text("settings.general.spotlightSearch.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.general.macOSIntegration",
                    systemImage: "macwindow.on.rectangle",
                    style: .prominent
                )
            }

            // Sparkle 自动更新只存在于 Direct 分发；App Store 构建必须整段隐藏，
            // 避免审核包暴露自更新入口（与菜单栏 / Help「检查更新」同一门控）。
            if DistributionChannel.current.isDirect {
                directUpdateSection
            }

            Section {
                HStack {
                    Spacer()

                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        NotificationCenter.default.post(
                            name: .starcatResetListPreferencesRequested,
                            object: nil
                        )
                    } label: {
                        Label("settings.listPreferences.reset.title", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!dependencies.authSession.state.isAuthenticated)
                    .help(Text("settings.listPreferences.reset.disabled"))

                    Button {
                        guard FirstRunOnboardingPreferences.canReplayManually else { return }
                        NSApp.keyWindow?.close()
                        FirstRunOnboardingPreferences.requestManualReplay()
                    } label: {
                        Label("settings.general.resetOnboarding", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!FirstRunOnboardingPreferences.canReplayManually)
                }
            } header: {
                SettingsSectionHeader(
                    "settings.general.other",
                    systemImage: "ellipsis.circle",
                    style: .prominent
                )
            }
        }
        .formStyle(.grouped)
    }

    /// 权限说明直接映射登录流程使用的 scope 常量，避免设置页与真实授权请求漂移。
    private func githubOAuthScopeDescriptionKey(for scope: String) -> LocalizedStringKey {
        switch scope {
        case "read:user":
            "settings.general.oauthScopes.readUser"
        case "public_repo":
            "settings.general.oauthScopes.publicRepo"
        case "user":
            "settings.general.oauthScopes.user"
        case "notifications":
            "settings.general.oauthScopes.notifications"
        default:
            "settings.general.oauthScopes.unknown"
        }
    }

    /// Direct 版 Sparkle 更新偏好。仅在 `DistributionChannel.current.isDirect` 为真时挂入通用设置。
    private var directUpdateSection: some View {
        let updateController = dependencies.directUpdateController

        return Section {
            Toggle("settings.pro.direct.updates.autoCheck", isOn: Binding(
                get: { updateController.automaticallyChecksForUpdates },
                set: { updateController.automaticallyChecksForUpdates = $0 }
            ))
            .disabled(!dependencies.directUpdateController.isConfigured)

            Toggle("settings.pro.direct.updates.autoDownload", isOn: Binding(
                get: { updateController.automaticallyDownloadsUpdates },
                set: { updateController.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!dependencies.directUpdateController.isConfigured || !updateController.automaticallyChecksForUpdates)

            // 「检查更新」是一次性动作，按设置页按钮右对齐规范推到右侧。
            HStack {
                Spacer()
                Button {
                    dependencies.directUpdateController.checkForUpdates()
                } label: {
                    Label("settings.pro.direct.updates.check", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!dependencies.directUpdateController.canCheckForUpdates)
            }
        } header: {
            SettingsSectionHeader(
                "settings.pro.direct.updates.section",
                systemImage: "arrow.triangle.2.circlepath",
                style: .prominent
            )
        } footer: {
            Text(LocalizedStringKey(dependencies.directUpdateController.isConfigured
                                    ? "settings.pro.direct.updates.footer"
                                    : "settings.pro.direct.updates.notConfigured"))
        }
    }

    private func shortcutValidationMessageKey(
        _ error: KeyboardShortcutConfiguration.ValidationError
    ) -> LocalizedStringKey {
        switch error {
        case .invalidKey:
            return "settings.general.shortcuts.error.invalidKey"
        case .missingModifier:
            return "settings.general.shortcuts.error.missingModifier"
        case .reserved:
            return "settings.general.shortcuts.error.reserved"
        case .duplicateConfiguredAction:
            return "settings.general.shortcuts.error.duplicateConfiguredAction"
        }
    }

    /// 返回除当前动作外的五个已保存键位。
    /// 关闭状态仍参与冲突检查，确保重新开启时不会与其它命令竞争同一组合。
    private func conflictingShortcuts(
        excluding action: ConfigurableShortcutAction
    ) -> Set<KeyboardShortcutConfiguration> {
        Set(ConfigurableShortcutAction.allCases.compactMap { candidate in
            candidate == action ? nil : shortcut(for: candidate)
        })
    }

    /// 恢复默认值时递归释放被其它动作占用的默认组合。
    ///
    /// 例如 A 使用 B 的默认键、B 又使用 A 的默认键时，先把整条占用链恢复到各自默认，
    /// 再落当前动作；`visited` 用于打断这种交换环，最终仍保持六项唯一。
    private func restoreShortcutDefault(_ action: ConfigurableShortcutAction) {
        var visited: Set<ConfigurableShortcutAction> = []

        func restore(_ current: ConfigurableShortcutAction) {
            guard visited.insert(current).inserted else { return }
            let defaultShortcut = current.defaultShortcut
            if let occupant = ConfigurableShortcutAction.allCases.first(where: {
                $0 != current && shortcut(for: $0) == defaultShortcut
            }) {
                restore(occupant)
            }
            setShortcut(defaultShortcut, for: current)
        }

        restore(action)
        shortcutValidationError = nil
    }

    private func shortcut(
        for action: ConfigurableShortcutAction
    ) -> KeyboardShortcutConfiguration {
        switch action {
        case .globalSearch:
            return settings.globalSearchShortcut
        case .regularSearch:
            return settings.regularSearchShortcut
        case .readmeFind:
            return settings.readmeFindShortcut
        case .refreshCurrentContent:
            return settings.refreshCurrentContentShortcut
        case .knowledgeRAG:
            return settings.knowledgeRAGShortcut
        case .selectedRepoAI:
            return settings.selectedRepoAIShortcut
        }
    }

    private func setShortcut(
        _ shortcut: KeyboardShortcutConfiguration,
        for action: ConfigurableShortcutAction
    ) {
        switch action {
        case .globalSearch:
            settings.globalSearchShortcut = shortcut
        case .regularSearch:
            settings.regularSearchShortcut = shortcut
        case .readmeFind:
            settings.readmeFindShortcut = shortcut
        case .refreshCurrentContent:
            settings.refreshCurrentContentShortcut = shortcut
        case .knowledgeRAG:
            settings.knowledgeRAGShortcut = shortcut
        case .selectedRepoAI:
            settings.selectedRepoAIShortcut = shortcut
        }
    }
}

/// 设置页里的“感兴趣语言”长期偏好。
///
/// 这里不读取任何列表数据：设置页负责维护候选池，toolbar 负责从候选池里做本次筛选。
/// 常用语言按钮覆盖主流场景；搜索框只允许从 GitHub Linguist 语言目录点选添加，
/// 避免任意字符串污染全局语言筛选候选池。
private struct InterestedLanguagesSettingsSection: View {

    @Binding var languages: [String]
    @State private var draftLanguage = ""
    @State private var showingLanguagePicker = false
    @State private var isHoveringAddLanguage = false

    private let presets = [
        "C", "C#", "C++", "Dart",
        "Go", "HTML", "Java", "JavaScript",
        "Kotlin", "Objective-C", "PHP", "Python",
        "Ruby", "Rust", "Shell", "Swift", "TypeScript",
        "Vue"
    ]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.filters.interestedLanguages.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                FlowLayout(spacing: 8) {
                    ForEach(presets, id: \.self) { language in
                        languagePresetChip(language)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        draftLanguage = ""
                        showingLanguagePicker = true
                    } label: {
                        addLanguageIcon
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(Text("settings.filters.interestedLanguages.add"))
                    .accessibilityLabel(Text("settings.filters.interestedLanguages.add"))
                    .onHover { isHoveringAddLanguage = $0 }
                    .popover(isPresented: $showingLanguagePicker, arrowEdge: .trailing) {
                        languagePickerPopover
                            .frame(width: 280, height: 300)
                            .padding(14)
                    }
                }

                Divider()

                if customLanguages.isEmpty {
                    Text("settings.filters.interestedLanguages.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowTagList(tags: customLanguages, removeAction: removeLanguage)
                }
            }
        } header: {
            SettingsSectionHeader(
                "settings.filters.interestedLanguages.section",
                systemImage: "chevron.left.forwardslash.chevron.right",
                style: .prominent
            )
        }
    }

    private var normalizedDraft: String {
        draftLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [String] {
        LinguistLanguageCatalog.search(normalizedDraft)
    }

    private var customLanguages: [String] {
        languages.filter { language in
            !isPresetLanguage(language)
        }
    }

    private func binding(for language: String) -> Binding<Bool> {
        Binding(
            get: { contains(language) },
            set: { isOn in
                if isOn {
                    addLanguage(language)
                } else {
                    removeLanguage(language)
                }
            }
        )
    }

    private func languagePresetChip(_ language: String) -> some View {
        Button {
            if contains(language) {
                removeLanguage(language)
            } else {
                addLanguage(language)
            }
        } label: {
            HStack(spacing: 6) {
                LanguageIconView(language: language, size: 14)
                Text(LanguageDisplayName.shortened(for: language))
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(presetChipBackground(for: language), in: Capsule())
            .foregroundStyle(contains(language) ? .white : .primary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func presetChipBackground(for language: String) -> Color {
        contains(language) ? .accentColor : Color(nsColor: .controlBackgroundColor)
    }

    private var addLanguageIcon: some View {
        // 对齐集成页 `tokenActionIcon` 的标准小工具图标规格：13pt / 24×22 / 圆角 6，
        // 避免这个 + 比设置页其它图标按钮更抢眼。
        Image(systemName: "plus")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.secondary)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(isHoveringAddLanguage ? 0.14 : 0.10))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var languagePickerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("settings.filters.interestedLanguages.add.placeholder", text: $draftLanguage)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addExactDraftLanguageIfPossible)

            Group {
                if normalizedDraft.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("settings.filters.interestedLanguages.add.placeholder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    Text("settings.filters.interestedLanguages.search.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(searchResults, id: \.self) { language in
                                languageSearchResultRow(language)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func languageSearchResultRow(_ language: String) -> some View {
        Button {
            if contains(language) {
                removeLanguage(language)
            } else {
                addLanguage(language)
            }
            showingLanguagePicker = true
        } label: {
            HStack(spacing: 8) {
                LanguageIconView(language: language, size: 16)
                Text(LanguageDisplayName.shortened(for: language))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if contains(language) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(contains(language) ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func addExactDraftLanguageIfPossible() {
        guard let language = LinguistLanguageCatalog.canonicalName(for: normalizedDraft) else { return }
        addLanguage(language)
        showingLanguagePicker = true
    }

    private func addLanguage(_ language: String) {
        languages = AppSettings.normalizedLanguageList(languages + [language])
    }

    private func removeLanguage(_ language: String) {
        languages = languages.filter { $0.caseInsensitiveCompare(language) != .orderedSame }
    }

    private func contains(_ language: String) -> Bool {
        languages.contains { $0.caseInsensitiveCompare(language) == .orderedSame }
    }

    private func isPresetLanguage(_ language: String) -> Bool {
        presets.contains { $0.caseInsensitiveCompare(language) == .orderedSame }
    }
}

/// 简单的可换行 tag 列表。
///
/// macOS 设置窗口宽度固定，语言数量不可预估；这里使用自定义 Layout 避免 HStack
/// 挤压或 ScrollView 嵌套，把用户已选语言稳定展示成多行 chip。
private struct FlowTagList: View {
    let tags: [String]
    let removeAction: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { language in
                HStack(spacing: 6) {
                    LanguageIconView(language: language, size: 13)
                    Text(LanguageDisplayName.shortened(for: language))
                        .font(.caption)
                        .lineLimit(1)
                    Button {
                        removeAction(language)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel(Text("settings.filters.interestedLanguages.remove"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
        }
    }
}

/// 设置页局部使用的轻量换行布局。
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let maxWidth = max(width, 1)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (origins, CGSize(width: maxWidth, height: y + rowHeight))
    }
}

// MARK: - 诊断 Tab（2026-06-20）

/// 调试日志导出面板。
///
/// 这里不是“日志清理”功能：系统 OSLog 仍由 Console.app 管理。本 Tab 只负责把 Starcat
/// 自己记录的关键诊断事件打包，便于用户遇到外部服务不可用、AI provider 异常或本地
/// 数据问题时，把最小必要证据交给 dong4j 排查。
private struct DiagnosticsSettingsTab: View {

    @Environment(AppSettings.self) private var settings

    @State private var isExporting = false
    @State private var lastExportMessage: String?
    @State private var exportError: String?

    var body: some View {
        @Bindable var settings = settings

        return Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        // 导出入口需要和说明文字保持同一行；窗口较窄时优先截断说明，
                        // 避免按钮被 Form 布局挤到第二行。
                        Text("settings.diagnostics.export.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        Button {
                            Task { await exportDiagnostics() }
                        } label: {
                            Label("diagnostics.export.button", systemImage: "square.and.arrow.up")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(isExporting)
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    if isExporting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("settings.diagnostics.export.running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let lastExportMessage {
                        Text(verbatim: lastExportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.diagnostics.export.section",
                    systemImage: "square.and.arrow.up",
                    style: .prominent
                )
            }

            Section {
                Toggle(isOn: $settings.telemetryEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.diagnostics.telemetry.enabled.title")
                        Text("settings.diagnostics.telemetry.enabled.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("settings.diagnostics.telemetry.privacy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(
                    "settings.diagnostics.telemetry.section",
                    systemImage: "chart.bar",
                    style: .prominent
                )
            }

            Section {
                Text("settings.diagnostics.privacy.description")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                SettingsSectionHeader(
                    "settings.diagnostics.privacy.section",
                    systemImage: "lock.shield",
                    style: .prominent
                )
            }
        }
        .formStyle(.grouped)
        .alert(
            "diagnostics.export.failed.title",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("general.ok") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @MainActor
    private func exportDiagnostics() async {
        isExporting = true
        defer { isExporting = false }

        switch await DiagnosticBundleExporter.exportFromPanel(settings: settings) {
        case .exported(_):
            // 导出器成功后已经标记诊断问题为已处理；这里用固定反馈同步告知状态已重置。
            lastExportMessage = String.l10n("settings.diagnostics.export.successMessage")
        case .cancelled:
            break
        case .failed(let message):
            exportError = message
        }
    }
}

// MARK: - 存储 Tab（HOM-68 v3 / 2026-06-15 大重构）
//
// 重构背景（dong4j 2026-06-15 拍板）：
//   原设计把"缓存用量"（只读统计）和"清理操作"（按钮列表）做成两个独立 Section，
//   导致用户必须在两个分组之间来回比对：先看用量决定要不要清，再去下一个分组找对应的按钮。
//   同时 AI 代码上下文产物管理整段又在 storage Tab 占了一大块（输出目录 + 项目列表），
//   而 CodeFlow 的同类面板放在 集成 Tab，两边职责不一致。
//
// 重构后职责划分：
//   - 存储 Tab → 缓存用量：**全局汇总 + 总闸**。每行 = 一类缓存，行内显示用量数字 +
//     "清理"按钮；底部一个"清除全部缓存" destructive 总按钮。覆盖 7 类：
//     README / 图片 / ZIP / 翻译 / AnySearch / AI 代码上下文 / CodeFlow。
//   - AI 设置 → AI 代码上下文(实验)：**这一类的精细化操作**（输出目录、单项目删除、
//     在 Finder 显示）。"一键清除"按钮搬到存储 Tab，本地不再保留。
//   - 集成 → CodeFlow：同上，"一键清除"按钮也搬到存储 Tab。
//
// 关键设计约束：
//   1. 行内"清理"按钮统一走 confirmationDialog（PendingAction enum 驱动），
//      所有类目共享一套确认/失败处理代码，避免每类一套独立 alert 像旧实现那样。
//   2. 翻译 / AnySearch 原本各自走独立 alert，本次合并到 PendingAction.translation /
//      .anySearch——视觉一致 + 代码量减半。
//   3. 日志行删除（dong4j q3 拍板）：既然系统 Console.app 管理、用户无法操作，
//      就别放在"缓存用量"里假装可清理，反而误导。
//   4. ZIP 行保留 Finder 显示按钮（dong4j q2）：放在"清理"按钮左边。
//   5. AI 上下文 / CodeFlow 行用量基于各自单例 @Observable 的 `projects.count` /
//      `totalBytes`，不再走 CacheStatistics——CacheCleaner 不感知这两类（它们各自
//      的 storage 单例管理生命周期，CacheCleaner 不应越权依赖单例）。

/// 缓存统计与清理面板。
private struct StorageSettingsTab: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale

    let readmeRepository: ReadmeRepository

    @State private var stats: CacheStatistics = .empty
    @State private var statsRefreshTask: Task<Void, Never>?
    @State private var isWorking: Bool = false
    @State private var isResettingAllData: Bool = false
    /// 当前显示的确认弹窗类型；nil 表示不显示。
    @State private var pendingAction: PendingAction?
    @State private var isShowingClearAllCachesSheet = false
    @State private var resetTarget: AppDataResetTarget?
    @State private var resetDidComplete = false
    @State private var storageActionError: String?
    @State private var isTriggeringReadmePrefetch = false
    @State private var ragIndexBytes: Int64 = 0
    @State private var ragConversationStats: RAGConversationStatistics = .empty

    /// AI 代码上下文产物（精细化面板已搬到 AISettingsView，本 Tab 仅消费汇总数字
    /// + "清除全部"入口）。`@Observable` 单例直接订阅，外部 storage 写入立即反映。
    @State private var aiContextStorage = RepoContextStorage.shared

    /// CodeFlow 产物（精细化面板留在 IntegrationSettingsView，本 Tab 同 AI 上下文）。
    @State private var codeFlowStorage = CodeFlowStorage.shared

    @State private var codebaseMemoryStorage = CodebaseMemoryStorage.shared

    /// 翻译磁盘缓存：`@MainActor @Observable` 单例，UI 直接读 `totalBytes` /
    /// `itemCount`。删除走默认 appSupport 路径，无 bookmark 等额外失败面，
    /// 失败极少；统一走 storageActionError。
    @State private var translationCache = DiskReadmeTranslationCache.shared

    /// External Search 磁盘缓存：global + AI External Context 子目录合并清除。
    /// 用户心智是"清外部搜索缓存"而不是分别清 provider / 子目录。
    @State private var externalSearchCache = DiskExternalSearchCache.shared

    /// Wiki 探测结果磁盘缓存（2026-06-15 v4.y）：DeepWiki / ZRead / CodeWiki 单仓查询
    /// 结果按 owner/repo 落盘。注入 AI Chat system prompt 的 `{starcatResources}` 段。
    @State private var wikiCache = DiskWikiCache.shared

    /// Issue / PR 事件流磁盘缓存：按 owner/repo/number 落盘。
    @State private var issueTimelineCache = DiskIssueTimelineCache.shared
    @State private var issueCommentDraftCache = DiskNotificationCommentDraftCache.shared

    /// 推荐结果磁盘缓存（2026-06-29，与 wiki 同款形态）：按 repoID 落盘，
    /// TTL 7d（有 items）/ 1h（空）。详情页 `RecommendationContextService` 读取 + 写盘。
    @State private var recommendationCache = DiskRecommendationCache.shared

    /// HOM-70：AI 对话历史磁盘存储（按 repo 多 session）。
    /// 设置页 Tab 仅消费汇总数字 + "清除全部"入口，单 session 删除由对话窗口自己管理。
    @State private var chatHistoryStore = DiskChatHistoryStore.shared

    /// 行内"清理"按钮的待执行动作。
    /// 单项缓存使用系统 alert 二次确认，保持 macOS 标准标题 / 正文层级；
    /// "删除全部缓存"已经升级为危险区 sheet，但保留 `.all` 作为执行分支，避免复制清理代码。
    private enum PendingAction: Identifiable {
        case readme, image, archive, translation, anySearch, wiki, issueTimeline, issueCommentDraft, recommendation, chatHistory
        case ragIndex, ragHistory, aiContext, codeFlow, codebaseMemory, all
        var id: String {
            switch self {
            case .readme:       return "readme"
            case .image:        return "image"
            case .archive:      return "archive"
            case .translation:  return "translation"
            case .anySearch:    return "anySearch"
            case .wiki:         return "wiki"
            case .issueTimeline: return "issueTimeline"
            case .issueCommentDraft: return "issueCommentDraft"
            case .recommendation: return "recommendation"
            case .chatHistory:  return "chatHistory"
            case .ragIndex:     return "ragIndex"
            case .ragHistory:   return "ragHistory"
            case .aiContext:    return "aiContext"
            case .codeFlow:     return "codeFlow"
            case .codebaseMemory: return "codebaseMemory"
            case .all:          return "all"
            }
        }
        func confirmTitle(locale: Locale) -> String {
            switch self {
            case .readme:       return String.l10n("settings.storage.clearReadme.confirm")
            case .image:        return String.l10n("settings.storage.clearImage.confirm")
            case .archive:      return String.l10n("settings.storage.clearArchive.confirm")
            case .translation:  return String.l10n("settings.storage.clearTranslation.confirm")
            case .anySearch:    return String.l10n("settings.storage.clearAnySearch.confirm")
            case .wiki:         return String.l10n("settings.storage.clearWiki.confirm")
            case .issueTimeline: return String.l10n("settings.storage.clearIssueTimeline.confirm")
            case .issueCommentDraft: return String.l10n("settings.storage.clearIssueCommentDraft.confirm")
            case .recommendation: return String.l10n("settings.storage.clearRecommendation.confirm")
            case .chatHistory:  return String.l10n("settings.storage.clearChatHistory.confirm")
            case .ragIndex:     return String.l10n("settings.storage.clearRAGIndex.confirm")
            case .ragHistory:   return String.l10n("settings.storage.clearRAGHistory.confirm")
            case .aiContext:    return String.l10n("settings.storage.clearAiContext.confirm")
            case .codeFlow:     return String.l10n("settings.storage.clearCodeFlow.confirm")
            case .codebaseMemory: return String.l10n("settings.storage.clearCodebaseMemory.confirm")
            case .all:          return String.l10n("settings.storage.clearAll.confirm")
            }
        }
        func confirmMessage(locale: Locale) -> String {
            switch self {
            case .readme:       return String.l10n("settings.storage.clearReadme.message")
            case .image:        return String.l10n("settings.storage.clearImage.message")
            case .archive:      return String.l10n("settings.storage.clearArchive.message")
            case .translation:  return String.l10n("settings.storage.clearTranslation.message")
            case .anySearch:    return String.l10n("settings.storage.clearAnySearch.message")
            case .wiki:         return String.l10n("settings.storage.clearWiki.message")
            case .issueTimeline: return String.l10n("settings.storage.clearIssueTimeline.message")
            case .issueCommentDraft: return String.l10n("settings.storage.clearIssueCommentDraft.message")
            case .recommendation: return String.l10n("settings.storage.clearRecommendation.message")
            case .chatHistory:  return String.l10n("settings.storage.clearChatHistory.message")
            case .ragIndex:     return String.l10n("settings.storage.clearRAGIndex.message")
            case .ragHistory:   return String.l10n("settings.storage.clearRAGHistory.message")
            case .aiContext:    return String.l10n("settings.storage.clearAiContext.message")
            case .codeFlow:     return String.l10n("settings.storage.clearCodeFlow.message")
            case .codebaseMemory: return String.l10n("settings.storage.clearCodebaseMemory.message")
            case .all:          return String.l10n("settings.storage.clearAll.message")
            }
        }
    }

    /// 9 类缓存全空时,"清除全部缓存"按钮 disabled,避免无意义点击。
    /// HOM-203：AI 上下文 / CodeFlow 改读 summary.projectCount，避免触发 projects 扫描。
    private var isAllCachesEmpty: Bool {
        stats.totalBytes == 0
            && translationCache.itemCount == 0
            && externalSearchCache.itemCount == 0
            && wikiCache.itemCount == 0
            && issueTimelineCache.itemCount == 0
            && issueCommentDraftCache.itemCount == 0
            && recommendationCache.itemCount == 0
            && chatHistoryStore.sessionCount == 0
            && ragIndexBytes == 0
            && ragConversationStats.conversationCount == 0
            && aiContextStorage.projectCount == 0
            && codeFlowStorage.projectCount == 0
            && codebaseMemoryStorage.projectCount == 0
    }

    private var currentResetTarget: AppDataResetTarget? {
        guard let user = authSession.state.user else { return nil }
        return AppDataResetTarget(userID: user.id, login: user.login)
    }

    private var isLoggedIn: Bool {
        currentResetTarget != nil
    }

    /// 未登录时禁止 Storage 页里的实际操作控件，但不能禁用 Form 根视图。
    /// SwiftUI 会把 `.disabled` 环境传给滚动容器；若挂在 Form 上，未登录提示页也会无法滚动。
    private var shouldDisableStorageActions: Bool {
        isResettingAllData || !isLoggedIn
    }

    private var shouldDisableReadmePrefetchRunNow: Bool {
        shouldDisableStorageActions
            || !settings.readmePrefetchEnabled
            || dependencies.readmePrefetchService.isRunning
            || dependencies.readmePrefetchPoller.isDraining
            || dependencies.initialWarmupCoordinator.isRunning
            || isTriggeringReadmePrefetch
    }

    var body: some View {
        let cleaner = CacheCleaner(readmeRepository: readmeRepository)
        @Bindable var settings = settings
        return Form {
            if !isLoggedIn {
                Section {
                    Text("settings.storage.loginRequired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("settings.storage.readmePrefetch.enabled", isOn: $settings.readmePrefetchEnabled)
                    .disabled(shouldDisableStorageActions)

                ReadmePrefetchSettingsStatusView(
                    service: dependencies.readmePrefetchService,
                    isEnabled: settings.readmePrefetchEnabled,
                    nextRunAt: dependencies.readmePrefetchPoller.nextRunAt
                ) {
                    Button("settings.storage.readmePrefetch.runNow") {
                        Task {
                            await triggerReadmePrefetch(using: cleaner)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(shouldDisableReadmePrefetchRunNow)
                }

                Text("settings.storage.readmePrefetch.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader(
                    "settings.storage.readmePrefetch.section",
                    systemImage: "doc.text.magnifyingglass",
                    style: .prominent
                )
            }

            Section {
                Picker("settings.storage.chatHistoryBackend.title", selection: $settings.chatHistoryStorageKind) {
                    ForEach(ChatHistoryStorageKind.allCases) { kind in
                        Text(LocalizedStringKey(kind.displayNameKey))
                            .tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .disabled(shouldDisableStorageActions)

                Text("settings.storage.chatHistoryBackend.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.chatHistoryStorageKind != chatHistoryStore.storageKind {
                    Text("settings.storage.chatHistoryBackend.restartRequired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(
                    "settings.storage.chatHistoryBackend.section",
                    systemImage: "bubble.left.and.bubble.right",
                    style: .prominent
                )
            }

            Section {
                StorageCacheUsageOverviewCard(snapshot: cacheUsageOverviewSnapshot)

                usageRow(
                    titleKey: "settings.storage.readme",
                    usageText: readmeUsageText,
                    isEmpty: stats.readmeCount == 0,
                    action: .readme,
                    revealItem: .readmeDatabase
                )
                usageRow(
                    titleKey: "settings.storage.image",
                    usageText: Int64(stats.imageDiskBytes).formattedByteSize,
                    isEmpty: stats.imageDiskBytes == 0,
                    action: .image,
                    revealItem: .imageCache
                )
                usageRow(
                    titleKey: "settings.storage.archive",
                    usageText: archiveUsageText,
                    isEmpty: stats.archiveCount == 0,
                    action: .archive,
                    revealItem: .archives
                )
                usageRow(
                    titleKey: "settings.storage.translation",
                    usageText: translationUsageText,
                    isEmpty: translationCache.itemCount == 0,
                    action: .translation,
                    helpKey: "settings.storage.translation.help",
                    revealItem: .translation
                )
                usageRow(
                    titleKey: "settings.storage.anySearch",
                    usageText: externalSearchUsageText,
                    isEmpty: externalSearchCache.itemCount == 0,
                    action: .anySearch,
                    helpKey: "settings.storage.anySearch.help",
                    revealItem: .externalSearch
                )
                usageRow(
                    titleKey: "settings.storage.wiki",
                    usageText: wikiUsageText,
                    isEmpty: wikiCache.itemCount == 0,
                    action: .wiki,
                    helpKey: "settings.storage.wiki.help",
                    revealItem: .wiki
                )
                usageRow(
                    titleKey: "settings.storage.issueTimeline",
                    usageText: issueTimelineUsageText,
                    isEmpty: issueTimelineCache.itemCount == 0,
                    action: .issueTimeline,
                    helpKey: "settings.storage.issueTimeline.help",
                    revealItem: .issueTimeline
                )
                usageRow(
                    titleKey: "settings.storage.issueCommentDraft",
                    usageText: issueCommentDraftUsageText,
                    isEmpty: issueCommentDraftCache.itemCount == 0,
                    action: .issueCommentDraft,
                    helpKey: "settings.storage.issueCommentDraft.help",
                    revealItem: .issueCommentDraft
                )
                usageRow(
                    titleKey: "settings.storage.recommendation",
                    usageText: recommendationUsageText,
                    isEmpty: recommendationCache.itemCount == 0,
                    action: .recommendation,
                    helpKey: "settings.storage.recommendation.help",
                    revealItem: .recommendation
                )
                usageRow(
                    titleKey: "settings.storage.chatHistory",
                    usageText: chatHistoryUsageText,
                    isEmpty: chatHistoryStore.sessionCount == 0,
                    action: .chatHistory,
                    helpKey: "settings.storage.chatHistory.help",
                    revealItem: .repoAIChatHistory
                )
                usageRow(
                    titleKey: "settings.storage.ragIndex",
                    usageText: ragIndexBytes.formattedByteSize,
                    isEmpty: ragIndexBytes == 0,
                    action: .ragIndex,
                    helpKey: "settings.storage.ragIndex.help",
                    revealItem: .ragDatabase
                )
                usageRow(
                    titleKey: "settings.storage.ragHistory",
                    usageText: ragHistoryUsageText,
                    isEmpty: ragConversationStats.conversationCount == 0,
                    action: .ragHistory,
                    helpKey: "settings.storage.ragHistory.help",
                    revealItem: .ragDatabase
                )
                usageRow(
                    titleKey: "settings.storage.aiContext",
                    usageText: aiContextUsageText,
                    isEmpty: aiContextStorage.projectCount == 0,
                    action: .aiContext,
                    revealItem: .aiContext
                )
                usageRow(
                    titleKey: "settings.storage.codeFlow",
                    usageText: codeFlowUsageText,
                    isEmpty: codeFlowStorage.projectCount == 0,
                    action: .codeFlow,
                    revealItem: .codeFlow
                )
                usageRow(
                    titleKey: "settings.storage.codebaseMemory",
                    usageText: codebaseMemoryUsageText,
                    isEmpty: codebaseMemoryStorage.projectCount == 0,
                    action: .codebaseMemory,
                    revealItem: .codebaseMemory
                )
            } header: {
                SettingsSectionHeader(
                    "settings.storage.cacheUsage",
                    systemImage: "internaldrive",
                    style: .prominent
                )
            }

            // Undo Star 历史保留设置（2026-07-05）
            Section {
                UndoStarRetentionSlider(retentionDays: $settings.undoStarRetentionDays)
            } header: {
                SettingsSectionHeader(
                    "activity.category.undoStar",
                    systemImage: "arrow.uturn.backward.circle",
                    style: .prominent
                )
            }

            Section {
                dangerActionBlock(
                    descriptionKey: "settings.storage.clearAll.description",
                    buttonTint: Color(nsColor: .systemYellow),
                    buttonForeground: .black,
                    isDisabled: shouldDisableStorageActions || isWorking || isAllCachesEmpty
                ) {
                    Button {
                        isShowingClearAllCachesSheet = true
                    } label: {
                        Label("settings.storage.clearAll", systemImage: "exclamationmark.triangle.fill")
                    }
                }

                dangerActionBlock(
                    descriptionKey: "settings.storage.resetAll.description",
                    buttonTint: .red,
                    buttonForeground: .white,
                    isDisabled: isWorking || isResettingAllData || currentResetTarget == nil
                ) {
                    Button(role: .destructive) {
                        resetTarget = currentResetTarget
                    } label: {
                        Label("settings.storage.resetAll", systemImage: "trash")
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.storage.dangerZone",
                    systemImage: "exclamationmark.triangle.fill",
                    style: .prominent
                )
            }

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
        .task(id: isLoggedIn) {
            guard isLoggedIn else {
                stats = .empty
                return
            }
            await refreshCacheStatistics(using: cleaner)
        }
        .onChange(of: dependencies.readmePrefetchService.processed) { _, _ in
            scheduleCacheStatisticsRefresh(using: cleaner)
        }
        .onChange(of: dependencies.readmePrefetchService.status) { _, _ in
            scheduleCacheStatisticsRefresh(using: cleaner)
        }
        .onDisappear {
            statsRefreshTask?.cancel()
            statsRefreshTask = nil
        }
        .task(id: isLoggedIn) {
            guard isLoggedIn else { return }
            // Tab 出现时强制重扫描全部产物 / 缓存目录，让用户刚生成的内容立即可见。
            aiContextStorage.reload()
            codeFlowStorage.reload()
            codebaseMemoryStorage.reload()
            translationCache.reload()
            externalSearchCache.reload()
            issueTimelineCache.reload()
            issueCommentDraftCache.reload()
            chatHistoryStore.reload()
            await refreshRAGStorageStatistics()
        }
        .alert(
            pendingAction?.confirmTitle(locale: locale) ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            presenting: pendingAction
        ) { action in
            Button("general.clear", role: .destructive) {
                Task { await perform(action: action, using: cleaner) }
            }
            Button("general.cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(verbatim: action.confirmMessage(locale: locale))
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
        .sheet(isPresented: $isShowingClearAllCachesSheet) {
            StorageClearAllCachesSheet(
                isClearing: isWorking,
                onCancel: {
                    isShowingClearAllCachesSheet = false
                },
                onConfirm: {
                    Task {
                        await perform(action: .all, using: cleaner)
                        isShowingClearAllCachesSheet = false
                    }
                }
            )
            .appLocaleEnvironment()
        }
        .sheet(item: $resetTarget) { target in
            StorageResetAllDataSheet(
                target: target,
                isResetting: isResettingAllData,
                didComplete: resetDidComplete,
                onCancel: {
                    resetTarget = nil
                    resetDidComplete = false
                },
                onConfirm: {
                    Task { await performResetAllData(target: target) }
                },
                onQuit: {
                    quitAfterResetCompletion()
                },
                onRestart: {
                    restartAfterResetCompletion()
                }
            )
            .appLocaleEnvironment()
        }
    }

    // MARK: - 行视图 helpers

    /// 危险区操作块：说明在左，按钮右对齐。黄色缓存删除与红色本地数据重置共用布局，
    /// 避免两个高风险入口在同一分组里产生不同的视觉节奏。
    private func dangerActionBlock<Action: View>(
        descriptionKey: LocalizedStringKey,
        buttonTint: Color,
        buttonForeground: Color,
        isDisabled: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(descriptionKey)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                action()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(buttonTint)
                    .foregroundStyle(buttonForeground)
                    .disabled(isDisabled)
            }
        }
    }

    /// 标准用量行：`<标题>     <用量>  [文件夹]  [清理]`。
    /// `isEmpty == true` 时清理按钮 disabled（避免空缓存触发"删空目录"等无意义操作）。
    /// 文件夹按钮始终可用（已登录且非清理中），便于用户定位磁盘路径。
    private func usageRow(
        titleKey: LocalizedStringKey,
        usageText: String,
        isEmpty: Bool,
        action: PendingAction,
        helpKey: LocalizedStringKey? = nil,
        revealItem: CacheDirectoryLocator.Item? = nil
    ) -> some View {
        let row = LabeledContent {
            HStack(spacing: 8) {
                Text(usageText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let revealItem {
                    revealInFinderButton(item: revealItem)
                }
                Button("settings.storage.action.clear") {
                    pendingAction = action
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(shouldDisableStorageActions || isWorking || isEmpty)
            }
        } label: {
            Text(titleKey)
        }

        return Group {
            if let helpKey {
                row.help(Text(helpKey))
            } else {
                row
            }
        }
    }

    /// 缓存用量行统一的 Finder 打开按钮。
    private func revealInFinderButton(item: CacheDirectoryLocator.Item) -> some View {
        Button {
            revealCacheLocation(item)
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("settings.storage.revealInFinder"))
        .accessibilityLabel(Text("settings.storage.revealInFinder"))
        .disabled(shouldDisableStorageActions || isWorking)
    }

    /// 按当前登录用户与**运行中**的仓库 AI 对话历史后端，在 Finder 中定位缓存目录。
    private func revealCacheLocation(_ item: CacheDirectoryLocator.Item) {
        let locator = CacheDirectoryLocator(
            userID: authSession.state.user?.id,
            chatHistoryStorageKind: chatHistoryStore.storageKind
        )
        do {
            try locator.reveal(item)
        } catch {
            storageActionError = error.localizedDescription
        }
    }

    // MARK: - 清理执行

    /// 执行清理 + 重新加载统计。UI state 全程在 main actor。
    ///
    /// 失败处理：每个 throws 调用独立 catch，互不阻断。多类同时失败时只显示**第一个**
    /// 错误（避免连弹多个 alert）；这是设置页"清理"动作可接受的简化——失败极少，
    /// 用户重试即可，没必要做错误聚合。
    @MainActor
    private func perform(action: PendingAction, using cleaner: CacheCleaner) async {
        guard isLoggedIn else { return }
        isWorking = true
        switch action {
        case .readme:
            await cleaner.clearReadmes()
        case .image:
            await cleaner.clearImageCache()
        case .archive:
            cleaner.clearArchives()
        case .translation:
            do { try await translationCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .anySearch:
            do { try await externalSearchCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
            await RAGRemoteContextMemoryCache.shared.removeAll()
        case .wiki:
            do { try wikiCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .issueTimeline:
            do { try issueTimelineCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .issueCommentDraft:
            do { try issueCommentDraftCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .recommendation:
            do { try await recommendationCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .chatHistory:
            do { try chatHistoryStore.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
        case .ragIndex:
            do { try await dependencies.ragChunkRepository.deleteAll() }
            catch { storageActionError = error.localizedDescription }
        case .ragHistory:
            do { try await dependencies.ragConversationStore.deleteAll() }
            catch { storageActionError = error.localizedDescription }
        case .aiContext:
            do { try aiContextStorage.deleteAllProjects() }
            catch { storageActionError = error.localizedDescription }
        case .codeFlow:
            do { try codeFlowStorage.deleteAllProjects() }
            catch { storageActionError = error.localizedDescription }
        case .codebaseMemory:
            do { try codebaseMemoryStorage.deleteAllProjects() }
            catch { storageActionError = error.localizedDescription }
        case .all:
            await cleaner.clearAll()
            // 4 处独立 try：互不阻断；首个失败的 description 留在 storageActionError，
            // 后续若再失败则丢弃（避免连弹多个 alert，dong4j 反馈"重试一遍即可"）。
            do { try await translationCache.deleteEverything() }
            catch { storageActionError = error.localizedDescription }
            do { try await externalSearchCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            await RAGRemoteContextMemoryCache.shared.removeAll()
            do { try wikiCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try issueTimelineCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try issueCommentDraftCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try await recommendationCache.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try chatHistoryStore.deleteEverything() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try await dependencies.ragChunkRepository.deleteAll() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try await dependencies.ragConversationStore.deleteAll() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try aiContextStorage.deleteAllProjects() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try codeFlowStorage.deleteAllProjects() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
            do { try codebaseMemoryStorage.deleteAllProjects() }
            catch {
                if storageActionError == nil { storageActionError = error.localizedDescription }
            }
        }
        await refreshCacheStatistics(using: cleaner)
        await refreshRAGStorageStatistics()
        isWorking = false
        pendingAction = nil
    }

    private var ragHistoryUsageText: String {
        let size = ragConversationStats.totalBytes.formattedByteSize
        return String(
            format: String.l10n("settings.storage.ragHistory.usageFormat"),
            ragConversationStats.conversationCount,
            size
        )
    }

    @MainActor
    private func refreshRAGStorageStatistics() async {
        ragIndexBytes = (try? await dependencies.ragChunkRepository.totalBytes()) ?? 0
        ragConversationStats = (try? await dependencies.ragConversationStore.statistics()) ?? .empty
    }

    /// 执行“本机恢复出厂”。真正的删除逻辑在 AppDependencies / AppDataResetService；
    /// Settings 页只负责收集用户确认并展示完成状态，避免 UI 层直接拼路径删文件。
    @MainActor
    private func performResetAllData(target: AppDataResetTarget) async {
        guard isLoggedIn else {
            storageActionError = AppDataResetError.notAuthenticated.localizedDescription
            return
        }
        isResettingAllData = true
        do {
            try await dependencies.resetLocalAppData(for: target)
            stats = .empty
            translationCache.reload()
            externalSearchCache.reload()
            wikiCache.reload()
            issueTimelineCache.reload()
            issueCommentDraftCache.reload()
            await recommendationCache.reload()
            chatHistoryStore.reload()
            aiContextStorage.reload()
            codeFlowStorage.reload()
            codebaseMemoryStorage.reload()
            resetDidComplete = true
        } catch {
            storageActionError = error.localizedDescription
        }
        isResettingAllData = false
    }

    /// reset 完成态需要先让 SwiftUI sheet 正常退场，再在下一轮 main queue 发退出请求。
    ///
    /// 直接在 sheet button action 里 `terminate` 容易被当前 modal 事务吞掉；把关闭
    /// sheet 与 AppKit 生命周期动作拆成两步，用户点击后才会稳定退出 / 重启。
    private func quitAfterResetCompletion() {
        dismissResetCompletionSheet()
        DispatchQueue.main.async {
            StorageResetAppLifecycle.quit()
        }
    }

    private func restartAfterResetCompletion() {
        dismissResetCompletionSheet()
        DispatchQueue.main.async {
            StorageResetAppLifecycle.restart()
        }
    }

    private func dismissResetCompletionSheet() {
        resetTarget = nil
        resetDidComplete = false
    }

    /// 立即刷新缓存用量。预拉后台任务会持续写入 readmes/readme_contents，设置页不能只在
    /// 打开时读一次，否则用户会看到“预拉进行中但用量不变”的割裂状态。
    private func refreshCacheStatistics(using cleaner: CacheCleaner) async {
        stats = await cleaner.loadStatistics()
    }

    /// README 预拉每个 repo 完成都会推进进度；这里做轻量 debounce，避免设置页为每个
    /// 进度 tick 都立即跑完整缓存统计，同时保证用户不需要关闭重开设置页才能看到数量变化。
    private func scheduleCacheStatisticsRefresh(using cleaner: CacheCleaner) {
        guard isLoggedIn else { return }
        statsRefreshTask?.cancel()
        statsRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let snapshot = await cleaner.loadStatistics()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                stats = snapshot
            }
        }
    }

    /// 手动触发一次 README 补齐，只处理 README，不触发 Repo Health 首次计算。
    ///
    /// 这里走 `InitialRepoWarmupCoordinator.runReadmeNow`，而不是直接调用 poller：
    /// 设置页按钮的产品语义是“立即补齐 README”，可以用于首次 warmup 前手动提前补，
    /// 也可以用于用户清理 README 缓存后的普通补漏，但不应该顺手启动 Health 计算。
    @MainActor
    private func triggerReadmePrefetch(using cleaner: CacheCleaner) async {
        guard !shouldDisableReadmePrefetchRunNow else { return }
        guard let userID = authSession.state.user?.id else { return }
        isTriggeringReadmePrefetch = true
        defer { isTriggeringReadmePrefetch = false }
        await dependencies.initialWarmupCoordinator.runReadmeNow(userID: userID)
        await refreshCacheStatistics(using: cleaner)
    }

    // MARK: - 用量文案

    /// Cache Usage 顶部总览：把十几种明细合并成 4 大类占比。
    private var cacheUsageOverviewSnapshot: StorageCacheUsageOverviewSnapshot {
        .make(
            readmeBytes: stats.readmeBytes,
            imageBytes: Int64(stats.imageDiskBytes),
            archiveBytes: stats.archiveBytes,
            translationBytes: translationCache.totalBytes,
            externalSearchBytes: externalSearchCache.totalBytes,
            wikiBytes: wikiCache.totalBytes,
            issueTimelineBytes: issueTimelineCache.totalBytes,
            issueCommentDraftBytes: issueCommentDraftCache.totalBytes,
            recommendationBytes: recommendationCache.totalBytes,
            chatHistoryBytes: chatHistoryStore.totalBytes,
            ragIndexBytes: ragIndexBytes,
            ragHistoryBytes: ragConversationStats.totalBytes,
            aiContextBytes: aiContextStorage.totalBytes,
            codeFlowBytes: codeFlowStorage.totalBytes,
            codebaseMemoryBytes: codebaseMemoryStorage.totalBytes
        )
    }

    private var readmeUsageText: String {
        String(
            format: String.l10n("settings.storage.readmeUsageFormat"),
            stats.readmeCount,
            stats.readmeBytes.formattedByteSize
        )
    }

    private var archiveUsageText: String {
        String(
            format: String.l10n("settings.storage.archiveUsageFormat"),
            stats.archiveCount,
            stats.archiveBytes.formattedByteSize
        )
    }

    /// 翻译磁盘缓存用量行文案：`X 项 · YY KB`。空缓存显示"未生成"。
    private var translationUsageText: String {
        if translationCache.itemCount == 0 {
            return String.l10n("settings.storage.translation.empty")
        }
        return String(
            format: String.l10n("settings.storage.translationUsageFormat"),
            translationCache.itemCount,
            translationCache.totalBytes.formattedByteSize
        )
    }

    /// External Search 磁盘缓存用量行文案（global + AI External Context 合计）。
    private var externalSearchUsageText: String {
        if externalSearchCache.itemCount == 0 {
            return String.l10n("settings.storage.anySearch.empty")
        }
        return String(
            format: String.l10n("settings.storage.anySearchUsageFormat"),
            externalSearchCache.itemCount,
            externalSearchCache.totalBytes.formattedByteSize
        )
    }

    /// Issue 事件流磁盘缓存用量。空态 / 计数格式复用翻译缓存那套通用文案。
    private var issueTimelineUsageText: String {
        if issueTimelineCache.itemCount == 0 {
            return String.l10n("settings.storage.translation.empty")
        }
        return String(
            format: String.l10n("settings.storage.translationUsageFormat"),
            issueTimelineCache.itemCount,
            issueTimelineCache.totalBytes.formattedByteSize
        )
    }

    private var issueCommentDraftUsageText: String {
        if issueCommentDraftCache.itemCount == 0 {
            return String.l10n("settings.storage.translation.empty")
        }
        return String(
            format: String.l10n("settings.storage.translationUsageFormat"),
            issueCommentDraftCache.itemCount,
            issueCommentDraftCache.totalBytes.formattedByteSize
        )
    }

    /// Wiki 探测结果磁盘缓存用量行文案。数据极小（每个 repo < 1KB），格式与
    /// translation / anySearch 同款（`X 项 · YY KB`）保持视觉一致。
    private var wikiUsageText: String {
        if wikiCache.itemCount == 0 {
            return String.l10n("settings.storage.wiki.empty")
        }
        return String(
            format: String.l10n("settings.storage.wikiUsageFormat"),
            wikiCache.itemCount,
            wikiCache.totalBytes.formattedByteSize
        )
    }

    /// 推荐结果磁盘缓存用量行文案（与 wiki / translation / anySearch 同款视觉）。
    private var recommendationUsageText: String {
        if recommendationCache.itemCount == 0 {
            return String.l10n("settings.storage.recommendation.empty")
        }
        return String(
            format: String.l10n("settings.storage.recommendationUsageFormat"),
            recommendationCache.itemCount,
            recommendationCache.totalBytes.formattedByteSize
        )
    }

    /// AI 对话历史用量行文案：`X 场对话 · YY 个仓库 · ZZ KB`。空显示"未生成"。
    private var chatHistoryUsageText: String {
        if chatHistoryStore.sessionCount == 0 {
            return String.l10n("settings.storage.chatHistory.empty")
        }
        return String(
            format: String.l10n("settings.storage.chatHistoryUsageFormat"),
            chatHistoryStore.sessionCount,
            chatHistoryStore.repoCount,
            chatHistoryStore.totalBytes.formattedByteSize
        )
    }

    /// AI 代码上下文用量：`X 项 · YY KB`。空显示"未生成"。
    /// HOM-203：直接读 summary 的 projectCount / totalBytes，避免遍历 projects 数组。
    private var aiContextUsageText: String {
        if aiContextStorage.projectCount == 0 {
            return String.l10n("settings.storage.aiContext.empty")
        }
        return String(
            format: String.l10n("settings.storage.aiContextUsageFormat"),
            aiContextStorage.projectCount,
            aiContextStorage.totalBytes.formattedByteSize
        )
    }

    /// CodeFlow 用量：同 AI 上下文格式。
    private var codeFlowUsageText: String {
        if codeFlowStorage.projectCount == 0 {
            return String.l10n("settings.storage.codeFlow.empty")
        }
        return String(
            format: String.l10n("settings.storage.codeFlowUsageFormat"),
            codeFlowStorage.projectCount,
            codeFlowStorage.totalBytes.formattedByteSize
        )
    }

    /// CodebaseMemory 用量：同 CodeFlow 格式。
    private var codebaseMemoryUsageText: String {
        if codebaseMemoryStorage.projectCount == 0 {
            return String.l10n("settings.storage.codeFlow.empty")
        }
        return String(
            format: String.l10n("settings.storage.codeFlowUsageFormat"),
            codebaseMemoryStorage.projectCount,
            codebaseMemoryStorage.totalBytes.formattedByteSize
        )
    }
}

/// Storage 页 README 预拉状态行。
///
/// 这里复用全局 `ReadmePrefetchService` 的可观察状态，而不是在设置页重新查库。原因是预拉
/// 是后台调度行为，用户最关心的是“当前是否在跑 / 是否冷却 / 上轮结果”，这些都已经由
/// service 聚合；设置页只做只读展示，避免打开设置时制造额外数据库负载。
private struct ReadmePrefetchSettingsStatusView<Action: View>: View {
    @Environment(\.locale) private var locale

    let service: ReadmePrefetchService
    let isEnabled: Bool
    let nextRunAt: Date?
    @ViewBuilder let action: () -> Action

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("settings.storage.readmePrefetch.status")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    if service.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if isEnabled {
                        Text(statusText(now: context.date))
                            .foregroundStyle(statusTint(now: context.date))
                            .multilineTextAlignment(.trailing)
                    }
                    action()
                }
            }
            .font(.caption)
        }
    }

    private func statusText(now: Date) -> String {
        guard isEnabled else {
            return String.l10n("toolbar.status.readmePrefetch.disabled")
        }

        if let nextRunAt, nextRunAt > now, !service.isRunning {
            return String(
                format: String.l10n("settings.storage.readmePrefetch.nextRunFormat"),
                countdownDuration(until: nextRunAt, now: now)
            )
        }

        switch service.status {
        case .running:
            return String(
                format: String.l10n("toolbar.status.readmePrefetch.progressFormat"),
                service.processed,
                service.total,
                service.failures
            )
        case .coolingDown(let until):
            return String(
                format: String.l10n("toolbar.status.readmePrefetch.coolingDownFormat"),
                RelativeTimeText.futureDeadline(until, locale: locale)
            )
        case .waitingForRetry:
            return String.l10n("settings.storage.readmePrefetch.retrying")
        case .completed:
            return String(
                format: String.l10n("toolbar.status.readmePrefetch.completedFormat"),
                service.htmlUpdated,
                service.markdownUpdated,
                service.notFound,
                service.failures
            )
        case .allPrefetched(let total):
            return String(
                format: String.l10n("settings.storage.readmePrefetch.allPrefetchedFormat"),
                total
            )
        case .noStarredRepos:
            return String.l10n("settings.storage.readmePrefetch.noStarredRepos")
        case .idle:
            if let lastRunAt = service.lastRunAt {
                return String(
                    format: String.l10n("toolbar.status.readmePrefetch.lastFormat"),
                    RelativeTimeText.pastEvent(lastRunAt, locale: locale)
                )
            }
            return String.l10n("toolbar.status.readmePrefetch.waiting")
        case .disabled:
            return String.l10n("toolbar.status.readmePrefetch.disabled")
        }
    }

    private func statusTint(now: Date) -> Color {
        if !isEnabled { return .secondary }
        if let nextRunAt, nextRunAt > now, !service.isRunning { return .accentColor }
        if service.failures > 0 { return .orange }
        switch service.status {
        case .running, .coolingDown:
            return .accentColor
        case .waitingForRetry:
            return .orange
        case .completed:
            return .green
        case .allPrefetched:
            return .green
        case .noStarredRepos:
            return .secondary
        case .idle, .disabled:
            return .secondary
        }
    }

    private func countdownDuration(until date: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(date.timeIntervalSince(now))))
        if seconds >= 3_600 {
            return String(
                format: String.l10n("settings.storage.readmePrefetch.countdown.hoursMinutes"),
                seconds / 3_600,
                (seconds % 3_600) / 60
            )
        }
        if seconds >= 60 {
            return String(
                format: String.l10n("settings.storage.readmePrefetch.countdown.minutesSeconds"),
                seconds / 60,
                seconds % 60
            )
        }
        return String(
            format: String.l10n("settings.storage.readmePrefetch.countdown.seconds"),
            seconds
        )
    }
}

/// Storage 页“删除全部缓存”的确认 sheet。
///
/// 这个操作会删除可重建的文件型缓存和生成物，但不会碰本地 SQLite 用户数据或凭据。
/// 独立成 sheet 是为了让“全部缓存”与危险区语义一致，同时区别于真正的本地数据重置。
private struct StorageClearAllCachesSheet: View {
    let isClearing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            warningContent
            footer
        }
        .padding(24)
        .frame(width: 480)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Color(nsColor: .systemYellow))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text("settings.storage.clearAll.sheet.title")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("settings.storage.clearAll.sheet.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.storage.clearAll.scope.title")
                    .font(.headline)
                    .foregroundStyle(.primary)

                ForEach(clearAllCacheScopeItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "smallcircle.filled.circle")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("settings.storage.clearAll.sheet.note")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("general.cancel", role: .cancel) {
                onCancel()
            }
            .disabled(isClearing)

            Button {
                onConfirm()
            } label: {
                if isClearing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.storage.clearAll.clearing")
                    }
                } else {
                    Text("settings.storage.clearAll.confirmAction")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: .systemYellow))
            .foregroundStyle(.black)
            .disabled(isClearing)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var clearAllCacheScopeItems: [String] {
        [
            "settings.storage.clearAll.scope.readme",
            "settings.storage.clearAll.scope.media",
            "settings.storage.clearAll.scope.searchWiki",
            "settings.storage.clearAll.scope.generated",
            "settings.storage.clearAll.scope.localDataSafe"
        ]
    }
}

/// Storage 页“清空所有数据”的二次确认 sheet。
///
/// 这个视图只负责把破坏性操作讲清楚并收集 GitHub username 确认；
/// 真正删除由 AppDataResetService 执行，避免 UI 层掌握本机路径删除细节。
private struct StorageResetAllDataSheet: View {
    let target: AppDataResetTarget
    let isResetting: Bool
    let didComplete: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onQuit: () -> Void
    let onRestart: () -> Void

    @State private var confirmationText = ""
    @FocusState private var isInputFocused: Bool

    private var normalizedInput: String {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var normalizedLogin: String {
        target.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canConfirm: Bool {
        !didComplete && !isResetting && normalizedInput == normalizedLogin
    }

    private var usernamePrompt: Text {
        Text("settings.storage.resetAll.usernamePromptPrefix")
            .foregroundStyle(.secondary)
        + Text(verbatim: target.login)
            .fontWeight(.semibold)
            .foregroundStyle(Color(nsColor: .systemOrange))
        + Text("settings.storage.resetAll.usernamePromptSuffix")
            .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if didComplete {
                completionContent
            } else {
                warningContent
            }

            footer
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            isInputFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: didComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(didComplete ? .green : .red)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(didComplete ? "settings.storage.resetAll.completed.title" : "settings.storage.resetAll.sheet.title")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(didComplete ? "settings.storage.resetAll.completed.message" : "settings.storage.resetAll.sheet.subtitle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.storage.resetAll.scope.title")
                    .font(.headline)
                    .foregroundStyle(.primary)

                ForEach(resetScopeItems, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "smallcircle.filled.circle")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item))
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                usernamePrompt
                    .font(.callout)

                TextField("settings.storage.resetAll.usernamePlaceholder", text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .disabled(isResetting)
            }
        }
    }

    private var completionContent: some View {
        Text("settings.storage.resetAll.completed.detail")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if didComplete {
                Button("settings.storage.resetAll.quit") {
                    onQuit()
                }

                Button("settings.storage.resetAll.restart") {
                    onRestart()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("general.cancel", role: .cancel) {
                    onCancel()
                }
                .disabled(isResetting)

                Button(role: .destructive) {
                    onConfirm()
                } label: {
                    if isResetting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("settings.storage.resetAll.resetting")
                        }
                    } else {
                        Text("settings.storage.resetAll.confirm")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var resetScopeItems: [String] {
        [
            "settings.storage.resetAll.scope.database",
            "settings.storage.resetAll.scope.caches",
            "settings.storage.resetAll.scope.generated",
            "settings.storage.resetAll.scope.settings",
            "settings.storage.resetAll.scope.credentials",
            "settings.storage.resetAll.scope.remoteSafe"
        ]
    }
}

/// Storage reset 完成后的 AppKit 生命周期桥接。
///
/// SwiftUI 只表达用户意图；退出 / 重启是应用级 imperative 行为，集中在这个小 helper
/// 里，避免 sheet 视图直接散落 `NSWorkspace` / `Process` 细节。
@MainActor
private enum StorageResetAppLifecycle {
    static func quit() {
        NSApplication.shared.terminate(nil)
    }

    static func restart() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                let message = error.localizedDescription
                Task { @MainActor in
                    AppLog.general.error("Restart Starcat failed via NSWorkspace: \(message, privacy: .public)")
                    restartWithOpenCommand(appURL: appURL)
                    quit()
                }
                return
            }

            Task { @MainActor in
                quit()
            }
        }
    }

    /// `NSWorkspace` 启动失败时兜底调用系统 `open -n`。
    ///
    /// 这条路径只负责尽量拉起新实例；无论兜底是否成功，当前实例都会退出，避免 reset 后
    /// 用户继续停留在已清空本机状态的进程里操作旧 UI。
    private static func restartWithOpenCommand(appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]

        do {
            try process.run()
        } catch {
            AppLog.general.error("Restart Starcat fallback failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
