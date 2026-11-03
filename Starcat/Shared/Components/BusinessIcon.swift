//
//  BusinessIcon.swift
//  Starcat
//
//  跨侧栏、设置、详情和工作台的业务图标入口；只补充 SF Symbols 的语义缺口。
//  素材随 App 打包并作为模板着色，不在界面渲染期间下载或解析外部 SVG。
//

import SwiftUI

/// 单色业务图标；颜色、选中态及外层占位仍由现有 Sidebar / Label 样式负责。
struct BusinessIcon: View {
    /// 使用业务含义而不是上游文件名，让同一入口在不同页面复用同一素材。
    enum Symbol: String, CaseIterable, Sendable {
        case curatedCollection = "BusinessCuratedCollection"
        case automation = "BusinessAutomation"
        case inference = "BusinessInference"
        case aiIndex = "BusinessAIIndex"
        case license = "BusinessLicense"
        case embedding = "BusinessEmbedding"
        case recommendations = "BusinessRecommendations"
        // Fork 身份与被 Fork 次数不可共用图形，避免把来源关系误读成热度统计。
        case forkedRepository = "BusinessForkedRepository"
        case forkCount = "BusinessForkCount"

        // Lucide 统一业务图标层（方案 A，2026-11-04 批量收口）：全部条目使用锁定版本
        // Lucide 1.67.0 的模板 SVG。画布自带留白，调用方按「16pt 素材 / 13pt SF」做光学匹配。
        // 仍需 SF 字符串的原生 API（Label(systemImage:) / 菜单）一律落字面量，不走本注册表。
        case discovery = "BusinessDiscovery"
        case trending = "BusinessTrending"
        case popular = "BusinessPopular"
        case releases = "BusinessReleases"
        case weekly = "BusinessWeekly"
        // 每日热点与 Weekly 拆分图形：前者雷达、后者报纸，避免探索侧栏同形撞车。
        case dailyRadar = "BusinessDailyRadar"
        case linuxDo = "BusinessLinuxDo"
        case stars = "BusinessStars"
        // 知识库改用书架图形（2026-11-04 决议），heart 收敛为「加入知识库」动作语义。
        case library = "BusinessLibrary"
        case myProjects = "BusinessMyProjects"
        case collections = "BusinessCollections"
        case languages = "BusinessLanguages"
        case codeContext = "BusinessCodeContext"
        case tags = "BusinessTags"
        case untagged = "BusinessUntagged"
        case ungrouped = "BusinessUngrouped"
        case groups = "BusinessGroups"
        case general = "BusinessGeneral"
        case notifications = "BusinessNotifications"
        case shortcuts = "BusinessShortcuts"
        case pro = "BusinessPro"
        case privacy = "BusinessPrivacy"
        case models = "BusinessModels"
        case translation = "BusinessTranslation"
        case mcp = "BusinessMCP"
        case codeFlow = "BusinessCodeFlow"
        case services = "BusinessServices"
        case browserExtensions = "BusinessBrowserExtensions"
        case localTools = "BusinessLocalTools"
        case prompts = "BusinessPrompts"
        case retrieval = "BusinessRetrieval"
        case storage = "BusinessStorage"
        case diagnostics = "BusinessDiagnostics"
        case labs = "BusinessLabs"
        case readme = "BusinessReadme"
        case notes = "BusinessNotes"
        case addNote = "BusinessAddNote"
        case summary = "BusinessSummary"
        case metadata = "BusinessMetadata"
        case knowledgeMetadata = "BusinessKnowledgeMetadata"
        case repositoryInsights = "BusinessInsights"
        case repositoryHealth = "BusinessRepositoryHealth"
        case security = "BusinessSecurity"
        case repositories = "BusinessRepositories"
        case repositoryAnalysis = "BusinessAnalysis"
        case alternatives = "BusinessAlternatives"
        case research = "BusinessResearch"
        case terminal = "BusinessTerminal"
        case ragWorkspace = "BusinessRAGWorkspace"
        case ai = "BusinessAI"
        // 活动与洞察分类补充条目：与主导航共用同一资产管线。
        case announcement = "BusinessAnnouncement"
        case following = "BusinessFollowing"
        case undoStar = "BusinessUndoStar"
        case dashboard = "BusinessDashboard"
        case organization = "BusinessOrganization"
        // 排序菜单、文件类型、Release 资产与通知筛选补充条目（批次 3）。
        case thumbsUp = "BusinessThumbsUp"
        case recentUpdate = "BusinessRecentUpdate"
        case calendarPlus = "BusinessCalendarPlus"
        case calendarDays = "BusinessCalendarDays"
        case sortAZ = "BusinessSortAZ"
        case sortZA = "BusinessSortZA"
        case heart = "BusinessHeart"
        case image = "BusinessImage"
        case file = "BusinessFile"
        case fileArchive = "BusinessFileArchive"
        case audio = "BusinessAudioLines"
        case video = "BusinessVideo"
        case monitor = "BusinessMonitor"
        case packageAsset = "BusinessPackage"
        case appWindow = "BusinessAppWindow"
        case circleDot = "BusinessCircleDot"
        case pullRequest = "BusinessGitPullRequest"
        case gitMerge = "BusinessGitMerge"
        case atSign = "BusinessAtSign"
        case eye = "BusinessEye"
        case circle = "BusinessCircle"
        case circleCheck = "BusinessCircleCheck"
        case layoutGrid = "BusinessLayoutGrid"
        case archive = "BusinessArchive"

