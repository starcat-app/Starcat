//
//  LicenseKnowledgeCapsule.swift
//  Starcat
//
//  带义务类别的 License 胶囊 + 点击展开的许可说明卡（2026-11-01 与 dong4j 对齐的设计）。
//
//  产品目标：用户不读原文就能回答三个问题——
//  ① 我可以怎么用（你可以）② 要履行什么义务（需要做到）③ 容易忽略什么（需要注意）。
//
//  关键设计决策：
//  - 颜色按「许可义务类别」而不是「能否商用」；互惠档允许商用这一点必须在卡里写明。
//  - 颜色只占小面积（浅底 + 深字 + 细边框），胶囊默认高 24pt，文字类别始终保留，
//    用户不依赖颜色也能理解（同时天然兼容暗色与辅助功能）。
//  - 多重许可（OR / AND / WITH）不取"最严格"颜色，落中性灰并由卡展开解释；
//    待确认（未识别 / NOASSERTION / 缺失）同灰但文案不同。
//  - 卡内容是人工核对过的固定模板（LicenseKnowledge.swift 静态表），
//    不是运行时生成；底部保留 LICENSE 原文入口，摘要永远让位于原文。
//
//  交互：
//  - 悬停：pressableHover 反馈 + tooltip；
//  - 点击：胶囊下方展开 popover，胶囊保持选中态（底色加深）；
//  - 关闭：点外部（popover transient 行为）、再次点击胶囊、Esc 或卡内关闭钮。
//
//  i18n 注意：所有 key 派生自运行时字符串（contentKey / 类别枚举），
//  必须走 `String.l10n`；`Text(String 变量)` 是 verbatim 语义，不会查表。
//

import SwiftUI

// MARK: - 类别视觉与文案

extension LicenseCategory {

    /// 胶囊上的短标签（宽松 / 有限互惠 / 强互惠 / 网络互惠 / 多重许可 / 待确认）。
    var shortLabelKey: String {
        switch self {
        case .permissive: return "license.category.permissive"
        case .weakCopyleft: return "license.category.weakCopyleft"
        case .strongCopyleft: return "license.category.strongCopyleft"
        case .networkCopyleft: return "license.category.networkCopyleft"
        case .multiLicense: return "license.category.multiLicense"
        case .unknown: return "license.category.unknown"
        }
    }

    /// 说明卡头部的完整标签（宽松许可 / 有限互惠许可 / ...）。
    var fullLabelKey: String {
        switch self {
        case .permissive: return "license.category.full.permissive"
        case .weakCopyleft: return "license.category.full.weakCopyleft"
        case .strongCopyleft: return "license.category.full.strongCopyleft"
        case .networkCopyleft: return "license.category.full.networkCopyleft"
        case .multiLicense: return "license.category.full.multiLicense"
        case .unknown: return "license.category.full.unknown"
        }
    }
}

/// 类别配色。浅色值取自设计稿（2026-11-01 分类建议）；深色模式浅底会刺眼，
/// 改用类别色低透明铺底 + 提亮前景，靠同一色相保持类别可辨识。
/// `multiLicense` 与 `unknown` 共用中性灰：两者都是"需要看卡确认"的状态，
/// 由标签文字区分语义，避免类别色数量失控。
struct LicenseCategoryPalette {
    let foreground: Color
    let background: Color
    /// 选中态（popover 展开中）：底色加深，胶囊保持"被按下"的视觉。
    let backgroundSelected: Color
    /// 细边框：前景色低透明。
    var border: Color { foreground.opacity(0.28) }

    static func palette(for category: LicenseCategory) -> LicenseCategoryPalette {
        switch category {
        case .permissive:
            return make(lightFg: 0x237A47, darkFg: 0x5BBE87, lightBg: 0xEAF6EE)
        case .weakCopyleft:
            return make(lightFg: 0x285E9D, darkFg: 0x7FA8DC, lightBg: 0xEDF3FB)
        case .strongCopyleft:
            return make(lightFg: 0x936000, darkFg: 0xD9B25A, lightBg: 0xFFF4D9)
        case .networkCopyleft:
            return make(lightFg: 0xB24F2F, darkFg: 0xE08A67, lightBg: 0xFCEDE6)
        case .multiLicense, .unknown:
            return make(lightFg: 0x666B73, darkFg: 0xA8ADB5, lightBg: 0xF0F1F3)
        }
    }

