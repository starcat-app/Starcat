//
//  RepoSkillCoverageBanner.swift
//  Starcat
//
//  未完成扫描时明确标注覆盖范围，不把已加载结果数量冒充全网完整结果。
//

import SwiftUI

/// 窄列表允许将操作折到第二行，不能靠缩小文字或挤掉进度适配长语言。
struct RepoSkillCoverageBanner: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    coverage
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 6) {
                    coverage
                    actions
                }
            }
            Text("repo.skills.scan.notice")
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help("repo.skills.scan.notice")
        }
        .font(interfaceScale.font(.captionSmall))
        .foregroundStyle(.secondary)
        .padding(8)
        .background(.bar)
    }

    private var coverage: some View {
        let store = dependencies.repoSkillStore
        return Label(String(format: String.l10n("repo.skills.scan.progress"), store.processedCount, store.candidateCount),
                     systemImage: "shippingbox")
            .monospacedDigit()
            .fixedSize()
    }

    private var actions: some View {
        let store = dependencies.repoSkillStore
        return HStack(spacing: 8) {
            Button(LocalizedStringKey(store.isPaused ? "repo.skills.scan.resume" : "repo.skills.scan.pause")) {
                store.togglePause()
            }
            if store.remainingCount == 0 {
                Button("repo.skills.scan.more") { store.scanNextBatch() }
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}
