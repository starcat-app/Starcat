//
//  RepoSkillSelectionPane.swift
//  Starcat
//
//  Skill 左栏将阅读对象与安装勾选分离，状态来自当前目标目录的实际文件校验。
//

import SwiftUI

/// 左栏保持稳定宽度，安装过程中锁定勾选，但仍允许浏览不同 Skill。
struct RepoSkillSelectionPane: View {
    let session: RepoSkillSession
    @Binding var previewID: String

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Namespace private var selectionSpace
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var filteredSkills: [RepoSkill] = []
    @State private var visibleSkills: [RepoSkill] = []
    @State private var publishedQuery = ""
    @State private var publishedRevision: UInt64 = 0
    @State private var isFiltering = false

    private enum Filter: String, CaseIterable, Sendable {
        case all, pending, installed
        func key(isExport: Bool) -> String {
            switch self {
            case .all: "repo.skills.list.all"
            case .pending: isExport ? "repo.skills.list.toExport" : "repo.skills.list.pending"
            case .installed: isExport ? "repo.skills.install.exported" : "repo.skills.list.installed"
            }
        }

        func symbol(isExport: Bool) -> String {
            switch self {
            case .all: "square.stack.3d.up"
            case .pending: isExport ? "square.and.arrow.up" : "arrow.down.circle"
            case .installed: "checkmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .all: .blue
            case .pending: .orange
            case .installed: .green
            }
        }
    }

    private var query: String { "\(filter.rawValue):\(search)" }
    private var hasMore: Bool { visibleSkills.count < filteredSkills.count }

    /// 首次扫描与筛选都可能暂时没有行；已有结果刷新时继续展示，最终空结果才显示空状态。
    private var showsLoadingSkeleton: Bool {
        visibleSkills.isEmpty && (
            isFiltering || publishedQuery != query
                || (session.skills.isEmpty && (session.isLoading || (session.scan == nil && session.error == nil)))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            CountedSegmentedControl(
                items: Filter.allCases, selection: $filter, totalCount: session.skills.count,
                title: { LocalizedStringKey($0.key(isExport: session.isExport)) },
                count: { count($0) },
                accessibilityLabel: "repo.skills.preview.selection",
                symbol: { $0.symbol(isExport: session.isExport) },
                tint: { $0.tint }
            )
            .padding(12)
            RepoWorkspaceSearchField(placeholder: "repo.skills.search", text: $search)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: RepoSkillRowChrome.rowSpacing) {
                    ForEach(Array(visibleSkills.enumerated()), id: \.element.id) { index, skill in
                        skillRow(skill, rowIndex: index)
                            .automaticListPagination(
                                appearingIndex: index, visibleItemCount: visibleSkills.count,
                                loadedItemCount: visibleSkills.count, hasMore: hasMore,
                                isLoading: isFiltering,
                                identity: "\(publishedQuery):\(publishedRevision)"
                            ) { appendPage(appearingIndex: index) }
                    }
                    if visibleSkills.isEmpty, !showsLoadingSkeleton {
                        Label("repo.skills.list.empty", systemImage: "shippingbox")
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 42)
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: previewID)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
            .opacity(showsLoadingSkeleton ? 0 : 1)
            .allowsHitTesting(!showsLoadingSkeleton)
            .accessibilityHidden(showsLoadingSkeleton)
            .overlay(alignment: .topLeading) {
                if showsLoadingSkeleton {
                    RepoSkillSkeletonView(layout: .selection)
                        .padding(.horizontal, 14)
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: showsLoadingSkeleton)

            HStack {
                Button("repo.skills.selection.all") { session.selectAll(true) }
                Spacer()
                Button("repo.skills.selection.clear") { session.selectAll(false) }
            }
            .font(interfaceScale.font(.caption))
            .buttonStyle(.borderless)
            .disabled(session.isInstalling)
            .padding(14)
        }
        .background(Color.primary.opacity(0.025))
        .task(id: "\(query):\(session.listRevision)") {
            isFiltering = true
            let requestedQuery = query
            do {
                let result = try await Self.filterSkills(
                    session.skills, installed: session.installedIDs, search: search, filter: filter
                )
                try Task.checkCancellation()
                let count = publishedQuery == requestedQuery ? max(60, visibleSkills.count) : 60
                filteredSkills = result
                visibleSkills = Array(result.prefix(count))
                publishedQuery = requestedQuery
                isFiltering = false
                // 加载完成才改变分页身份，补发在筛选准备期间出现的尾部行需求。
                publishedRevision &+= 1
            } catch {
                if !Task.isCancelled { isFiltering = false }
            }
        }
    }

