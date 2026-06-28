//
//  RepoRecommendationPopover.swift
//  Starcat
//
//  相似仓库推荐列表弹层。
//

import SwiftUI

struct RepoRecommendationPopover: View {
    let items: [RepoRecommendationItem]
    let hasMore: Bool
    let isLoadingMore: Bool
    let errorMessage: String?
    let onOpen: (RepoRecommendationItem) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        RepoRecommendationCard(item: item) {
                            onOpen(item)
                        }
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    if hasMore {
                        Button {
                            onLoadMore()
                        } label: {
                            HStack(spacing: 6) {
                                if isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.75)
                                }
                                Text(LocalizedStringKey(isLoadingMore ? "repo.recommendations.loadingMore" : "repo.recommendations.more"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoadingMore)
                        .padding(.top, 4)
                    }
                }
                .padding(12)
            }
            .frame(width: 400, height: 500)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("repo.recommendations.title")
                .font(.headline)
            Spacer()
            Text(String(format: String.l10n("repo.recommendations.countFormat"), items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RepoRecommendationCard: View {
    let item: RepoRecommendationItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.fullName)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text(String(format: "%.2f", item.score))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let description = item.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 8) {
                    if let language = item.language, !language.isEmpty {
                        Label(language, systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    Label("\(item.stars)", systemImage: "star")
                    Label("\(item.forks)", systemImage: "tuningfork")
                    if item.archived {
                        Label("repo.recommendations.archived", systemImage: "archivebox")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
    }
}
