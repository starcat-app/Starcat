//
//  RepoSkillFilterSection.swift
//  Starcat
//
//  Skill 四态筛选和按需补查进度。状态来自共享服务，不再保留演示条件。
//

import SwiftUI

struct RepoSkillFilterSection: View {
    @Binding var selection: RepoSkillFilter
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let store = dependencies.repoSkillStore
        VStack(alignment: .leading, spacing: 6) {
            Label("repo.skills.filter.title", systemImage: "shippingbox")
                .foregroundStyle(.secondary)
            Picker("repo.skills.filter.title", selection: $selection) {
                ForEach(RepoSkillFilter.allCases, id: \.self) { filter in
                    // 先构造 String，避免 LocalizedStringKey 将插值解释成带 %@ 的格式模板。
                    let key = "repo.skills.filter.\(filter.rawValue)"
                    Text(LocalizedStringKey(key)).tag(filter)
                }
            }
            .labelsHidden()
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
}
