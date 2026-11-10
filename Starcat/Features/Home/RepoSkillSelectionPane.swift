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
    @State private var filter = Filter.all
    @State private var search = ""

    private enum Filter: CaseIterable {
        case all, pending, installed
        func key(isExport: Bool) -> String {
            switch self {
            case .all: "repo.skills.list.all"
            case .pending: isExport ? "repo.skills.list.toExport" : "repo.skills.list.pending"
            case .installed: isExport ? "repo.skills.install.exported" : "repo.skills.list.installed"
            }
        }
    }

    private var visibleSkills: [RepoSkill] {
        session.skills.filter { skill in
            guard search.isEmpty || skill.name.localizedCaseInsensitiveContains(search)
                || skill.summary.localizedCaseInsensitiveContains(search)
                || skill.directory.localizedCaseInsensitiveContains(search) else { return false }
            return switch filter {
            case .all: true
            case .pending: !session.installedIDs.contains(skill.id)
            case .installed: session.installedIDs.contains(skill.id)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                CountedSegmentedControl(
                    items: Filter.allCases, selection: $filter, totalCount: session.skills.count,
                    title: { LocalizedStringKey($0.key(isExport: session.isExport)) },
                    count: count,
                    accessibilityLabel: "repo.skills.preview.selection"
                )
                Picker("repo.skills.preview.selection", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { option in
                        Text(LocalizedStringKey(option.key(isExport: session.isExport))).tag(option)
                    }
                }
                .labelsHidden()
            }
            .padding(12)
            searchField
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleSkills.enumerated()), id: \.element.id) { index, skill in
                        skillRow(skill, rowIndex: index)
                    }
                    if visibleSkills.isEmpty {
                        Label("repo.skills.list.empty", systemImage: "shippingbox")
                            .font(interfaceScale.font(.body))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 42)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

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
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(interfaceScale.font(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("repo.skills.search", text: $search)
                .textFieldStyle(.plain)
                .font(interfaceScale.font(.body))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func count(_ filter: Filter) -> Int {
        switch filter {
        case .all: session.skills.count
        case .pending: session.skills.filter { !session.installedIDs.contains($0.id) }.count
        case .installed: session.skills.filter { session.installedIDs.contains($0.id) }.count
        }
    }

    /// checkbox 只修改安装集合；右侧整块按钮只切换预览，避免误选和误取消。
    private func skillRow(_ skill: RepoSkill, rowIndex: Int) -> some View {
        SkillRow(
            skill: skill,
            rowIndex: rowIndex,
            session: session,
            isPreviewSelected: previewID == skill.id
        ) { previewID = $0 }
    }

}

/// 紧凑单行列表：名称保持唯一可见内容，路径只进入 tooltip 和无障碍说明。
private struct SkillRow: View {
    let skill: RepoSkill
    let rowIndex: Int
    let session: RepoSkillSession
    let isPreviewSelected: Bool
    let selectPreview: (String) -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isHovered = false

    private var isInstalled: Bool { session.installedIDs.contains(skill.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(
                get: { session.selectedIDs.contains(skill.id) },
                set: { _ in session.toggleSelection(skill.id) }
            )) {
                Text(verbatim: skill.name)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(session.isInstalling || isInstalled || skill.installationIssue != nil)

            Button {
                selectPreview(skill.id)
            } label: {
                HStack(spacing: 5) {
                    Text(verbatim: skill.name)
                        .font(interfaceScale.font(.bodyEmphasis, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .help(LocalizedStringKey(session.isExport ? "repo.skills.install.exported" : "repo.skills.install.installed"))
                    } else if session.coverage(of: skill.id) > 0 {
                        Text(verbatim: "\(session.coverage(of: skill.id))/\(session.selectedDestinations.count)")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityAddTraits(isPreviewSelected ? .isSelected : [])
        }
        .padding(.horizontal, 10)
        .frame(height: interfaceScale.scaled(32))
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            RepoSkillRowChrome.background(rowIndex: rowIndex, isSelected: isPreviewSelected, isHovered: isHovered),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isPreviewSelected ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .help(skill.summary + "\n" + skill.manifestPath)
    }
}

/// 独立抽出行底色，保证斑马纹、悬停与选中的优先级可用单元测试固定。
enum RepoSkillRowChrome {
    /// 选中 > 悬停 > 斑马纹；避免悬停时破坏当前预览行的语义。
    static func background(rowIndex: Int, isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            Color.accentColor.opacity(0.14)
        } else if isHovered {
            Color.accentColor.opacity(0.08)
        } else {
            rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
        }
    }
}
