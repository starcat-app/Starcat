//
//  RepositoryUnstarDataChoiceSheet.swift
//  Starcat
//
//  取消 Star 前展示两层数据清理范围，并由用户明确选择是否同时移出知识库。
//

import SwiftUI

/// 解释取消 Star 会删除哪些数据，并在仓库已入库时提供额外的知识库移除选项。
///
/// 不使用系统 Alert：删除范围包含多组用户数据与可重建缓存，需要分区说明；执行期间 Sheet
/// 保持打开并展示错误，避免 GitHub 已取消 Star、但本地清理部分失败时只出现一次短暂抖动。
struct RepositoryUnstarDataChoiceSheet: View {

    private struct DeletionItem: Identifiable {
        let id: String
        let icon: String
        let accent: Color
        let titleKey: LocalizedStringKey
        let detailKey: LocalizedStringKey
    }

    let repositoryFullName: String
    let isInKnowledgeLibrary: Bool
    let onConfirm: (RepositoryUnstarCleanupScope) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let starDataItems = [
        DeletionItem(
            id: "personal",
            icon: "doc.text",
            accent: .blue,
            titleKey: "repo.unstarData.star.personal.title",
            detailKey: "repo.unstarData.star.personal.detail"
        ),
        DeletionItem(
            id: "ai",
            icon: "sparkles",
            accent: .purple,
            titleKey: "repo.unstarData.star.ai.title",
            detailKey: "repo.unstarData.star.ai.detail"
        ),
        DeletionItem(
            id: "analysis",
            icon: "chart.bar.xaxis",
            accent: .green,
            titleKey: "repo.unstarData.star.analysis.title",
            detailKey: "repo.unstarData.star.analysis.detail"
        )
    ]

    private let knowledgeDataItems = [
        DeletionItem(
            id: "sources",
            icon: "books.vertical",
            accent: .orange,
            titleKey: "repo.unstarData.knowledge.sources.title",
            detailKey: "repo.unstarData.knowledge.sources.detail"
        ),
        DeletionItem(
            id: "index",
            icon: "magnifyingglass.circle",
            accent: .cyan,
            titleKey: "repo.unstarData.knowledge.index.title",
            detailKey: "repo.unstarData.knowledge.index.detail"
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Divider()
                .padding(.horizontal, 20)
            footer
        }
        // 单卡确认不占用双卡布局的宽度；已入库时仍为两种清理范围保留并排空间。
        .frame(width: isInKnowledgeLibrary ? 760 : 560)
        .interactiveDismissDisabled(isWorking)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 7) {
                Text("repo.unstarData.title")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(String(
                    format: String.l10n(
                        isInKnowledgeLibrary
                            ? "repo.unstarData.message.library"
                            : "repo.unstarData.message.starOnly"
                    ),
                    repositoryFullName
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            Spacer(minLength: 12)
            SheetCloseButton(action: { dismiss() })
                .disabled(isWorking)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var content: some View {
        VStack(spacing: 12) {
            if isInKnowledgeLibrary {
                HStack(alignment: .top, spacing: 12) {
                    deletionCard(
                        titleKey: "repo.unstarData.star.section",
                        items: starDataItems
                    )
                    deletionCard(
                        titleKey: "repo.unstarData.knowledge.section",
                        items: knowledgeDataItems
                    )
                }
            } else {
                deletionCard(
                    titleKey: "repo.unstarData.star.section",
                    items: starDataItems
                )
            }

            warningBanner
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func deletionCard(
        titleKey: LocalizedStringKey,
        items: [DeletionItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titleKey)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.bottom, 8)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                        .padding(.leading, 46)
                }
                deletionRow(item)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var warningBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .background(Color.orange, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("repo.unstarData.warning.title")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("repo.unstarData.warning.detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 1)
            }
    }

    private func deletionRow(_ item: DeletionItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(item.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.titleKey)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("general.cancel", role: .cancel) {
                dismiss()
            }
            .controlSize(.large)
            .disabled(isWorking)

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if isInKnowledgeLibrary {
                Button("repo.unstarData.confirmStarOnly", role: .destructive) {
                    confirm(.keepKnowledgeLibrary)
                }
                .controlSize(.large)
                .disabled(isWorking)

                Button("repo.unstarData.confirmWithKnowledge", role: .destructive) {
                    confirm(.removeFromKnowledgeLibrary)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(isWorking)
            } else {
                Button("repo.unstarData.unstarOnly", role: .destructive) {
                    confirm(.keepKnowledgeLibrary)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func confirm(_ scope: RepositoryUnstarCleanupScope) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onConfirm(scope)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }
}
