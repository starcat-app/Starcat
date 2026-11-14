//
//  RepoSkillFilterSection.swift
//  Starcat
//
//  Skill 四态筛选和按需补查进度。短标签与图标自适应同一行，状态来自共享服务。
//

import SwiftUI

/// 标题独占一行，四态分段切换共用现有筛选绑定与补查进度。
struct RepoSkillFilterSection: View {
    @Binding var selection: RepoSkillFilter
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let store = dependencies.repoSkillStore
        VStack(alignment: .leading, spacing: 4) {
            Label("repo.skills.filter.title", systemImage: "shippingbox")
                .foregroundStyle(.secondary)
            RepoFilterTabs(
                label: "repo.skills.filter.title",
                options: RepoSkillFilter.allCases,
                selection: $selection,
                title: { filter in
                    let key = "repo.skills.filter.\(filter.rawValue)"
                    return LocalizedStringKey(key)
                },
                shortTitle: { filter in
                    let key = "repo.skills.filter.short.\(filter.rawValue)"
                    return LocalizedStringKey(key)
                },
                symbol: filterSymbol,
                color: filterColor
            )
            if selection != .any {
                Text("repo.skills.scan.resultsHint")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(String(format: String.l10n("repo.skills.scan.progress"), store.processedCount, store.candidateCount))
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(LocalizedStringKey(store.isPaused ? "repo.skills.scan.resume" : "repo.skills.scan.pause")) {
                        store.togglePause()
                    }
                    .font(interfaceScale.font(.captionSmall))
                }
                if store.remainingCount == 0, store.processedCount < store.candidateCount {
                    Button("repo.skills.scan.more") { store.scanNextBatch() }
                        .font(interfaceScale.font(.captionSmall))
                }
            }
        }
    }

    /// 图标形状独立表达四种状态，避免窄宽模式只能靠颜色辨认。
    private func filterSymbol(for filter: RepoSkillFilter) -> String {
        switch filter {
        case .any: "square.grid.2x2"
        case .contains: "checkmark.circle.fill"
        case .absent: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// 按产品要求仅在图标模式使用状态色，选中状态另由强调色底与描边表达。
    private func filterColor(for filter: RepoSkillFilter) -> Color {
        switch filter {
        case .any: .blue
        case .contains: .green
        case .absent: .secondary
        case .unknown: .orange
        }
    }
}
