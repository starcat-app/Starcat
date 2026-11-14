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
        LanguageDistributionBar(
            segments: viewModel.segments,
            onLanguageTapped: onLanguageTapped
        )
        // 同一仓库内刷新共享分段；换仓库时重建纯展示状态，立即清掉旧 hover。
        .id(repo.id)
        .task(id: repo.id) {
            await viewModel.load(
                repoID: repo.id,
                owner: repo.owner,
                name: repo.name
            )
        }
    }
}
