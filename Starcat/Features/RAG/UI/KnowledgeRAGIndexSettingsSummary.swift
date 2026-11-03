//
//  KnowledgeRAGIndexSettingsSummary.swift
//  Starcat
//
//  检索设置与索引管理共用真实索引摘要。读取数据库覆盖率不触发索引构建；
//  重建和停止仅出现在管理页，并继续调用原索引器入口。
//

import SwiftUI

/// 共享状态投影，防止检索页和管理页对同一轮构建给出不同的统计含义。
struct KnowledgeRAGIndexSettingsSummary: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale
    let showsControls: Bool

    @State private var coverage: RAGIndexStatusProjection?
    @State private var coverageError: String?
    @State private var refreshRevision = 0
    @State private var confirmsRebuild = false

    var body: some View {
        Group {
            if showsControls {
                managementContent
            } else {
                retrievalSummary
            }
        }
        .task(id: refreshRevision) { await refreshCoverage() }
        .onChange(of: dependencies.knowledgeRAGIndexBuilder.status) { _, _ in
            refreshRevision += 1
        }
        .onChange(of: settings.resolvedAITask(settings.aiEmbeddingTask, type: .embedding).resolvedModelName) { _, _ in
            refreshRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .knowledgeRAGIndexDidChange)) { _ in
            refreshRevision += 1
        }
        .sheet(isPresented: $confirmsRebuild) {
            IndexRebuildConfirmationSheet(kind: .knowledge) {
                guard !dependencies.knowledgeRAGIndexBuilder.status.isActivelyIndexing else { return }
                dependencies.knowledgeRAGIndexBuilder.startRebuild()
            }
            .appLocaleEnvironment()
        }
    }

    /// 检索页保留紧凑只读摘要，构建操作只在索引管理页出现。
    private var retrievalSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(indexStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let coverage {
                Text(String(
                    format: String.l10n("settings.retrieval.index.coverage"),
                    locale: locale,
                    Int64(coverage.indexedRepoCount), Int64(coverage.knowledgeRepoCount), Int64(coverage.readyChunks)
                ))
            }
            // 摘要页将管理入口与向量状态并排，长备注允许换行，按钮保持原生尺寸。
            HStack(alignment: .center, spacing: 8) {
                if let coverage {
                    Text(String(
                        format: String.l10n("settings.retrieval.index.issues"),
                        locale: locale,
                        Int64(coverage.pendingChunks), Int64(coverage.failedChunks), Int64(coverage.staleChunks)
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                } else if let coverageError {
                    Text("settings.retrieval.index.loadFailed")
                        .help(coverageError)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
                Button("settings.retrieval.index.manage") {
                    NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "ai.knowledgeIndex")
                }
                .fixedSize()
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// 文本可检索数量与向量异常各自展示；二者可能重叠，不能相加为完成率。
    private var managementContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.searchIndex.layout.knowledgeHeader")
                        .font(.callout.weight(.medium))
                    Text(indexStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IndexSettingsStatusBadge(status: SearchIndexStatus.knowledge(
                    status: dependencies.knowledgeRAGIndexBuilder.status,
                    coverage: coverage,
                    hasModel: (try? settings.resolveEmbeddingSelection()) != nil
                ))
            }
            if let progress = buildProgress {
                ProgressView(value: Double(progress.processed), total: Double(max(1, progress.total)))
                    .accessibilityLabel(Text(indexStatusText))
            }
            if let coverage {
                HStack(alignment: .top, spacing: 20) {
                    IndexSettingsMetric(
                        value: coverage.indexedRepoCount, total: coverage.knowledgeRepoCount,
                        unit: "settings.searchIndex.layout.repoUnit",
                        caption: "settings.searchIndex.layout.knowledgeRepos"
                    )
                    Divider().frame(height: 56)
                    IndexSettingsMetric(
                        value: coverage.readyChunks,
                        unit: "settings.searchIndex.layout.chunkUnit",
                        caption: "settings.searchIndex.layout.knowledgeText"
                    )
                }
                .padding(.vertical, 4)
                Divider()
                HStack(spacing: 16) {
                    vectorCount("settings.searchIndex.layout.vectorPending", value: coverage.pendingChunks)
                    vectorCount("settings.searchIndex.layout.vectorFailed", value: coverage.failedChunks)
                    vectorCount("settings.searchIndex.layout.vectorStale", value: coverage.staleChunks)
                    Spacer(minLength: 0)
                }
            } else if let coverageError {
                Text("settings.retrieval.index.loadFailed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(coverageError)
            } else {
                ProgressView().controlSize(.small)
            }
            Divider()
            HStack(alignment: .center, spacing: 8) {
                Text("settings.searchIndex.layout.buildHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if dependencies.knowledgeRAGIndexBuilder.status.isActivelyIndexing {
                    Button("settings.searchIndex.knowledge.stop") {
                        dependencies.knowledgeRAGIndexBuilder.cancel()
                    }
                } else {
                    Button("settings.searchIndex.layout.rebuild") {
                        confirmsRebuild = true
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.vertical, 4)
    }

    /// 标签与计数分开着色，长语言可以换行，不能挤掉真实异常数量。
    private func vectorCount(_ title: LocalizedStringKey, value: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number.locale(locale))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }

    /// 各阶段使用自身计数单位，切换阶段时不把仓库数延续为分片数。
    private var buildProgress: (processed: Int, total: Int)? {
        switch dependencies.knowledgeRAGIndexBuilder.status {
        case let .fetchingReadmes(processed, total), let .building(processed, total):
            return (min(max(0, processed), max(0, total)), total)
        case .embedding:
            guard let progress = dependencies.knowledgeRAGIndexBuilder.status.embeddingProgress else { return nil }
            return (progress.processedChunks, progress.totalChunks)
        default:
            return nil
        }
    }

    /// 状态计数沿用索引器语义；FTS 可检索片段不冒充当前模型的向量覆盖率。
    private var indexStatusText: String {
        switch dependencies.knowledgeRAGIndexBuilder.status {
        case .idle:
            return String.l10n("settings.rag.index.idle")
        case .fetchingReadmes(let processed, let total):
            return String(format: String.l10n("settings.rag.index.readmesFormat"), locale: locale, processed, total)
        case .building(let processed, let total):
            return String(format: String.l10n("settings.rag.index.reposFormat"), locale: locale, processed, total)
        case .embedding(let processed, let total):
            return String(format: String.l10n("settings.rag.index.chunksFormat"), locale: locale, processed, total)
        case .completed(let coverage):
            return String(format: String.l10n("settings.rag.index.readyFormat"), locale: locale, coverage.readyChunks)
        case .failed(let message):
            return message
        }
    }

    /// 视图离开或新一轮刷新会取消旧读取，避免过期快照覆盖更新后的数据库统计。
    @MainActor
    private func refreshCoverage() async {
        do {
            let snapshot = try await dependencies.knowledgeRAGIndexBuilder.coverage()
            guard !Task.isCancelled else { return }
            coverage = snapshot
            coverageError = nil
        } catch {
            guard !Task.isCancelled else { return }
            coverageError = error.localizedDescription
            coverage = nil
        }
    }
}