    private func count(_ filter: Filter) -> Int {
        switch filter {
        case .all: session.skills.count
        case .pending: session.skills.count - session.installedIDs.count
        case .installed: session.installedIDs.count
        }
    }

    /// 搜索只在输入或证据变化时计算；离开 MainActor，不能让大集合搜索阻塞滚动。
    @concurrent private nonisolated static func filterSkills(
        _ skills: [RepoSkill], installed: Set<String>, search: String, filter: Filter
    ) async throws -> [RepoSkill] {
        try Task.checkCancellation()
        return try skills.filter { skill in
            try Task.checkCancellation()
            guard search.isEmpty || skill.name.localizedCaseInsensitiveContains(search)
                || skill.summary.localizedCaseInsensitiveContains(search)
                || skill.directory.localizedCaseInsensitiveContains(search) else { return false }
            switch filter {
            case .all: return true
            case .pending: return !installed.contains(skill.id)
            case .installed: return installed.contains(skill.id)
            }
        }
    }

    /// 统一预取触发器负责快速滚动；追加成本仅与一页有关。
    private func appendPage(appearingIndex: Int) {
        guard !isFiltering, publishedQuery == query,
              ListPaginationPolicy.shouldPrefetch(
                  appearingIndex: appearingIndex, itemCount: visibleSkills.count, hasMore: hasMore
              ) else { return }
        // 同一帧可能有多行请求预取；按追加后的数量复核，不能把排队的旧请求连续放大成多页。
        let end = min(visibleSkills.count + 60, filteredSkills.count)
        visibleSkills.append(contentsOf: filteredSkills[visibleSkills.count..<end])
    }

    /// checkbox 只修改安装集合；右侧整块按钮只切换预览，避免误选和误取消。
    private func skillRow(_ skill: RepoSkill, rowIndex: Int) -> some View {
        SkillRow(
            skill: skill,
            rowIndex: rowIndex,
            session: session,
            isPreviewSelected: previewID == skill.id,
            selectionSpace: selectionSpace
        ) { previewID = $0 }
    }

}

/// 紧凑单行列表：名称保持唯一可见内容，路径只进入 tooltip 和无障碍说明。
private struct SkillRow: View {
    let skill: RepoSkill
    let rowIndex: Int
    let session: RepoSkillSession
    let isPreviewSelected: Bool
    let selectionSpace: Namespace.ID
    let selectPreview: (String) -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isInstalled: Bool { session.installedIDs.contains(skill.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Toggle(isOn: Binding(
                get: { session.selectedIDs.contains(skill.id) },
                set: { _ in session.toggleSelection(skill.id) }
            )) {
                Text(verbatim: skill.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(session.isInstalling || skill.installationIssue != nil)
            .padding(.leading, RepoSkillRowChrome.horizontalInset)

            Button {
                selectPreview(skill.id)
            } label: {
                HStack(spacing: RepoSkillRowChrome.itemSpacing) {
                    RepoSkillMonogram(skill: skill)
                    Text(verbatim: skill.name)
                        .font(interfaceScale.font(.bodyEmphasis, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .offset(x: isHovered && !isPreviewSelected && !reduceMotion ? 1.5 : 0)
                    Spacer(minLength: 0)
                    if isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(Color.green)
                            .help(LocalizedStringKey(session.isExport ? "repo.skills.install.exported" : "repo.skills.install.installed"))
                    } else if session.coverage(of: skill.id) > 0 {
                        Text(verbatim: "\(session.coverage(of: skill.id))/\(session.selectedDestinations.count)")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let issue = skill.installationIssue {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .help(issue)
                            .accessibilityLabel(Text(verbatim: issue))
                    }
                }
                // 预览按钮覆盖复选框右侧的整行区域，包含留白；复选框保留独立命中。
                .padding(.leading, RepoSkillRowChrome.itemSpacing)
                .padding(.trailing, RepoSkillRowChrome.horizontalInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityAddTraits(isPreviewSelected ? .isSelected : [])
        }
        .frame(height: interfaceScale.scaled(RepoSkillRowChrome.rowHeight))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: RepoSkillRowChrome.rowCornerRadius, style: .continuous)
                    .fill(RepoSkillRowChrome.background(rowIndex: rowIndex, isSelected: false, isHovered: isHovered))
                    .opacity(isPreviewSelected ? 0 : 1)
                if isPreviewSelected {
                    if reduceMotion {
                        selectionBackground
                    } else {
                        // 高亮的各层共用几何身份，文字、色块与复选框保持原位。
                        selectionBackground
                            .matchedGeometryEffect(id: "repo.skills.preview.selection", in: selectionSpace)
                    }
                }
            }
        }
        .onHover { isHovered = $0 }
        .help(skill.summary + "\n" + skill.manifestPath)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
    }

    private var selectionBackground: some View {
        let shape = RoundedRectangle(cornerRadius: RepoSkillRowChrome.rowCornerRadius, style: .continuous)
        return shape
            .fill(RepoSkillRowChrome.background(rowIndex: rowIndex, isSelected: true, isHovered: false))
            .overlay { shape.strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1) }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 16)
                    .padding(.leading, 5)
            }
    }
}

