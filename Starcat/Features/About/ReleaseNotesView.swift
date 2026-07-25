//
//  ReleaseNotesView.swift
//  Starcat
//
//  更新说明窗口内容：读 bundle 内 CHANGELOG，按版本 / ### 分类结构化展示。
//
//  关键约束：
//  - 文案单一来源仍是 Keep a Changelog 风格 Markdown，不另维护一份 UI 文案。
//  - `###` 小节解析成带 SF Symbol 的分区；条目尽量拆成「短标题 + 说明」。
//  - 无法结构化时回退 MarkdownUI，避免旧版 / 异常 changelog 空白。
//

import AppKit
import MarkdownUI
import SwiftUI

// MARK: - View

/// Release Notes 的 SwiftUI 内容。
///
/// `project.yml` 构建脚本在 codesign 前同步拷贝英文 `CHANGELOG.md` 与中文 `CHANGELOG-ZH.md`。
struct ReleaseNotesView: View {
    @State private var expandedVersionIDs: Set<String> = []
    @State private var localeStore = LocaleStore.shared

    var body: some View {
        let document = ChangelogParser.parse(
            ReleaseNotesLoader.loadBundledChangelog(for: localeStore.selection)
        )

        // Hero 固定在滚动区外，滚长 changelog 时仍保留产品锚点。
        VStack(spacing: 0) {
            ReleaseNotesHero()
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let latestVersion = document.latestVersion {
                        ReleaseNotesVersionCard(
                            version: latestVersion,
                            isLatest: true,
                            isExpanded: true,
                            toggle: nil
                        )
                    }

                    ForEach(document.previousVersions) { version in
                        ReleaseNotesVersionCard(
                            version: version,
                            isLatest: false,
                            isExpanded: expandedVersionIDs.contains(version.id),
                            toggle: {
                                toggleVersion(version.id)
                            }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .detailScrollViewStyle()
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.52))
    }

    private func toggleVersion(_ id: String) {
        if expandedVersionIDs.contains(id) {
            expandedVersionIDs.remove(id)
        } else {
            expandedVersionIDs.insert(id)
        }
    }
}

/// 顶部品牌区：产品图标 + 标题，对齐 About 的图标口径但尺寸更紧凑。
private struct ReleaseNotesHero: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 8, x: 0, y: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("releaseNotes.hero.title")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("releaseNotes.hero.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct ReleaseNotesVersionCard: View {
    let version: ChangelogVersion
    let isLatest: Bool
    let isExpanded: Bool
    let toggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let toggle {
                Button(action: toggle) {
                    ReleaseNotesVersionTitle(
                        title: version.title,
                        isExpanded: isExpanded,
                        showsDisclosureIcon: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            } else {
                ReleaseNotesVersionTitle(
                    title: version.title,
                    isExpanded: true,
                    showsDisclosureIcon: false,
                    badgeText: "releaseNotes.badge.new"
                )
            }

            if isExpanded {
                changelogBody
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var changelogBody: some View {
        if version.sections.isEmpty {
            // 无 ### 分区时保持可读：直接渲染原始 Markdown。
            Markdown(version.bodyMarkdown)
                .font(.body)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = version.summary, summary.isEmpty == false {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                ForEach(version.sections) { section in
                    ReleaseNotesSectionBlock(section: section)
                }
            }
        }
    }

    private var cardBackground: Color {
        if isLatest {
            return Color.accentColor.opacity(0.06)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorder: Color {
        if isLatest {
            return Color.accentColor.opacity(0.16)
        }
        return Color(nsColor: .separatorColor).opacity(0.55)
    }
}

private struct ReleaseNotesVersionTitle: View {
    let title: String
    let isExpanded: Bool
    let showsDisclosureIcon: Bool
    var badgeText: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            if let badgeText {
                // 最新版标记用 emoji，不加胶囊底色，避免把彩字洗成单色。
                Text(LocalizedStringKey(badgeText))
                    .font(.body)
            }

            Spacer(minLength: 0)

            if showsDisclosureIcon {
                Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.16), value: isExpanded)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// 单个 `###` 分类块：图标标题 + 条目列表。
private struct ReleaseNotesSectionBlock: View {
    let section: ChangelogSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: section.kind.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(section.kind.accentColor)
                    .frame(width: 16, alignment: .center)

                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(section.items) { item in
                    ReleaseNotesItemRow(item: item)
                }
            }
            .padding(.leading, 2)
        }
    }
}

private struct ReleaseNotesItemRow: View {
    let item: ChangelogItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let detail = item.detail, detail.isEmpty == false {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Models

struct ChangelogDocument {
    let preamble: String?
    let versions: [ChangelogVersion]

    var latestVersion: ChangelogVersion? {
        versions.first
    }

    var previousVersions: ArraySlice<ChangelogVersion> {
        versions.dropFirst()
    }
}

struct ChangelogVersion: Identifiable {
    let id: String
    let title: String
    /// 原始 body，结构化失败时给 MarkdownUI 兜底。
    let bodyMarkdown: String
    /// `###` 之前的引导段落（可空）。
    let summary: String?
    let sections: [ChangelogSection]
}

struct ChangelogSection: Identifiable {
    let id: String
    let title: String
    let kind: ChangelogSectionKind
    let items: [ChangelogItem]
}

struct ChangelogItem: Identifiable {
    let id: String
    let title: String
    let detail: String?
}

/// changelog `###` 分类语义，用于图标与轻度着色。
enum ChangelogSectionKind {
    case added
    case improved
    case fixed
    case highlights
    case other

    var systemImage: String {
        switch self {
        case .added: return "sparkles"
        case .improved: return "wrench.and.screwdriver"
        case .fixed: return "checkmark.seal"
        case .highlights: return "star.fill"
        case .other: return "list.bullet"
        }
    }

    /// 分类图标色：只用 accent / secondary，遵守颜色规范（无 tertiary）。
    var accentColor: Color {
        switch self {
        case .added, .highlights:
            return Color.accentColor
        case .improved, .fixed, .other:
            return Color.secondary
        }
    }

    static func infer(from title: String) -> ChangelogSectionKind {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("新增")
            || normalized == "new"
            || normalized == "added"
            || normalized.hasPrefix("added ") {
            return .added
        }
        if normalized.contains("优化")
            || normalized.contains("改进")
            || normalized == "improvements"
            || normalized == "improved"
            || normalized == "changed"
            || normalized == "changes" {
            return .improved
        }
        if normalized.contains("修复")
            || normalized == "fixes"
            || normalized == "fixed"
            || normalized == "bug fixes" {
            return .fixed
        }
        if normalized.contains("亮点")
            || normalized.contains("highlight") {
            return .highlights
        }
        return .other
    }
}

// MARK: - Parser

/// Keep a Changelog 解析：按 `##` 切版本，再按 `###` 切分类与 bullet。
enum ChangelogParser {
    static func parse(_ markdown: String) -> ChangelogDocument {
        let lines = markdown.components(separatedBy: .newlines)
        var preambleLines: [String] = []
        var versions: [ChangelogVersion] = []
        var currentTitle: String?
        var currentBodyLines: [String] = []

        for line in lines {
            if let title = versionTitle(from: line) {
                appendVersion(title: currentTitle, bodyLines: currentBodyLines, to: &versions)
                currentTitle = title
                currentBodyLines = []
            } else if currentTitle == nil {
                preambleLines.append(line)
            } else {
                currentBodyLines.append(line)
            }
        }
        appendVersion(title: currentTitle, bodyLines: currentBodyLines, to: &versions)

        let preamble = normalizedMarkdown(from: preambleLines)
        return ChangelogDocument(
            preamble: preamble.isEmpty ? nil : preamble,
            versions: versions
        )
    }

    /// 只按 Keep a Changelog 的二级标题切版本，避免把三级功能小节误判为版本。
    private static func versionTitle(from line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let rawTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawTitle.isEmpty == false else { return nil }

        if rawTitle.hasPrefix("["),
           let closingBracket = rawTitle.firstIndex(of: "]") {
            let version = rawTitle[rawTitle.index(after: rawTitle.startIndex)..<closingBracket]
            let suffix = rawTitle[rawTitle.index(after: closingBracket)...]
            return "\(version)\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rawTitle
    }

    private static func appendVersion(
        title: String?,
        bodyLines: [String],
        to versions: inout [ChangelogVersion]
    ) {
        guard let title else { return }
        let bodyMarkdown = normalizedMarkdown(from: bodyLines)
        let parsedBody = parseBody(bodyMarkdown)
        versions.append(
            ChangelogVersion(
                id: title,
                title: title,
                bodyMarkdown: bodyMarkdown,
                summary: parsedBody.summary,
                sections: parsedBody.sections
            )
        )
    }

    /// 把版本 body 拆成引导段 + `###` 分区。无 `###` 时 sections 为空，UI 走 Markdown 兜底。
    static func parseBody(_ markdown: String) -> (summary: String?, sections: [ChangelogSection]) {
        let lines = markdown.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        var sections: [ChangelogSection] = []
        var currentTitle: String?
        var currentItems: [String] = []

        func flushSection() {
            guard let currentTitle else { return }
            let items = currentItems.enumerated().map { index, raw in
                let split = splitItem(raw)
                return ChangelogItem(
                    id: "\(currentTitle)-\(index)",
                    title: split.title,
                    detail: split.detail
                )
            }
            // 空分区（只有标题无 bullet）仍保留，避免吞掉用户写的小节标题。
            sections.append(
                ChangelogSection(
                    id: "\(currentTitle)-\(sections.count)",
                    title: currentTitle,
                    kind: .infer(from: currentTitle),
                    items: items
                )
            )
        }

        for line in lines {
            if line.hasPrefix("### ") {
                flushSection()
                currentTitle = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentItems = []
                continue
            }

            if currentTitle == nil {
                summaryLines.append(line)
                continue
            }

            if let bullet = bulletText(from: line) {
                currentItems.append(bullet)
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // 续行并入上一条 bullet，兼容编辑器软换行。
                if trimmed.isEmpty == false, currentItems.isEmpty == false {
                    currentItems[currentItems.count - 1] += " " + trimmed
                }
            }
        }
        flushSection()

        let summary = normalizedMarkdown(from: summaryLines)
        return (summary.isEmpty ? nil : summary, sections)
    }

    /// 从 `- ` / `* ` / `+ ` 列表行取出正文；支持可选任务列表前缀。
    static func bulletText(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, "-*+".contains(first) else { return nil }
        var rest = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        // `- [x] text` / `- [ ] text`
        if rest.hasPrefix("["),
           rest.count >= 3,
           rest[rest.index(rest.startIndex, offsetBy: 2)] == "]" {
            let afterBracket = rest.index(rest.startIndex, offsetBy: 3)
            rest = String(rest[afterBracket...]).trimmingCharacters(in: .whitespaces)
        }
        guard rest.isEmpty == false else { return nil }
        return rest
    }

    /// 把一条 changelog bullet 尽量拆成「短标题 + 说明」，扫读成本更低。
    ///
    /// 不改 changelog 文件：靠逗号 / 破折号 / 冒号启发式；拆不好就整句当标题。
    static func splitItem(_ raw: String) -> (title: String, detail: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripMarkdownEmphasis(text)
        text = stripLeadingCategoryVerb(text)

        // 新规范优先冒号；仍兼容历史 em / en dash。
        if let split = split(text, separator: "：") { return polish(split) }
        if let split = split(text, separator: ": "), split.left.count <= 36 {
            return polish(split)
        }
        if let split = split(text, separator: " — ") { return polish(split) }
        if let split = split(text, separator: " – ") { return polish(split) }

        // 中文：首个顿号/逗号前较短时作标题。
        if let index = text.firstIndex(of: "，") {
            let left = String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if left.count >= 2, left.count <= 18, right.count >= 6 {
                return polish((left, right))
            }
        }

        // 英文：首个 ", " 且左侧不太长。
        if let range = text.range(of: ", ") {
            let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if left.count >= 4, left.count <= 42, right.count >= 8 {
                return polish((left, right))
            }
        }

        return (text, nil)
    }

    private static func split(
        _ text: String,
        separator: String
    ) -> (left: String, right: String)? {
        guard let range = text.range(of: separator) else { return nil }
        let left = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard left.isEmpty == false, right.isEmpty == false else { return nil }
        return (left, right)
    }

    private static func polish(_ parts: (left: String, right: String)) -> (title: String, detail: String?) {
        var title = parts.left
        // 标题去掉句末标点；说明保留 changelog 原文标点。
        while let last = title.last, "。．.".contains(last) {
            title.removeLast()
        }
        return (title, parts.right)
    }

    /// 去掉条目开头与分区标题重复的动词，避免「新增 / Added」双重噪音。
    private static func stripLeadingCategoryVerb(_ text: String) -> String {
        let verbs = [
            "新增", "优化", "修复", "支持", "改进",
            "Added ", "Improved ", "Fixed ", "Changed ", "Add ",
            "added ", "improved ", "fixed ", "changed "
        ]
        for verb in verbs {
            if text.hasPrefix(verb) {
                return String(text.dropFirst(verb.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    private static func stripMarkdownEmphasis(_ text: String) -> String {
        var result = text
        if result.hasPrefix("**"), result.hasSuffix("**"), result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedMarkdown(from lines: [String]) -> String {
        lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Loader

/// 读取随 App 打包的 CHANGELOG。
///
/// 同步读取：文件很小，窗口打开时读一次即可；失败时返回短 Markdown 兜底。
enum ReleaseNotesLoader {
    static func loadBundledChangelog(for appLocale: AppLocale) -> String {
        for resourceName in preferredResourceNames(for: appLocale) {
            if let markdown = loadMarkdown(resourceName: resourceName) {
                return markdown
            }
        }
        return fallbackMarkdown
    }

    /// Release Notes 目前只有简体中文和英文资源。除简体中文外统一回退英文，
    /// 避免把简体中文正文展示给繁体中文用户，也避免为不存在的资源返回空白。
    private static func preferredResourceNames(for appLocale: AppLocale) -> [String] {
        switch appLocale {
        case .simplifiedChinese:
            return ["CHANGELOG-ZH", "CHANGELOG"]
        case .english,
             .traditionalChinese,
             .japanese,
             .korean,
             .german,
             .french,
             .spanish,
             .brazilianPortuguese,
             .italian,
             .russian,
             .dutch,
             .polish,
             .ukrainian,
             .turkish,
             .vietnamese,
             .indonesian,
             .arabic:
            return ["CHANGELOG"]
        case .system:
            if systemPrefersSimplifiedChinese {
                return ["CHANGELOG-ZH", "CHANGELOG"]
            }
            return ["CHANGELOG"]
        }
    }

    /// 只让简体中文系统偏好命中 `CHANGELOG-ZH`。`zh-Hant` 尚无对应 Changelog
    /// 资源，必须回退英文，不能因为 languageCode 同为 `zh` 而错误展示简体正文。
    private static var systemPrefersSimplifiedChinese: Bool {
        let identifier = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? Locale.current.identifier
        let language = Locale.Language(identifier: identifier)
        guard language.languageCode?.identifier == "zh" else {
            return false
        }
        let script = language.script?.identifier
        let region = language.region?.identifier
        return script != "Hant" && region != "TW" && region != "HK" && region != "MO"
    }

    private static func loadMarkdown(resourceName: String) -> String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return markdown
    }

    private static let fallbackMarkdown = """
    # Release Notes

    The bundled changelog is temporarily unavailable.
    """
}
