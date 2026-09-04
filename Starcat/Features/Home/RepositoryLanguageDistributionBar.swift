//
//  RepositoryLanguageDistributionBar.swift
//  Starcat
//
//  Manage 详情 Hero 中的响应式语言占比分割线。
//

import SwiftUI

/// 将语言占比画成随详情栏宽度变化的整行分割线；文字只通过 hover tooltip 与辅助功能暴露。
struct RepositoryLanguageDistributionBar: View {
    let repo: Repo
    let onLanguageTapped: (String) -> Void

    @State private var viewModel: RepositoryLanguageDistributionViewModel

    init(
        repo: Repo,
        service: any RepositoryLanguageServing,
        onLanguageTapped: @escaping (String) -> Void
    ) {
        self.repo = repo
        self.onLanguageTapped = onLanguageTapped
        _viewModel = State(
            initialValue: RepositoryLanguageDistributionViewModel(service: service)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            if viewModel.segments.isEmpty {
                // Loading、空数据和失败共用一条中性线，Hero 高度从首帧起保持稳定。
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            } else {
                HStack(spacing: 0) {
                    ForEach(viewModel.segments) { segment in
                        segmentView(segment)
                            // 总宽度只来自父容器 proposal；窗口缩放时每段按占比即时重算。
                            .frame(width: proxy.size.width * segment.fraction)
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 6)
        .task(id: repo.id) {
            await viewModel.load(
                repoID: repo.id,
                owner: repo.owner,
                name: repo.name
            )
        }
    }

    @ViewBuilder
    private func segmentView(
        _ segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> some View {
        let title = segment.language ?? String.l10n("sidebar.languages.other")
        let tooltip = "\(title) · \(segment.fraction.formatted(.percent.precision(.fractionLength(1))))"

        if let language = segment.language {
            Button {
                onLanguageTapped(language)
            } label: {
                Rectangle()
                    .fill(LanguageColor.color(for: language))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(verbatim: tooltip))
            .accessibilityLabel(Text(verbatim: tooltip))
        } else {
            // Other 是多个语言的聚合，无法映射到单个主语言筛选，因此只展示说明、不响应点击。
            Rectangle()
                .fill(Color.secondary.opacity(0.45))
                .help(Text(verbatim: tooltip))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: tooltip))
        }
    }
}