/// Skill 名称没有稳定语义图标；用确定性字母块提供识别点，不伪造分类含义。
private struct RepoSkillMonogram: View {
    let skill: RepoSkill

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let monogram = RepoSkillRowChrome.monogram(for: skill.name)
        let tint = RepoSkillRowChrome.monogramTint(for: skill)
        let size = interfaceScale.scaled(RepoSkillRowChrome.monogramSize)
        let shape = RoundedRectangle(cornerRadius: RepoSkillRowChrome.monogramCornerRadius, style: .continuous)

        Text(verbatim: monogram)
            .font(.system(size: interfaceScale.scaled(10), weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: shape)
            .overlay { shape.strokeBorder(tint.opacity(0.28)) }
            .accessibilityHidden(true)
    }
}

/// 真实行和骨架共用尺寸与斑马纹，避免加载交接时改变对齐位置。
enum RepoSkillRowChrome {
    static let rowHeight: CGFloat = 38
    static let rowSpacing: CGFloat = 2
    static let rowCornerRadius: CGFloat = 5
    static let horizontalInset: CGFloat = 10
    static let itemSpacing: CGFloat = 8
    static let monogramSize: CGFloat = 24
    static let monogramCornerRadius: CGFloat = 6

    private static let monogramPalette: [Color] = [
        .blue, .teal, .indigo, .purple, .pink, .orange
    ]

    /// 选中 > 悬停 > 斑马纹；避免悬停时破坏当前预览行的语义。
    static func background(rowIndex: Int, isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            Color.accentColor.opacity(0.14)
        } else if isHovered {
            Color.accentColor.opacity(0.08)
        } else {
            Color.primary.opacity(rowIndex.isMultiple(of: 2) ? 0.015 : 0.045)
        }
    }

    /// 名称可能来自任意仓库，没有可信分类来源；取分隔词首字母，单词取前两位。
    static func monogram(for name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        guard let firstWord = words.first else { return "–" }
        let initials = words.count > 1 ? String(words.prefix(2).compactMap(\.first)) : String(firstWord.prefix(2))
        return String(initials.uppercased().prefix(2))
    }

    /// FNV-1a 在重启时保持稳定；排除提交号，避免每次同步仓库后同一个目录变色。
    static func monogramPaletteIndex(for skill: RepoSkill) -> Int {
        let identity = "\(skill.repositoryID):\(skill.directory)"
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(monogramPalette.count))
    }

    static func monogramTint(for skill: RepoSkill) -> Color {
        monogramPalette[monogramPaletteIndex(for: skill)]
    }
}