    private static func make(lightFg: UInt32, darkFg: UInt32, lightBg: UInt32) -> LicenseCategoryPalette {
        LicenseCategoryPalette(
            foreground: adaptive(light: lightFg, dark: darkFg),
            background: adaptiveBackground(lightBg: lightBg, darkFg: darkFg, overlay: 0.16),
            backgroundSelected: adaptiveBackground(lightBg: nil, darkFg: darkFg, lightFg: lightFg, overlay: 0.20)
        )
    }

    /// NSColor 动态提供者：按明暗外观切换，主题切换时即时生效。
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }

    /// 浅色用设计稿底色；深色用前景色低透明铺底（浅底在深色面板上会刺眼）。
    /// `lightBg == nil` 时浅色也走前景低透明（选中态加深路径）。
    private static func adaptiveBackground(
        lightBg: UInt32?,
        darkFg: UInt32,
        lightFg: UInt32? = nil,
        overlay: CGFloat
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(hex: darkFg).withAlphaComponent(overlay)
            }
            if let lightBg {
                return NSColor(hex: lightBg)
            }
            return NSColor(hex: lightFg ?? darkFg).withAlphaComponent(overlay)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension LicenseCategory {
    var palette: LicenseCategoryPalette {
        LicenseCategoryPalette.palette(for: self)
    }
}

// MARK: - 胶囊

/// License 胶囊：⚖ + 标识 + 类别短标签 + ⓘ，点击展开说明卡。
/// 传入的是 DB 原始 license 字符串，解析统一走 `LicenseKnowledge.resolve`。
struct LicenseKnowledgeCapsule: View {
    let rawLicense: String?
    let owner: String
    let repoName: String
    /// 搜索详情沿用原匹配度胶囊的上下各 3pt 留白，其他详情仍使用默认 24pt 高度。
    var isCompact = false

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var showsDetails = false

    var body: some View {
        // 每次渲染重新解析即可：纯函数查表，无 IO，state 只保留 popover 开关。
        let resolution = LicenseKnowledge.resolve(rawLicense)
        let category = Self.category(of: resolution)
        let palette = category.palette

        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                BusinessIcon(.license, pointSize: 11 * interfaceScale.multiplier)
                Text(verbatim: Self.displayName(of: resolution))
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: String.l10n(category.shortLabelKey))
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "info.circle")
                    .font(interfaceScale.font(.captionSmall))
                    .imageScale(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, isCompact ? 3 : 0)
            .frame(height: isCompact ? nil : 24)
            .background(showsDetails ? palette.backgroundSelected : palette.background, in: Capsule())
            .overlay {
                Capsule().strokeBorder(palette.border, lineWidth: 0.5)
            }
            .foregroundStyle(palette.foreground)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover(opacity: 0.8, scale: 1.0)
        .help("license.capsule.help")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            LicenseKnowledgePopoverContent(
                resolution: resolution,
                owner: owner,
                repoName: repoName,
                onClose: { showsDetails = false }
            )
        }
    }

    private static func category(of resolution: LicenseKnowledgeResolution) -> LicenseCategory {
        switch resolution {
        case .known(let entry): return entry.category
        case .multiLicense: return .multiLicense
        case .unknown: return .unknown
        }
    }

    /// 胶囊主文本：已知 → SPDX 标识；多重许可 → 原始表达式（截断）；
    /// 待确认 → 原值；缺失 → 本地化通用名。
    private static func displayName(of resolution: LicenseKnowledgeResolution) -> String {
        switch resolution {
        case .known(let entry): return entry.displayName
        case .multiLicense(let expression): return expression
        case .unknown(let raw):
            return raw ?? String.l10n("license.generic.name")
        }
    }
}

