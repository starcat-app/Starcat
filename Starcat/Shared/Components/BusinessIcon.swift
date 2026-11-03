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

        // Lucide 统一业务图标层（方案 A）：素材取自锁定版本 Lucide 1.67.0 的同名 SVG。
        // 画布自带留白，调用方按既有「16pt 素材 / 13pt SF」规则做光学尺寸匹配。
        case discovery = "BusinessDiscovery"
        case trending = "BusinessTrending"
        case popular = "flame"
        case releases = "shippingbox"
        case weekly = "BusinessWeekly"
        // 每日热点与 Weekly 拆分图形：前者雷达、后者报纸，避免探索侧栏同形撞车。
        case dailyRadar = "BusinessDailyRadar"
        case linuxDo = "text.bubble"
        case stars = "BusinessStars"
        // 知识库改用书架图形（2026-11-04 决议），heart 收敛为「加入知识库」动作语义。
        case library = "BusinessLibrary"
        case myProjects = "person.crop.rectangle.stack.fill"
        case collections = "line.3.horizontal.decrease.circle"
        case languages = "globe"
        case codeContext = "chevron.left.forwardslash.chevron.right"
        case tags = "tag.fill"
        case untagged = "tag.slash"
        case ungrouped = "tray"
        case groups = "folder.fill"
        case general = "gearshape"
        case notifications = "BusinessNotifications"
        case shortcuts = "keyboard"
        case pro = "crown.fill"
        case privacy = "lock.shield"
        case models = "cpu"
        case translation = "character.bubble"
        case mcp = "point.3.connected.trianglepath.dotted"
        case codeFlow = "flowchart"
        case services = "server.rack"
        case browserExtensions = "puzzlepiece.extension"
        case localTools = "hammer"
        case prompts = "text.quote"
        case retrieval = "magnifyingglass"
        case storage = "internaldrive"
        case diagnostics = "stethoscope"
        case labs = "flask"
        case readme = "doc.richtext"
        case notes = "note.text"
        case addNote = "note.text.badge.plus"
        case summary = "doc.text"
        case metadata = "list.bullet.rectangle"
        case knowledgeMetadata = "cylinder.split.1x2"
        case repositoryInsights = "BusinessInsights"
        case repositoryHealth = "gauge.with.dots.needle.67percent"
        case security = "checkmark.shield.fill"
        case repositories = "square.stack.3d.up"
        case repositoryAnalysis = "doc.text.magnifyingglass"
        case alternatives = "arrow.triangle.branch"
        case research = "books.vertical"
        case terminal = "terminal"
        case ragWorkspace = "bubble.left.and.text.bubble.right"
        case ai = "sparkles"

        /// 只把嵌入资源作为模板图处理；SF Symbols 继续参与系统的字重与基线排版。
        var isAsset: Bool {
            switch self {
            case .curatedCollection, .automation, .inference, .aiIndex, .license, .embedding, .recommendations,
                 .forkedRepository, .forkCount,
                 .discovery, .trending, .weekly, .dailyRadar, .stars, .library, .notifications, .repositoryInsights:
                return true
            default: return false
            }
        }

        /// 用于已只接受系统图标名的原生 API。资产调用方必须走 BusinessIcon。
        var systemImage: String {
            precondition(!isAsset, "Asset business icons must be rendered with BusinessIcon")
            return rawValue
        }
    }

    /// 通用控件仍可传 SF 名称，但资源与系统符号不能在渲染时混用。
    enum Source: Equatable, Sendable {
        case system(String)
        case asset(String)

        /// SVG 画布包含边缘留白；调用方按既有 16pt 素材 / 13pt SF 规则做光学尺寸匹配。
        var isAsset: Bool {
            if case .asset = self { return true }
            return false
        }

        /// 通用徽章和统计项也复用资源解析，不能把资产名称传给 SF Symbols API。
        static func business(_ symbol: Symbol) -> Source {
            symbol.isAsset ? .asset(symbol.rawValue) : .system(symbol.systemImage)
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