        /// 全部条目均已资产化；保留布尔开关以便未来个别条目回落 SF Symbols。
        var isAsset: Bool { true }
    }

    /// 通用控件仍可传 SF 名称，但资源与系统符号不能在渲染时混用。
    /// Hashable：AgentDefinition 等持图标来源的数据模型需要合成判等。
    enum Source: Hashable, Sendable {
        case system(String)
        case asset(String)

        /// SVG 画布包含边缘留白；调用方按既有 16pt 素材 / 13pt SF 规则做光学尺寸匹配。
        var isAsset: Bool {
            if case .asset = self { return true }
            return false
        }

        /// 通用徽章和统计项也复用资源解析；注册表已全量资产化，直接返回资产名。
        /// 不再暴露 SF 字符串访问器，避免资产名经变量间接漏进 `Image(systemName:)`。
        static func business(_ symbol: Symbol) -> Source {
            .asset(symbol.rawValue)
        }
    }

    private let source: Source
    private let weight: Font.Weight
    @ScaledMetric private var pointSize: CGFloat

    /// pointSize 是界面中的画布尺寸，不是上游 24px 设计网格；应用字号倍率由调用方传入。
    init(_ symbol: Symbol, pointSize: CGFloat, weight: Font.Weight = .regular) {
        self.init(source: .business(symbol), pointSize: pointSize, weight: weight)
    }

    /// 共享控件持有图标来源，具体绘制仍集中在这里，尺寸由控件原有字号决定。
    init(source: Source, pointSize: CGFloat, weight: Font.Weight = .regular) {
        self.source = source
        self.weight = weight
        self._pointSize = ScaledMetric(wrappedValue: pointSize, relativeTo: .body)
    }

    /// 通用 Section 还使用非业务 SF 图标，沿用同一绘制方式而不增加伪业务枚举。
    init(systemImage: String, pointSize: CGFloat, weight: Font.Weight = .regular) {
        self.init(source: .system(systemImage), pointSize: pointSize, weight: weight)
    }

    var body: some View {
        Group {
            switch source {
            case .asset(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: pointSize, height: pointSize)
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: pointSize, weight: weight))
            }
        }
        // 该组件总是与入口文字配对，避免 VoiceOver 再朗读无意义的资源名。
        .accessibilityHidden(true)
    }
}