// MARK: - 说明卡

/// 许可说明卡：一句话结论 → 你可以 → 需要做到 → 需要注意 → 原文入口。
/// 所有文案 key 由 `contentKey` 派生并在 `Localizable.xcstrings` 人工核对，
/// 条目数量由 `cardSpecs` 声明；单测会校验 spec 与 strings 一一对应。
struct LicenseKnowledgePopoverContent: View {
    let resolution: LicenseKnowledgeResolution
    let owner: String
    let repoName: String
    let onClose: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    /// 说明卡条目分组；internal 是因为 cardSpecs 要暴露给单测校验。
    enum CardSection: String {
        case can
        case must
        case watch
    }

    /// 每张卡的条目数量声明（key 形如 `license.card.<key>.can.<i>`）。
    /// 新增 / 调整卡内容时必须与 Localizable.xcstrings 同步改这里；
    /// internal 供单测校验 spec 与中英文案一一对应。
    static let cardSpecs: [String: [CardSection: Int]] = [
        "mit": [.can: 4, .must: 1, .watch: 2],
        "apache-2.0": [.can: 4, .must: 2, .watch: 2],
        "bsd-2-clause": [.can: 4, .must: 2, .watch: 1],
        "bsd-3-clause": [.can: 4, .must: 3, .watch: 1],
        "isc": [.can: 4, .must: 1, .watch: 2],
        "cc0-1.0": [.can: 4, .must: 1, .watch: 2],
        "unlicense": [.can: 4, .must: 1, .watch: 2],
        "0bsd": [.can: 4, .must: 1, .watch: 1],
        "wtfpl": [.can: 4, .must: 1, .watch: 1],
        "mit-0": [.can: 4, .must: 2, .watch: 1],
        "zlib": [.can: 4, .must: 2, .watch: 1],
        "bsl-1.0": [.can: 4, .must: 1, .watch: 1],
        "mpl-2.0": [.can: 4, .must: 2, .watch: 2],
        "lgpl-2.0": [.can: 4, .must: 2, .watch: 2],
        "lgpl-2.1": [.can: 4, .must: 2, .watch: 2],
        "lgpl-3.0": [.can: 4, .must: 2, .watch: 2],
        "gpl-2.0": [.can: 4, .must: 2, .watch: 3],
        "gpl-3.0": [.can: 4, .must: 2, .watch: 3],
        "agpl-3.0": [.can: 4, .must: 2, .watch: 2],
        "multi": [.can: 1, .must: 2, .watch: 2],
        "unknown": [.can: 2, .must: 1, .watch: 2],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            conclusion
            Divider()
            canSection
            mustSection
            watchSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 440, alignment: .leading)
        // 关键：popover 内容会继承挂载点所在环境的 lineLimit——Hero 区 badgeRow
        // 的 `.lineLimit(1)` 会渗入并把卡内所有 Text 压成单行（长句被省略号截断
        // 而不是换行）。这里显式重置为不限行数，让结论 / 义务长句正常换行。
        .lineLimit(nil)
        // popover 是独立窗口层级，不会稳定继承父 scene 的 locale；
        // 按 i18n 军规给 sheet / popover 根视图挂语言环境（卡内文案同时走 String.l10n 双保险）。
        .appLocaleEnvironment()
    }

    // MARK: 子区

    private var header: some View {
        HStack(spacing: 8) {
            BusinessIcon(.license, pointSize: 18 * interfaceScale.multiplier)
                .foregroundStyle(category.palette.foreground)
            Text(verbatim: title)
                .font(interfaceScale.font(.panelTitle))
                .lineLimit(1)
            // 类别完整标签：文字类别 + 颜色双通道，与胶囊短标签区分层级。
            Text(verbatim: String.l10n(category.fullLabelKey))
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(category.palette.background, in: Capsule())
                .foregroundStyle(category.palette.foreground)
            Spacer()
            SheetCloseButton(
                action: onClose,
                iconFont: .system(size: 16, weight: .medium)
            )
        }
    }

    private var conclusion: some View {
        Text(verbatim: String.l10n(conclusionKey))
            .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
    }

    private var canSection: some View {
        sectionTitle("license.card.section.can") {
            // 权限清单两列排布（与设计稿一致），右列留白时自然收紧。
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(cardKeys(.can), id: \.self) { key in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(Color.green)
                        Text(verbatim: String.l10n(key))
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var mustSection: some View {
        sectionTitle("license.card.section.must") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cardKeys(.must), id: \.self) { key in
                    HStack(alignment: .top, spacing: 8) {
                        // 左侧类别色短竖条：把"义务"与类别语义绑在一起。
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(category.palette.foreground)
                            .frame(width: 3)
                        Image(systemName: "doc.text")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(category.palette.foreground)
                        Text(verbatim: String.l10n(key))
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var watchSection: some View {
        sectionTitle("license.card.section.watch") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(cardKeys(.watch), id: \.self) { key in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                        Text(verbatim: String.l10n(key))
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let licenseURL {
                Link(destination: licenseURL) {
                    Label {
                        // popover 是独立窗口层级，Text("key") 不跟随语言设置，
                        // 必须与卡内其它文案一样走 String.l10n 查表。
                        Text(verbatim: String.l10n("license.card.action.viewLicense"))
                    } icon: {
                        Image(systemName: "arrow.up.forward")
                    }
                    .font(interfaceScale.font(.caption, weight: .medium))
                }
                .pointerStyle(.link)
            }
            Spacer()
            if let referenceURL {
                Link(destination: referenceURL) {
                    Text(verbatim: String.l10n("license.card.action.learnMore"))
                        .font(interfaceScale.font(.caption, weight: .medium))
                }
                .pointerStyle(.link)
            }
        }
    }

    private func sectionTitle<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: String.l10n(key))
                .font(interfaceScale.font(.captionStrong))
                .foregroundStyle(.primary)
            content()
        }
    }

    // MARK: 模型派生

    private var category: LicenseCategory {
        switch resolution {
        case .known(let entry): return entry.category
        case .multiLicense: return .multiLicense
        case .unknown: return .unknown
        }
    }

    /// 卡标题：已知 → 本地化完整名（"MIT License" / "MIT 许可证"）；
    /// 多重许可 / 待确认 → 原始数据文本，缺失时用通用名。
    private var title: String {
        switch resolution {
        case .known(let entry):
            return String.l10n("license.card.\(entry.contentKey).title")
        case .multiLicense(let expression):
            return expression
        case .unknown(let raw):
            return raw ?? String.l10n("license.generic.name")
        }
    }

    private var contentKey: String {
        switch resolution {
        case .known(let entry): return entry.contentKey
        case .multiLicense: return "multi"
        case .unknown: return "unknown"
        }
    }

    private var conclusionKey: String {
        "license.card.\(contentKey).conclusion"
    }

    /// 按数量声明生成条目 key；spec 缺卡时安全退化为空列表而不是崩。
    private func cardKeys(_ section: CardSection) -> [String] {
        guard let spec = Self.cardSpecs[contentKey], let count = spec[section] else { return [] }
        return (0..<count).map { "license.card.\(contentKey).\(section.rawValue).\($0)" }
    }

    /// 查看项目 LICENSE：已知卡用规范 SPDX 构造 GitHub 概览链接；
    /// 多重许可 / 待确认 GitHub 不提供该锚点页，隐藏入口（与 RepoExternalLinks 过滤口径一致）。
    private var licenseURL: URL? {
        guard case .known(let entry) = resolution else { return nil }
        return RepoExternalLinks.license(owner: owner, name: repoName, spdx: entry.displayName)
    }

    private var referenceURL: URL? {
        guard case .known(let entry) = resolution else { return nil }
        return entry.referenceURL
    }
}
