//
//  TrendingView.swift
//  Starcat
//
//  GitHub Trending 页面视图。
//
//  功能：
//  - 日/周/月榜切换
//  - 按语言筛选
//  - 展示 Trending 仓库列表
//  - 显示 AI 摘要按钮
//  - 显示 AI 评分
//  - 显示个性化推荐区块
//  - 支持一键订阅到 Stars
//
//  设计约束：
//  - 使用 SwiftUI
//  - 遵循项目 UI 规范（focus ring 等）
//

import SwiftUI

struct TrendingView: View {

    @State private var viewModel: TrendingViewModel

    init(repository: any TrendingRepositoryProtocol) {
        _viewModel = State(initialValue: TrendingViewModel(repository: repository))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            toolbarView

            Divider()

            // 主要内容
            if viewModel.isLoading && viewModel.repos.isEmpty {
                loadingView
            } else if let error = viewModel.loadError, viewModel.repos.isEmpty {
                errorView(message: error)
            } else {
                contentView
            }
        }
        .task {
            await viewModel.reload()
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 16) {
            // 时间周期切换
            periodPicker

            Spacer()

            // 语言筛选
            languagePicker
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(TrendingPeriod.allCases) { period in
                Button {
                    viewModel.selectedPeriod = period
                } label: {
                    Text(period.displayName)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedPeriod == period
                                ? Color.accentColor
                                : Color.clear
                        )
                        .foregroundStyle(
                            viewModel.selectedPeriod == period
                                ? Color.white
                                : Color.primary
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
    }

    private var languagePicker: some View {
        Menu {
            ForEach(TrendingLanguage.allCases) { lang in
                Button {
                    viewModel.selectedLanguage = lang
                } label: {
                    HStack {
                        Text(lang.displayName)
                        if viewModel.selectedLanguage == lang {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedLanguage.displayName)
                    .font(.subheadline)
                Image(systemName: "chevron.down")
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Content

    private var contentView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // 个性化推荐区块
                if !viewModel.userLanguagePreferences.isEmpty {
                    personalizedSection
                }

                // Trending 列表
                ForEach(viewModel.repos) { repo in
                    TrendingRepoCard(
                        repo: repo,
                        score: viewModel.score(for: repo),
                        summary: viewModel.summaryCache[repo.fullName],
                        isSummarizing: viewModel.summarizingRepoIDs.contains(repo.fullName),
                        onSubscribe: {
                            Task {
                                try? await viewModel.subscribe(repo: repo)
                            }
                        },
                        onRequestSummary: {
                            Task {
                                await viewModel.requestSummary(for: repo)
                            }
                        }
                    )
                }
            }
            .padding(16)
        }
        .refreshable {
            await viewModel.reload()
        }
    }

    private var personalizedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                Text("为你推荐")
                    .font(.headline)
                Spacer()
            }

            Text("基于你的收藏偏好精选")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("加载中...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("加载失败")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("重试") {
                Task {
                    await viewModel.reload()
                }
            }
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - TrendingRepoCard

/// Trending 仓库卡片
struct TrendingRepoCard: View {

    let repo: TrendingRepo
    let score: TrendingScore
    let summary: String?
    let isSummarizing: Bool
    let onSubscribe: () -> Void
    let onRequestSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部：名称 + 语言
            headerView

            // 描述
            if let desc = repo.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // 统计信息
            statsView

            // AI 评分
            scoreView

            // 摘要（如果已生成）
            if let summary {
                summaryView(summary)
            }

            // 操作按钮
            actionButtons
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.headline)

                Text(repo.owner)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let lang = repo.language {
                HStack(spacing: 4) {
                    Circle()
                        .fill(languageColor(for: lang))
                        .frame(width: 8, height: 8)
                    Text(lang)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.quaternaryLabelColor))
                .clipShape(Capsule())
            }
        }
    }

    private var statsView: some View {
        HStack(spacing: 16) {
            // Stars
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.orange)
                Text("\(repo.starsCount)")
                    .font(.caption)
                    .monospacedDigit()
            }

            // Forks
            HStack(spacing: 4) {
                Image(systemName: "tuningfork")
                    .foregroundStyle(.secondary)
                Text("\(repo.forksCount)")
                    .font(.caption)
                    .monospacedDigit()
            }

            // 周期增长
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.green)
                Text(repo.periodText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 贡献者头像
            if !repo.contributors.isEmpty {
                HStack(spacing: -6) {
                    ForEach(repo.contributors.prefix(5)) { contributor in
                        AsyncImage(url: contributor.avatarURL) { image in
                            image
                                .resizable()
                                .scaledToFit()
                        } placeholder: {
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                        }
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1)
                        )
                    }

                    if repo.contributors.count > 5 {
                        Text("+\(repo.contributors.count - 5)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var scoreView: some View {
        HStack(spacing: 8) {
            // AI 评分
            HStack(spacing: 4) {
                Text("AI 评分")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(score.total)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(scoreColor)

                Text(score.level.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(scoreColor.opacity(0.2))
                    .foregroundStyle(scoreColor)
                    .clipShape(Capsule())
            }

            Spacer()

            // GitHub 链接
            Link(destination: repo.url) {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                    Text("查看")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    private func summaryView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.purple)
                Text("AI 摘要")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // AI 摘要按钮
            Button {
                onRequestSummary()
            } label: {
                HStack(spacing: 4) {
                    if isSummarizing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "text.bubble")
                    }
                    Text(summary != nil ? "重新摘要" : "AI 摘要")
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .focusEffectDisabled()
            .disabled(isSummarizing)

            // 订阅按钮
            Button {
                onSubscribe()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "star")
                    Text("订阅")
                }
                .font(.caption)
            }
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
        }
    }

    private var scoreColor: Color {
        switch score.level {
        case .excellent: return .green
        case .good: return .blue
        case .average: return .orange
        case .low: return .gray
        }
    }

    private func languageColor(for language: String) -> Color {
        // 常用语言颜色映射
        switch language.lowercased() {
        case "swift": return .red
        case "python": return .blue
        case "typescript", "javascript": return .yellow
        case "go": return .cyan
        case "rust": return .orange
        case "java": return .brown
        case "kotlin": return .purple
        case "dart": return .teal
        default: return .gray
        }
    }
}
