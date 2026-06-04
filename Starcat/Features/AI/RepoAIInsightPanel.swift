//
//  RepoAIInsightPanel.swift
//  Starcat
//
//  详情页 AI 摘要面板。
//
//  模块职责：
//  - 在单仓详情页展示结构化 AI 摘要；
//  - 提供生成 / 重新生成入口；
//  - 展示 AI 标签推荐，并让用户逐个或批量确认后才写入本地标签。
//
//  关键约束：
//  - AI 视觉克制：使用系统分组、细分隔线和少量 sparkles，不做整页彩色背景。
//  - 标签推荐按钮是明确命令；未点击前不写数据库。
//  - 本 View 自己创建 VM，但底层依赖仍来自 AppDependencies，避免 RepoDetailView init 继续膨胀。
//

import SwiftUI

struct RepoAIInsightPanel: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel

    @State private var viewModel: RepoAIInsightViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: repo.id) {
            if viewModel == nil {
                let vm = RepoAIInsightViewModel(
                    service: dependencies.repoAIInsightService,
                    tagRepository: dependencies.tagRepository,
                    repoTagRepository: dependencies.repoTagRepository
                )
                vm.onTagsChanged = { [weak homeViewModel] in
                    Task {
                        await homeViewModel?.refreshSidebar()
                        await homeViewModel?.reloadItems()
                    }
                }
                viewModel = vm
            }
            await viewModel?.load(repo: repo)
        }
    }

    @ViewBuilder
    private func content(_ vm: RepoAIInsightViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(vm)

                if let error = vm.errorMessage {
                    errorBanner(error)
                }

                if vm.isLoading {
                    loadingState
                } else if let draft = vm.streamingSummaryText, !draft.isEmpty {
                    streamingSummary(draft, vm: vm)
                } else if let insight = vm.insight {
                    insightContent(insight, vm: vm)
                } else {
                    emptyState(vm)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ vm: RepoAIInsightViewModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Label("AI 摘要", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            if let insight = vm.insight {
                Button {
                    copySummaryToClipboard(insight)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .pressableHover()

                Button {
                    Task { await vm.generate(repo: repo) }
                } label: {
                    if vm.isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(vm.isGenerating)
                .controlSize(.small)
            }
        }
    }

    private func copySummaryToClipboard(_ insight: RepoAIInsight) {
        var content = ""
        if !insight.oneLiner.isEmpty {
            content += "**一句话总结**\n\(insight.oneLiner)\n\n"
        }
        if !insight.summary.isEmpty {
            content += "**摘要**\n\(insight.summary)\n\n"
        }
        if !insight.platforms.isEmpty {
            content += "**平台/生态**\n\(insight.platforms.joined(separator: ", "))\n\n"
        }
        if !insight.suitableFor.isEmpty {
            content += "**适用场景**\n\(insight.suitableFor.map { "• \($0)" }.joined(separator: "\n"))\n\n"
        }
        if !insight.strengths.isEmpty {
            content += "**优点**\n\(insight.strengths.map { "• \($0)" }.joined(separator: "\n"))\n\n"
        }
        if !insight.risks.isEmpty {
            content += "**风险/注意点**\n\(insight.risks.map { "• \($0)" }.joined(separator: "\n"))\n\n"
        }
        if let example = insight.minimalExample, !example.isEmpty {
            content += "**最小示例**\n\(example)"
        }

        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        #endif
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在读取本地 AI 缓存…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private func emptyState(_ vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("尚未生成 AI 摘要")
                .font(.title3.weight(.semibold))
            Text("将读取 repo 元数据、README、topics，并生成摘要、适用场景、优缺点、风险和推荐标签。")
                .foregroundStyle(.secondary)
            Button {
                Task { await vm.generate(repo: repo) }
            } label: {
                if vm.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("生成摘要", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.isGenerating)
            Text("预计消耗 1 次 AI Chat 调用；标签不会自动写入，需你确认。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 40)
    }

    private func insightContent(_ insight: RepoAIInsight, vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryText(insight.summaryMarkdown ?? insight.summary)
            tagSuggestions(insight.suggestedTags, vm: vm)
            if let tagError = vm.tagErrorMessage {
                tagErrorBanner(tagError)
            }
            footer(insight)
        }
    }

    private func streamingSummary(_ text: String, vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成 AI 摘要…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            summaryText(text)
            Divider()
            Label("推荐标签正在并行解析，完成后会出现在下方。", systemImage: "tag")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryText(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI 摘要")
                .font(.subheadline.weight(.semibold))
            RepoAISummaryMarkdownView(markdown: text)
        }
    }

    private func section(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(items.filter { !$0.isEmpty }, id: \.self) { item in
                Text("• \(item)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func chips(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        Text(value)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private func codeSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最小示例")
                .font(.subheadline.weight(.semibold))
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func tagSuggestions(_ tags: [AITagSuggestion], vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("推荐标签")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("全部应用") {
                    Task { await vm.applyAllTags(repo: repo) }
                }
                .disabled(tags.isEmpty || tags.allSatisfy { vm.appliedTagNames.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) })
                .controlSize(.small)
            }

            if tags.isEmpty {
                Text("暂无推荐标签。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tags) { tag in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tag.name)
                                .font(.body.weight(.medium))
                            Text(tag.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int((max(0, min(tag.confidence, 1)) * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button(vm.appliedTagNames.contains(tag.name.trimmingCharacters(in: .whitespacesAndNewlines)) ? "已应用" : "应用") {
                            Task { await vm.applyTag(tag, repo: repo) }
                        }
                        .disabled(vm.appliedTagNames.contains(tag.name.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private func footer(_ insight: RepoAIInsight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
            Text("由 \(insight.model) 生成 · \(formattedDate(insight.generatedAt))")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tagErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.slash")
            Text("推荐标签解析失败：\(message)")
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter.shared.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
