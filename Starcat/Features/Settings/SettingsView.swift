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
// 2026-06-13 Y3/Y5：设置内的跨分类操作需要切换到目标页面并定位具体区块。
// SettingsView 用 @State 自管 selectedTab，没有外部入口可以直接改它的值；
// 项目惯例（见 ReadmeViewModel /
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
    /// 跨 Settings 分类跳转。字符串保留旧入口兼容；新页面由 `settingsLocation(for:)`
    /// 统一映射，发起方不需要依赖私有的 `SettingsTab`。
    static let starcatJumpToSettingsTab: Notification.Name = .init("starcat.settings.jumpToTab")
    /// SettingsView 切到代码与本地工具后，通知对应页面定位代码上下文。
    static let starcatJumpToAIRepoContextSection: Notification.Name = .init(
        "starcat.settings.jumpToAIRepoContextSection"
    )
    /// 知识库索引入口需要直达「模型配置 → 向量化」，不能只把用户丢在 AI Tab 顶部。
    static let starcatJumpToAIEmbeddingSection: Notification.Name = .init(
        "starcat.settings.jumpToAIEmbeddingSection"
    )
    /// 搜索入口直达「搜索与上下文 → AI 索引」，避免先落到联网搜索再让用户查找。
    static let starcatJumpToAIIndexSection: Notification.Name = .init(
        "starcat.settings.jumpToAIIndexSection"
    )
    /// 检索页与向量模型页共用的知识库索引管理定位事件。
    static let starcatJumpToKnowledgeIndexSection: Notification.Name = .init(
        "starcat.settings.jumpToKnowledgeIndexSection"
    )
    /// 工作台入口缺少有效模型时，直达「模型配置 → 对话」。
    static let starcatJumpToAIChatModelSection: Notification.Name = .init(
        "starcat.settings.jumpToAIChatModelSection"
    )
}

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedTab: SettingsTab = .general
    @State private var currentLocation = SettingsLocation(tab: .general)
    @State private var backwardHistory: [SettingsLocation] = []
    @State private var forwardHistory: [SettingsLocation] = []
    @State private var settingsSearchText = ""
    @State private var isRedispatchingSettingsJump = false
    /// 提示词归入推理页；由导航层持有展示状态，首次深链不依赖子视图接收通知的时机。
    @State private var isRAGPromptEditorPresented = false
    @State private var hasMarkedFirstFrame = false
    /// 权限弹框仅解释现有授权请求，不触发登录或重新授权。
    @State private var isShowingGitHubPermissions = false
    /// 快捷键录制失败时只在 General 页就地提示，不修改已保存配置。
    @State private var shortcutValidationError: KeyboardShortcutConfiguration.ValidationError?

    /// 五个可配置应用命令的设置页标识。
    /// 这里只负责冲突矩阵和“恢复默认”级联，不参与菜单动作路由。
    private enum ConfigurableShortcutAction: CaseIterable, Hashable {
        case globalSearch
        case readmeFind
        case refreshCurrentContent
        case knowledgeRAG
        case selectedRepoAI

        var defaultShortcut: KeyboardShortcutConfiguration {
            switch self {
            case .globalSearch:
                return .globalSearchDefault
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
        /// 2026-09-13 从通用页拆出：通知策略（总开关 + 分类订阅）独立成页。
        case notifications
        /// 2026-09-13 从通用页拆出：键盘交互（AI 发送键 + 应用命令键位）独立成页。
        case shortcuts
        case pro
        /// 2026-09-06 新增：权限类配置（OAuth scope、数据贡献）独立成页。
        case privacy
        /// AI 的依赖配置优先于自动化与索引：供应商 / 本地模型 / 任务模型集中在本页。
        case aiModels
        /// README 翻译服务（系统 MT、Google、AI）；默认系统翻译无需额外配置。
        case translation
        /// 消费模型配置的后台能力：自动整理与 GitHub Lists 自动分组。
        case aiAutomation
        /// 本地语义索引与知识库索引统一在搜索与索引配置。
        case aiIndexContext
        /// 外部搜索独立配置，不与本地索引和代码上下文混在同一页。
        case externalSearch
        case mcp
        /// 2026-06-08 新增：第三方 / 自建后端服务的 URL 配置。
        case services
        /// 面向普通用户的浏览器插件与共享本地凭据。
        case browserExtensions
        /// Direct Agent Runtime、CodeFlow 与 CodebaseMemory 等开发者工具。
        case localTools
        /// RAG 按推理与检索分组，提示词在推理页的编辑弹窗内配置。
        case ragInference
        case ragRetrieval
        case storage
        case diagnostics
        /// 实验性功能(Labs):TypeSafe Jev 决策引擎 POC 等未定型能力的统一开关入口,
        /// 与稳定功能隔离,便于后续整体下线。
        case labs

        var id: String { rawValue }

        var titleKeyString: String {
            switch self {
            case .general:      return "settings.general.title"
            case .notifications: return "settings.notifications.title"
            case .shortcuts:    return "settings.general.shortcuts"
            case .pro:          return "settings.navigation.item.proLicense"
            case .privacy:      return "settings.navigation.item.privacyPermissions"
            case .aiModels:     return "settings.models.title"
            case .translation:  return "settings.navigation.item.translation"
            case .aiAutomation: return "settings.automation.title"
            case .aiIndexContext: return "settings.navigation.item.searchIndex"
            case .externalSearch: return "settings.navigation.item.webSearch"
            case .mcp:          return "settings.mcp.title"
            case .services:     return "settings.navigation.item.customServices"
            case .browserExtensions: return "settings.navigation.item.browserExtensions"
            case .localTools:   return "settings.navigation.item.codeAndLocalTools"
            case .ragInference: return "rag.workspace.settings.section.inference"
            case .ragRetrieval: return "rag.workspace.settings.section.retrieval"
            case .storage:      return "settings.navigation.item.dataStorage"
            case .diagnostics:  return "settings.navigation.item.diagnosticsSupport"
            case .labs:         return "settings.navigation.item.labs"
            }
        }

        var titleKey: LocalizedStringKey {
            LocalizedStringKey(titleKeyString)
        }

        var businessIcon: BusinessIcon.Symbol {
            switch self {
            case .general:      return .general
            case .notifications: return .notifications
            case .shortcuts:    return .shortcuts
            case .pro:          return .pro
            case .privacy:      return .privacy
            case .aiModels:     return .models
            case .translation:  return .translation
            case .aiAutomation: return .automation
            case .aiIndexContext: return .aiIndex
            case .externalSearch: return .languages
            case .mcp:          return .mcp
            case .services:     return .services
            case .browserExtensions: return .browserExtensions
            case .localTools:   return .localTools
            case .ragInference: return RAGSettingsSection.inference.businessIcon
            case .ragRetrieval: return RAGSettingsSection.retrieval.businessIcon
            case .storage:      return .storage
            case .diagnostics:  return .diagnostics
            case .labs:         return .labs
            }
        }

        /// RAG 主侧栏条目把 selection 传给共用的设置内容。
        var ragSettingsSection: RAGSettingsSection {
            switch self {
            case .ragInference: return .inference
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
    /// 注意：这才是窗口实际尺寸的单一来源；`StarcatApp` 的 `.defaultSize` 只
    /// 是首次启动且无持久化 frame 时的兜底，必须与这里保持一致。
    private static let contentSize = CGSize(width: 720, height: 720)
    /// SwiftUI 与 AppKit 桥接共用同一组数值，避免视觉建议和硬拖拽边界分叉。
    private static let sidebarWidth: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) =
        (220, 240, 260)

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
        // Window scene 的 defaultSize 负责初始尺寸；内容只填满已分配 bounds，不再把
        // 720×720 作为 intrinsic size 回传给 SwiftUI 窗口控制器。这样菜单 action
        // 不需要先同步测量完整的 NavigationSplitView 才能决定窗口大小。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SettingsWindowSizeLimiter(contentSize: Self.contentSize)
                .frame(width: 0, height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button(action: goBack) {
                        Label("settings.navigation.back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .help(Text("settings.navigation.back"))
                    .disabled(backwardHistory.isEmpty)

                    Button(action: goForward) {
                        Label("settings.navigation.forward", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                    .help(Text("settings.navigation.forward"))
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
        .onChange(of: selectedTab) { _, newValue in
            if newValue != .ragInference {
                isRAGPromptEditorPresented = false
            }
        }
        .onAppear {
            if !hasMarkedFirstFrame {
                hasMarkedFirstFrame = true
                PerformanceTracer.shared.mark(.settingsWindowFirstFrame)
            }
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
            Section("settings.sidebar.group.application") {
                settingsSidebarRow(.general)
                settingsSidebarRow(.notifications)
                settingsSidebarRow(.shortcuts)
            }

            // 账户相关入口独立归类，继续复用原 tab 身份，保留搜索、深链和历史导航。
            Section("settings.sidebar.group.account") {
                settingsSidebarRow(.pro)
                settingsSidebarRow(.privacy)
            }

            Section("settings.navigation.group.ai") {
                settingsSidebarRow(.aiModels)
                settingsSidebarRow(.translation)
                settingsSidebarRow(.aiAutomation)
            }

            // 仅按职责拆分侧栏分组，保留 tab 身份，确保深链、搜索和导航历史仍定位原页面。
            Section("settings.navigation.group.retrieval") {
                settingsSidebarRow(.aiIndexContext)
                settingsSidebarRow(.externalSearch)
            }

            // 提示词属于推理配置，通过页内编辑弹窗进入，不再占用独立侧栏分类。
            Section("RAG") {
                settingsSidebarRow(.ragInference)
                settingsSidebarRow(.ragRetrieval)
            }

            Section("settings.navigation.group.extensionsConnections") {
                settingsSidebarRow(.browserExtensions)
                settingsSidebarRow(.mcp)
                settingsSidebarRow(.localTools)
                settingsSidebarRow(.services)
            }

            Section("settings.navigation.group.support") {
                settingsSidebarRow(.storage)
                settingsSidebarRow(.diagnostics)
                // Labs 放侧栏末尾:实验性入口不与稳定功能混排,下线时删除这一行即可。
                settingsSidebarRow(.labs)
            }
        }
        .listStyle(.sidebar)
        // Apple 要求把默认项移除声明挂在产生它的 Sidebar column 上；挂在 SplitView
        // 根部时 macOS 26 仍可能在窗口重建 Toolbar 后重新注入折叠按钮。
        .toolbar(removing: .sidebarToggle)
        // 系统设置采用稳定的分类栏宽度；拖动只允许在窄幅范围内微调，
        // SwiftUI modifier 负责理想值，AppKit limiter 负责真正限制 divider 拖拽边界。
        .navigationSplitViewColumnWidth(
            min: Self.sidebarWidth.minimum,
            ideal: Self.sidebarWidth.ideal,
            max: Self.sidebarWidth.maximum
        )
        .background {
            SettingsSidebarWidthLimiter(
                minimumThickness: Self.sidebarWidth.minimum,
                maximumThickness: Self.sidebarWidth.maximum
            )
            .frame(width: 0, height: 0)
        }
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
                    Label {
                        Text(LocalizedStringKey(item.titleKey))
                    } icon: {
                        BusinessIcon(item.tab.businessIcon, pointSize: item.tab.businessIcon.isAsset ? 16 : 13)
                    }
                }
            }
        }
    }

    private func settingsSidebarRow(_ tab: SettingsTab) -> some View {
        Label {
            Text(tab.titleKey)
                .lineLimit(1)
                .help(Text(tab.titleKey))
        } icon: {
            // SF 与资产共用原生 Label 图标列；换图不能改变导航行的宽高。
            BusinessIcon(tab.businessIcon, pointSize: tab.businessIcon.isAsset ? 16 : 13)
                .frame(width: 16, height: 16)
        }
        .tag(tab)
    }

    /// 只构造当前页，避免旧版 ZStack 让所有访问过的重型 Form 一直参与布局与刷新。
    @ViewBuilder
    private func settingsPage(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsView()
        case .notifications:
            notificationsTab
        case .shortcuts:
            shortcutsTab
        case .pro:
            ProSettingsTab()
        case .privacy:
            privacyTab
        case .aiModels:
            AISettingsTab(page: .models)
        case .translation:
            TranslationSettingsTab()
        case .aiAutomation:
            AISettingsTab(page: .automation)
        case .aiIndexContext:
            SearchIndexSettingsView()
        case .externalSearch:
            AISettingsTab(page: .externalSearch)
        case .mcp:
            MCPSettingsTab()
        case .services:
            ServicesSettingsTab()
        case .browserExtensions:
            IntegrationSettingsTab(page: .browserExtensions)
        case .localTools:
            IntegrationSettingsTab(page: .localTools)
        case .ragInference, .ragRetrieval:
            RAGWorkspaceSettingsView(
                settings: settings,
                presentation: .embeddedInMainSettings(section: tab.ragSettingsSection),
                isPromptEditorPresented: $isRAGPromptEditorPresented
            )
        case .storage:
            StorageSettingsTab(readmeRepository: dependencies.readmeRepository)
        case .diagnostics:
            DiagnosticsSettingsTab()
        case .labs:
            LabsSettingsTab()
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
            SettingsSearchItem("general.explore", titleKey: "settings.explore.content.title", tab: .general,
                               keywords: ["探索", "周刊", "来源", "分类", "explore", "weekly", "source", "Hacker News", "Linux.do", "Awesome"]),
            SettingsSearchItem("notifications", titleKey: "settings.notifications.title", tab: .notifications,
                               keywords: ["通知", "notification", "提醒"]),
            SettingsSearchItem("shortcuts", titleKey: "settings.general.shortcuts", tab: .shortcuts,
                               keywords: ["快捷键", "keyboard", "shortcut", "键位"]),
            SettingsSearchItem("general.accessibility", titleKey: "settings.general.accessibility", tab: .general,
                               keywords: ["动画", "无障碍", "accessibility", "motion"]),
            SettingsSearchItem("pro", titleKey: "settings.navigation.item.proLicense", tab: .pro,
                               keywords: ["订阅", "授权", "激活", "license", "subscription", "purchase"]),
            SettingsSearchItem("privacy", titleKey: "settings.navigation.item.privacyPermissions", tab: .privacy,
                               keywords: ["隐私", "权限", "OAuth", "数据贡献", "推荐", "privacy"]),
            SettingsSearchItem("privacy.oauthScopes", titleKey: "settings.privacy.github.title", tab: .privacy,
                               keywords: ["OAuth", "scope", "权限", "组织"]),
            SettingsSearchItem("privacy.dataContribution", titleKey: "settings.privacy.data.contribution.title", tab: .privacy,
                               keywords: ["数据贡献", "匿名", "推荐", "隐私"]),
            SettingsSearchItem("privacy.telemetry", titleKey: "settings.privacy.data.telemetry.title", tab: .privacy,
                               keywords: ["遥测", "诊断数据", "telemetry", "privacy"]),
            SettingsSearchItem("privacy.ai", titleKey: "settings.privacy.ai.title", tab: .privacy,
                               keywords: ["AI 隐私", "模型数据", "api key", "privacy"]),
            SettingsSearchItem("ai", titleKey: "settings.models.title", tab: .aiModels,
                               keywords: ["人工智能", "模型", "provider", "model", "api key"]),
            SettingsSearchItem("ai.provider", titleKey: "settings.models.provider.section", tab: .aiModels,
                               keywords: ["服务商", "provider", "api key"]),
            SettingsSearchItem("ai.chat", titleKey: "settings.ai.taskModels.title", tab: .aiModels, target: "ai.chat",
                               keywords: ["对话", "任务模型", "chat", "model"]),
            SettingsSearchItem("ai.prompt", titleKey: "settings.ai.prompt.title", tab: .aiModels,
                               keywords: ["提示词", "prompt", "system", "user"]),
            SettingsSearchItem("ai.embedding", titleKey: "settings.ai.models.embedding.title", tab: .aiModels, target: "ai.embedding",
                               keywords: ["向量模型", "向量化模型", "embedding", "model"]),
            SettingsSearchItem("ai.automation", titleKey: "settings.automation.title", tab: .aiAutomation,
                               keywords: ["自动整理", "仓库分组", "github lists", "automation"]),
            SettingsSearchItem("ai.indexContext", titleKey: "settings.navigation.item.searchIndex", tab: .aiIndexContext,
                               keywords: ["全文索引", "语义搜索", "索引", "index", "search"]),
            SettingsSearchItem("ai.index", titleKey: "settings.searchIndex.repository.title", tab: .aiIndexContext, target: "ai.index",
                               keywords: ["向量", "向量化", "索引", "embedding", "vector"]),
            SettingsSearchItem("ai.knowledgeIndex", titleKey: "settings.searchIndex.knowledge.title", tab: .aiIndexContext, target: "ai.knowledgeIndex",
                               keywords: ["知识库索引", "重建", "knowledge", "rag", "index"]),
            SettingsSearchItem("ai.repoContext", titleKey: "ai.context.settings.title", tab: .localTools, target: "ai.repoContext",
                               keywords: ["代码上下文", "仓库上下文", "context", "token"]),
            SettingsSearchItem("ai.externalSearch", titleKey: "settings.navigation.item.webSearch",
                               tab: .externalSearch, target: "ai.externalSearch",
                               keywords: ["外部搜索", "anysearch", "search api"]),
            SettingsSearchItem("mcp", titleKey: "settings.mcp.title", tab: .mcp,
                               keywords: ["model context protocol", "server", "端口", "隐私"]),
            SettingsSearchItem("services", titleKey: "settings.navigation.item.customServices", tab: .services,
                               keywords: ["自定义服务", "自托管", "trending", "weekly", "api", "endpoint", "状态"]),
            SettingsSearchItem("browserExtensions", titleKey: "settings.navigation.item.browserExtensions", tab: .browserExtensions,
                               keywords: ["浏览器", "chrome", "safari", "extension", "plugin", "本地 api"]),
            SettingsSearchItem("integrations.agentRuntime", titleKey: "settings.integration.agentRuntime.title",
                               tab: .localTools, target: "integrations.agentRuntime",
                               keywords: ["agent runtime", "codex", "deepseek"]),
            SettingsSearchItem("integrations.localAPIKey", titleKey: "settings.integration.localAPIKey.title",
                               tab: .browserExtensions, target: "integrations.localAPIKey",
                               keywords: ["本地 api key", "local api key", "鉴权"]),
            SettingsSearchItem("integrations.browserPlugin", titleKey: "settings.integration.browserPlugin.title",
                               tab: .browserExtensions, target: "integrations.browserPlugin",
                               keywords: ["浏览器", "chrome", "safari", "extension", "plugin"]),
            SettingsSearchItem("localTools", titleKey: "settings.navigation.item.codeAndLocalTools", tab: .localTools,
                               keywords: ["本地工具", "代码上下文", "仓库上下文", "context", "agent runtime", "codeflow", "codebase memory"]),
            SettingsSearchItem("labs", titleKey: "settings.navigation.item.labs", tab: .labs,
                               keywords: ["实验性", "实验室", "labs", "typesafe", "jev", "决策"]),
            SettingsSearchItem("integrations.codebaseMemory", titleKey: "settings.navigation.item.codeAndLocalTools",
                               tab: .localTools, target: "integrations.codebaseMemory",
                               keywords: ["codebase memory", "codebasememory", "代码索引"]),
            SettingsSearchItem("rag.inference", titleKey: "rag.workspace.settings.section.inference", tab: .ragInference,
                               keywords: ["推理", "后端", "inference", "backend", "codex", "claude"]),
            SettingsSearchItem("rag.retrieval", titleKey: "rag.workspace.settings.section.retrieval", tab: .ragRetrieval,
                               keywords: ["检索", "重排", "向量", "自托管", "retrieval", "rerank", "vector", "meilisearch", "qdrant"]),
            SettingsSearchItem("rag.prompts", titleKey: "rag.workspace.settings.section.prompts",
                               tab: .ragInference, target: "rag.prompts",
                               keywords: ["提示词", "模板", "prompt", "system", "user"]),
            SettingsSearchItem("storage", titleKey: "settings.navigation.item.dataStorage", tab: .storage,
                               keywords: ["存储", "缓存", "数据库", "清理", "导出", "storage", "cache", "database"]),
            SettingsSearchItem("diagnostics", titleKey: "settings.navigation.item.diagnosticsSupport", tab: .diagnostics,
                               keywords: ["诊断", "日志", "网络", "diagnostics", "logs", "support"]),
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
        case "notifications":
            return SettingsLocation(tab: .notifications)
        case "shortcuts":
            return SettingsLocation(tab: .shortcuts)
        case "pro":
            return SettingsLocation(tab: .pro)
        case "privacy", "privacy.oauthScopes", "privacy.dataContribution", "privacy.telemetry",
             "privacy.ai", "diagnostics.telemetry", "diagnostics.privacy":
            return SettingsLocation(tab: .privacy)
        case "ai", "ai.models", "ai.prompt":
            return SettingsLocation(tab: .aiModels)
        case "ai.chat", "ai.embedding":
            return SettingsLocation(tab: .aiModels, target: target)
        case "ai.automation":
            return SettingsLocation(tab: .aiAutomation)
        case "ai.searchContext", "ai.indexContext":
            return SettingsLocation(tab: .aiIndexContext)
        case "ai.index", "ai.knowledgeIndex":
            return SettingsLocation(tab: .aiIndexContext, target: target)
        case "ai.repoContext":
            return SettingsLocation(tab: .localTools, target: target)
        case "ai.externalSearch", "integrations.externalSearch":
            return SettingsLocation(tab: .externalSearch, target: target)
        case "translation":
            return SettingsLocation(tab: .translation)
        case "mcp":
            return SettingsLocation(tab: .mcp)
        case "services":
            return SettingsLocation(tab: .services)
        case "integrations", "integrations.localAPIKey", "integrations.browserPlugin":
            return SettingsLocation(tab: .browserExtensions, target: target == "integrations" ? nil : target)
        case "integrations.agentRuntime", "integrations.codebaseMemory":
            return SettingsLocation(tab: .localTools, target: target)
        case "rag", "rag.inference":
            return SettingsLocation(tab: .ragInference)
        case "rag.prompts":
            return SettingsLocation(tab: .ragInference, target: target)
        case "rag.retrieval":
            return SettingsLocation(tab: .ragRetrieval)
        case "storage":
            return SettingsLocation(tab: .storage)
        case "diagnostics":
            return SettingsLocation(tab: .diagnostics)
        case "labs":
            return SettingsLocation(tab: .labs)
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
            case "rag.prompts":
                isRAGPromptEditorPresented = true
            case "ai.chat":
                NotificationCenter.default.post(name: .starcatJumpToAIChatModelSection, object: nil)
            case "ai.embedding":
                NotificationCenter.default.post(name: .starcatJumpToAIEmbeddingSection, object: nil)
            case "ai.index":
                NotificationCenter.default.post(name: .starcatJumpToAIIndexSection, object: nil)
            case "ai.knowledgeIndex":
                NotificationCenter.default.post(name: .starcatJumpToKnowledgeIndexSection, object: nil)
            case "ai.repoContext":
                NotificationCenter.default.post(name: .starcatJumpToAIRepoContextSection, object: nil)
            case "integrations.agentRuntime", "integrations.localAPIKey", "integrations.browserPlugin",
                 "integrations.externalSearch", "ai.externalSearch", "integrations.codebaseMemory":
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

    /// 通知策略独立页（2026-09-13 从通用页拆出）。
    /// 通知只用于「用户离开 App 后需要回来处理」的低频事件；普通状态变化继续留在
    /// toolbar 状态面板，避免把通知中心变成运行日志。
    private var notificationsTab: some View {
        @Bindable var settings = settings

        return Form {
            // 与通用页沿用同一说明卡片结构，表面仍由 grouped Form 提供。
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "bell.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)

                    Divider()
                        .frame(height: 48)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.notifications.title")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("settings.notifications.introduction.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(Text("settings.notifications.introduction.description"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                Toggle("settings.notifications.enabled.title", isOn: $settings.notificationsEnabled)
            } header: {
                SettingsSectionHeader("settings.notifications.system.title", systemImage: "bell")
            }

            // 总开关只影响可操作性，不覆盖各类型偏好；重新开启时保留原选择。
            Section {
                notificationTypeToggle(
                    "settings.notifications.release.title",
                    description: "settings.notifications.release.description",
                    isOn: $settings.releaseNotificationsEnabled
                )
                .disabled(!settings.notificationsEnabled)
                notificationTypeToggle(
                    "settings.notifications.githubInbox.title",
                    description: "settings.notifications.githubInbox.description",
                    isOn: $settings.githubInboxNotificationsEnabled
                )
                .disabled(!settings.notificationsEnabled)
                notificationTypeToggle(
                    "settings.notifications.batchAI.title",
                    description: "settings.notifications.batchAI.description",
                    isOn: $settings.batchAINotificationsEnabled
                )
                .disabled(!settings.notificationsEnabled)
                notificationTypeToggle(
                    "settings.notifications.syncIssues.title",
                    description: "settings.notifications.syncIssues.description",
                    isOn: $settings.syncIssueNotificationsEnabled
                )
                .disabled(!settings.notificationsEnabled)
                notificationTypeToggle(
                    "settings.notifications.mcpIssues.title",
                    description: "settings.notifications.mcpIssues.description",
                    isOn: $settings.mcpIssueNotificationsEnabled
                )
                .disabled(!settings.notificationsEnabled)
            } header: {
                SettingsSectionHeader(
                    "settings.notifications.types.title",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
        }
        .formStyle(.grouped)
    }

    /// 显式按标题与备注的整体高度居中，避免 grouped Form 将开关仅对齐第一行。
    private func notificationTypeToggle(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(description))
        }
    }

    /// 键盘交互独立页（2026-09-13 从通用页拆出）：AI 发送方式 + 五个可配置应用命令键位。
    /// 常规搜索（⇧⌘F）快捷键已随搜索统一进全局搜索一起删除。
    private var shortcutsTab: some View {
        @Bindable var settings = settings

        return Form {
            // 与通用、通知页保持一致，分类说明仍由原生 grouped Section 承载。
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "keyboard")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)

                    Divider()
                        .frame(height: 48)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.general.shortcuts")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("settings.shortcuts.introduction.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(Text("settings.shortcuts.introduction.description"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
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
            } header: {
                SettingsSectionHeader(
                    "settings.shortcuts.application.title",
                    systemImage: "keyboard"
                )
            } footer: {
                Text("settings.general.shortcuts.configuration.description")
                    .lineLimit(2)
                    .help(Text("settings.general.shortcuts.configuration.description"))
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    // 下拉项直接映射既有 Bool，不复制偏好状态，也不受应用快捷键总开关影响。
                    Picker("settings.shortcuts.input.sendMode.title", selection: $settings.aiChatRequiresCommandReturn) {
                        Text("settings.shortcuts.input.sendMode.return").tag(false)
                        Text("settings.shortcuts.input.sendMode.commandReturn").tag(true)
                    }
                    .pickerStyle(.menu)

                    Text(
                        settings.aiChatRequiresCommandReturn
                            ? "settings.general.shortcuts.aiCommandReturn.description.on"
                            : "settings.general.shortcuts.aiCommandReturn.description.off"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text(settings.aiChatRequiresCommandReturn
                                   ? "settings.general.shortcuts.aiCommandReturn.description.on"
                                   : "settings.general.shortcuts.aiCommandReturn.description.off"))
                }
            } header: {
                SettingsSectionHeader("settings.shortcuts.input.title", systemImage: "return")
            }
        }
        .formStyle(.grouped)
    }

    /// 「隐私与权限」统一呈现 OAuth scope、数据贡献、遥测和 AI 数据边界。
    /// 这些配置都回答“应用会访问或发送什么”，不再分散在通用、AI 与诊断页；
    /// 原有绑定和默认值保持不变，仅调整用户寻找它们的路径。
    private var privacyTab: some View {
        @Bindable var settings = settings

        return Form {
            // 沿用通用页的说明卡片，避免在 grouped Form 中额外叠加卡片表面。
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "checkmark.shield")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)

                    Divider()
                        .frame(height: 48)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.navigation.item.privacyPermissions")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("settings.privacy.introduction.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(Text("settings.privacy.introduction.description"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }

            Section {
                LabeledContent {
                    if let login = dependencies.authSession.state.user?.login {
                        Text(verbatim: login)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(login)
                    } else {
                        Text("settings.privacy.github.account.signedOut")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("settings.privacy.github.account.title")
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.privacy.github.scopes.title")
                            .lineLimit(1)
                            .help(Text("settings.privacy.github.scopes.title"))
                        Text("settings.privacy.github.scopes.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(Text("settings.privacy.github.scopes.description"))
                    }

                    Spacer(minLength: 0)

                    Button {
                        isShowingGitHubPermissions = true
                    } label: {
                        Text("settings.privacy.github.scopes.show")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            } header: {
                SettingsSectionHeader("settings.privacy.github.title", systemImage: "lock.shield.fill")
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
                        Text("settings.privacy.data.contribution.title")
                        Text("settings.privacy.data.contribution.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .disabled(dependencies.database.currentUserId == nil)
                .help(Text("settings.general.dataContribution.help"))
                .accessibilityHint(Text("settings.general.dataContribution.help"))

                Toggle(isOn: $settings.telemetryEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.privacy.data.telemetry.title")
                        Text("settings.privacy.data.telemetry.description")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                // 短说明用于扫读，完整的数据白名单与 MetricKit 本地保存边界保留在提示中。
                .help(Text("settings.privacy.data.telemetry.details"))
                .accessibilityHint(Text("settings.privacy.data.telemetry.details"))
            } header: {
                SettingsSectionHeader("settings.privacy.data.title", systemImage: "hand.raised.fill")
            }

            Section {
                Text("settings.privacy.ai.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Text("settings.privacy.ai.description"))
            } header: {
                SettingsSectionHeader("settings.privacy.ai.title", systemImage: "lock.shield")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingGitHubPermissions) {
            GitHubPermissionsSheet(accountLogin: dependencies.authSession.state.user?.login)
                .appLocaleEnvironment()
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

    /// 返回除当前动作外的四个已保存键位。
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
    /// 再落当前动作；`visited` 用于打断这种交换环，最终仍保持五项唯一。
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
// 通用表单已独立成页；语言候选池组件仍复用原有实现与本文件中的换行布局。
struct InterestedLanguagesSettingsSection: View {

    @Binding var languages: [String]
    @Environment(\.locale) private var locale
    @State private var isExpanded = false
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
            DisclosureGroup(isExpanded: $isExpanded) {
                languageEditor
            } label: {
                // 收起仅影响编辑器可见性；已选数量和标签摘要始终读取同一份长期偏好。
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(SettingsIconMetrics.smallGlyph)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text("settings.filters.interestedLanguages.title")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(Text("settings.filters.interestedLanguages.title"))
                    }

                    selectedLanguageSummary
                        // 与标题文字对齐；图标列宽 20pt，标题间距 6pt。
                        .padding(.leading, 26)
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.filters.interestedLanguages.title"),
                accessibilityHint: Text(verbatim: selectedLanguageCountText)
            ))
        }
    }

    /// 最多保留三个标签，不让低频语言配置在收起时仍占用多行候选池空间。
    private var selectedLanguageSummary: some View {
        HStack(spacing: 6) {
            if languages.isEmpty {
                Text("settings.filters.interestedLanguages.noneSelected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(verbatim: selectedLanguageCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)

                ForEach(Array(languages.prefix(3)), id: \.self) { language in
                    HStack(spacing: 4) {
                        LanguageIconView(language: language, size: 13)
                        Text(LanguageDisplayName.shortened(for: language))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                    .foregroundStyle(.primary)
                    .help(language)
                }

                if languages.count > 3 {
                    Text(verbatim: "+\((languages.count - 3).formatted(.number.locale(locale)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// 格式化显式使用应用语言，避免数量摘要与当前界面语言各走一套 locale。
    private var selectedLanguageCountText: String {
        languages.isEmpty
            ? String.l10n("settings.filters.interestedLanguages.noneSelected")
            : String(format: String.l10n("settings.filters.interestedLanguages.selectedCountFmt"),
                     locale: locale, languages.count)
    }

    /// 复用原有候选池编辑内容；折叠不改变点选、搜索添加、移除与持久化行为。
    private var languageEditor: some View {
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
                    addLanguageChip
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("settings.filters.interestedLanguages.addLanguage"))
                .onHover { isHoveringAddLanguage = $0 }
                .popover(isPresented: $showingLanguagePicker, arrowEdge: .trailing) {
                    languagePickerPopover
                        .frame(width: 280, height: 300)
                        .padding(14)
                        .appLocaleEnvironment()
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

    /// 与常用语言 chip 同族的「添加语言」入口：胶囊 + plus 图标 + 文案，
    /// 让添加动作读作候选池的一部分而不是孤零零的 + 图标；
    /// glyph 沿用 `SettingsIconMetrics.smallGlyph`（13pt）与分组图标同源。
    private var addLanguageChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(SettingsIconMetrics.smallGlyph)
            Text("settings.filters.interestedLanguages.addLanguage")
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(addLanguageChipBackground, in: Capsule())
        .foregroundStyle(.primary)
        .contentShape(Capsule())
    }

    /// 静止态与未选中语言 chip 一致；hover 抬一档提示可点，深色下避免与表单卡混同。
    private var addLanguageChipBackground: Color {
        isHoveringAddLanguage
            ? Color.secondary.opacity(0.14)
            : Color(nsColor: .controlBackgroundColor)
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
                    ChipRemoveButton(help: Text("settings.filters.interestedLanguages.remove")) {
                        removeAction(language)
                    }
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

// MARK: - 数据与存储
//
// 页面按存储概览、缓存与生成物、草稿与会话历史、后台维护、维护与重置组织。
// 四类用量统计沿用原组件与汇总口径；15 类明细只重新分组，不改变清理和 Finder 路由。
// 草稿与会话历史有独立分组，但“删除全部缓存”继续使用原来的执行范围，并如实说明影响。

/// 缓存统计、分类清理与后台维护；视图不直接拼接路径或改变数据生命周期。
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
    @State private var isRefreshingStorageStatistics = false
    @State private var isContentCacheExpanded = false
    @State private var isGeneratedExpanded = false
    @State private var isIndexExpanded = false
    @State private var isHistoryExpanded = false

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
        isResettingAllData || !isLoggedIn || chatHistoryStore.isMigrating
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
            SettingsPageIntroduction(
                title: "settings.navigation.item.dataStorage",
                iconSource: .business(.storage),
                description: "settings.storage.layout.introduction.description",
                context: "settings.storage.layout.introduction.context"
            )

            if !isLoggedIn {
                Section {
                    Text("settings.storage.loginRequired")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 总览独立常驻，保留四类占比、颜色及原有汇总口径，折叠明细不会隐藏统计。
            Section {
                StorageCacheUsageOverviewCard(snapshot: cacheUsageOverviewSnapshot)
                HStack(spacing: 8) {
                    Text("settings.storage.refinement.overviewNote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if isRefreshingStorageStatistics {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        Task { await reloadStorageStatistics(using: cleaner) }
                    } label: {
                        Text("settings.storage.layout.refresh")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(shouldDisableStorageActions || isWorking || isRefreshingStorageStatistics)
                }
            }

            Section {
                storageDisclosure(
                    "settings.storage.layout.content.title",
                    summary: "settings.storage.layout.content.summary",
                    isExpanded: $isContentCacheExpanded
                ) {
                    usageRow(
                        titleKey: "settings.storage.readme",
                        usageText: readmeUsageText,
                        isEmpty: stats.readmeCount == 0,
                        action: .readme,
                        helpKey: "settings.storage.refinement.readme",
                        revealItem: .readmeDatabase
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.image",
                        usageText: Int64(stats.imageDiskBytes).formattedByteSize,
                        isEmpty: stats.imageDiskBytes == 0,
                        action: .image,
                        helpKey: "settings.storage.refinement.image",
                        revealItem: .imageCache
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.archive",
                        usageText: archiveUsageText,
                        isEmpty: stats.archiveCount == 0,
                        action: .archive,
                        helpKey: "settings.storage.refinement.archive",
                        revealItem: .archives
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.translation",
                        usageText: translationUsageText,
                        isEmpty: translationCache.itemCount == 0,
                        action: .translation,
                        helpKey: "settings.storage.refinement.translation",
                        revealItem: .translation
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.anySearch",
                        usageText: externalSearchUsageText,
                        isEmpty: externalSearchCache.itemCount == 0,
                        action: .anySearch,
                        helpKey: "settings.storage.refinement.anySearch",
                        revealItem: .externalSearch
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.wiki",
                        usageText: wikiUsageText,
                        isEmpty: wikiCache.itemCount == 0,
                        action: .wiki,
                        helpKey: "settings.storage.refinement.wiki",
                        revealItem: .wiki
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.issueTimeline",
                        usageText: issueTimelineUsageText,
                        isEmpty: issueTimelineCache.itemCount == 0,
                        action: .issueTimeline,
                        helpKey: "settings.storage.refinement.issueTimeline",
                        revealItem: .issueTimeline
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.recommendation",
                        usageText: recommendationUsageText,
                        isEmpty: recommendationCache.itemCount == 0,
                        action: .recommendation,
                        helpKey: "settings.storage.refinement.recommendation",
                        revealItem: .recommendation
                    )
                }
                storageDisclosure(
                    "settings.storage.layout.generated.title",
                    summary: "settings.storage.layout.generated.summary",
                    isExpanded: $isGeneratedExpanded
                ) {
                    usageRow(
                        titleKey: "settings.storage.aiContext",
                        usageText: aiContextUsageText,
                        isEmpty: aiContextStorage.projectCount == 0,
                        action: .aiContext,
                        helpKey: "settings.storage.refinement.aiContext",
                        revealItem: .aiContext
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.codeFlow",
                        usageText: codeFlowUsageText,
                        isEmpty: codeFlowStorage.projectCount == 0,
                        action: .codeFlow,
                        helpKey: "settings.storage.refinement.codeFlow",
                        revealItem: .codeFlow
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.codebaseMemory",
                        usageText: codebaseMemoryUsageText,
                        isEmpty: codebaseMemoryStorage.projectCount == 0,
                        action: .codebaseMemory,
                        helpKey: "settings.storage.refinement.codebaseMemory",
                        revealItem: .codebaseMemory
                    )
                }
                storageDisclosure(
                    "settings.storage.layout.index.title",
                    summary: "settings.storage.layout.index.summary",
                    isExpanded: $isIndexExpanded
                ) {
                    usageRow(
                        titleKey: "settings.storage.ragIndex",
                        usageText: ragIndexBytes.formattedByteSize,
                        isEmpty: ragIndexBytes == 0,
                        action: .ragIndex,
                        helpKey: "settings.storage.refinement.ragIndex",
                        revealItem: .ragDatabase
                    )
                    Divider()
                    HStack {
                        Spacer(minLength: 8)
                        Button("settings.storage.layout.openIndex") {
                            NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.knowledgeIndex")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
            } header: {
                SettingsSectionHeader("settings.storage.layout.caches.title", systemImage: "archivebox")
            }

            Section {
                storageDisclosure(
                    "settings.storage.layout.history.title",
                    summary: "settings.storage.layout.history.summary",
                    isExpanded: $isHistoryExpanded
                ) {
                    usageRow(
                        titleKey: "settings.storage.issueCommentDraft",
                        usageText: issueCommentDraftUsageText,
                        isEmpty: issueCommentDraftCache.itemCount == 0,
                        action: .issueCommentDraft,
                        helpKey: "settings.storage.refinement.issueCommentDraft",
                        revealItem: .issueCommentDraft
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.chatHistory",
                        usageText: chatHistoryUsageText,
                        isEmpty: chatHistoryStore.sessionCount == 0,
                        action: .chatHistory,
                        helpKey: "settings.storage.refinement.chatHistory",
                        revealItem: .repoAIChatHistory
                    )
                    Divider()
                    usageRow(
                        titleKey: "settings.storage.ragHistory",
                        usageText: ragHistoryUsageText,
                        isEmpty: ragConversationStats.conversationCount == 0,
                        action: .ragHistory,
                        helpKey: "settings.storage.refinement.ragHistory",
                        revealItem: .ragDatabase
                    )
                }
            } header: {
                SettingsSectionHeader("settings.storage.layout.histories.title", systemImage: "bubble.left.and.bubble.right")
            }

            Section {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.storage.refinement.prefetchTitle")
                        Text("settings.storage.refinement.prefetchNote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                    Toggle("settings.storage.refinement.prefetchTitle", isOn: $settings.readmePrefetchEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityHint(Text("settings.storage.refinement.prefetchNote"))
                }
                .disabled(shouldDisableStorageActions)

                ReadmePrefetchSettingsStatusView(
                    service: dependencies.readmePrefetchService,
                    isEnabled: settings.readmePrefetchEnabled,
                    nextRunAt: dependencies.readmePrefetchPoller.nextRunAt
                ) {
                    Button("settings.storage.readmePrefetch.runNow") {
                        Task { await triggerReadmePrefetch(using: cleaner) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(shouldDisableReadmePrefetchRunNow)
                }

                UndoStarRetentionSettings(retentionDays: $settings.undoStarRetentionDays)
                    .disabled(shouldDisableStorageActions)

                // 选择只发起迁移；原偏好必须等校验、切换成功后再持久化。
                Picker(selection: Binding(
                    get: { chatHistoryStore.storageKind },
                    set: { kind in
                        Task {
                            do {
                                try await chatHistoryStore.migrate(to: kind)
                                settings.chatHistoryStorageKind = chatHistoryStore.storageKind
                            } catch {
                                storageActionError = String(format: String.l10n("settings.storage.refinement.migrationFailed"), error.localizedDescription)
                            }
                        }
                    }
                )) {
                    ForEach(ChatHistoryStorageKind.allCases) { kind in
                        Text(LocalizedStringKey(kind.displayNameKey)).tag(kind)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.storage.chatHistoryBackend.section")
                        Text("settings.storage.refinement.backendNote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
                .disabled(shouldDisableStorageActions || isWorking)

                if chatHistoryStore.isMigrating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("settings.storage.refinement.migrating")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsSectionHeader("settings.storage.layout.background.title", systemImage: "clock")
            }

            Section {
                dangerActionBlock(
                    titleKey: "settings.storage.clearAll",
                    descriptionKey: "settings.storage.layout.clearAll.help",
                    buttonTint: Color(nsColor: .systemYellow),
                    buttonForeground: .black,
                    isDisabled: shouldDisableStorageActions || isWorking || isAllCachesEmpty
                ) {
                    Button {
                        isShowingClearAllCachesSheet = true
                    } label: {
                        Text("settings.storage.layout.action.clear")
                    }
                }

                dangerActionBlock(
                    titleKey: "settings.storage.resetAll",
                    descriptionKey: "settings.storage.resetAll.description",
                    buttonTint: .red,
                    buttonForeground: .white,
                    isDisabled: isWorking || isResettingAllData || currentResetTarget == nil || chatHistoryStore.isMigrating
                ) {
                    Button(role: .destructive) {
                        resetTarget = currentResetTarget
                    } label: {
                        Text("settings.storage.layout.action.reset")
                    }
                }
            } header: {
                SettingsSectionHeader(
                    "settings.storage.layout.maintenanceActions.title",
                    systemImage: "exclamationmark.triangle.fill"
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
            if !chatHistoryStore.isMigrating {
                settings.chatHistoryStorageKind = chatHistoryStore.storageKind
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

    /// 各类明细共用整行折叠入口；展开内容用显式分割线维持原生表单的行边界。
    private func storageDisclosure<Content: View>(
        _ title: LocalizedStringKey,
        summary: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded, content: content) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: Text(title)))
    }

    /// 危险区操作块：说明在左，按钮右对齐。黄色缓存删除与红色本地数据重置共用布局，
    /// 避免两个高风险入口在同一分组里产生不同的视觉节奏。
    private func dangerActionBlock<Action: View>(
        titleKey: LocalizedStringKey,
        descriptionKey: LocalizedStringKey,
        buttonTint: Color,
        buttonForeground: Color,
        isDisabled: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey)
                    .foregroundStyle(.primary)
                Text(descriptionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(buttonTint)
                .foregroundStyle(buttonForeground)
                .fixedSize()
                .disabled(isDisabled)
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
        let row = HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey)
                if let helpKey {
                    Text(helpKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
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
            .fixedSize()
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
        RevealInFinderIconButton(help: Text("settings.storage.revealInFinder")) {
            revealCacheLocation(item)
        }
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

    /// 手动重新统计只重读现有缓存和生成物，不触发下载、索引构建或任何清理动作。
    @MainActor
    private func reloadStorageStatistics(using cleaner: CacheCleaner) async {
        guard !shouldDisableStorageActions, !isWorking, !isRefreshingStorageStatistics else { return }
        isRefreshingStorageStatistics = true
        defer { isRefreshingStorageStatistics = false }
        aiContextStorage.reload()
        codeFlowStorage.reload()
        codebaseMemoryStorage.reload()
        translationCache.reload()
        externalSearchCache.reload()
        wikiCache.reload()
        issueTimelineCache.reload()
        issueCommentDraftCache.reload()
        chatHistoryStore.reload()
        await recommendationCache.reload()
        await refreshCacheStatistics(using: cleaner)
        await refreshRAGStorageStatistics()
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

                Text("settings.storage.layout.clearAll.subtitle")
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

            Text("settings.storage.layout.clearAll.note")
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
            "settings.storage.layout.clearAll.content",
            "settings.storage.layout.clearAll.discovery",
            "settings.storage.layout.clearAll.generated",
            "settings.storage.layout.clearAll.index",
            "settings.storage.layout.clearAll.histories",
            "settings.storage.layout.clearAll.preserved"
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
