//
//  RepositoryInsightsXMLViewer.swift
//  Starcat
//
//  知识库浏览器中的仓库洞察 XML 只读详情。
//
//  布局与 `KnowledgeRAGChunkEditor` 的 RepoContext 详情对齐：标题 / 章节路径 /
//  分片内容框 + 底栏时间·tokens；洞察 XML 是结构化缓存投影，只读不可手改写回。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RepositoryInsightsXMLExport {
    static func defaultFilename(repositoryFullName: String) -> String {
        let components = repositoryFullName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .filter { !$0.isEmpty }
        let prefix = components.isEmpty ? "repository" : components.joined(separator: "-")
        return "\(prefix)-insights.xml"
    }

    static func write(_ xml: String, to url: URL) throws {
        try Data(xml.utf8).write(to: url, options: .atomic)
    }
}

struct RepositoryInsightsXMLViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let artifact: RepositoryInsightsContextArtifact
    @State private var exportErrorMessage: String?

    /// 与列表行同源：按当前 XML 估算，避免再引入未持久化的 token 字段。
    private var tokenCount: Int {
        TokenEstimator.estimate(text: artifact.document.xml)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.titleLabel").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "rag.browser.chunk.title",
                    text: .constant(String.l10n("rag.browser.repositoryInsights.title"))
                )
                .disabled(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.sectionLabel").font(.caption).foregroundStyle(.secondary)
                TextField(
                    "rag.browser.chunk.section",
                    text: .constant(RepositoryInsightsDocument.fileName)
                )
                .disabled(true)
            }

            // 正文区吃掉标题/路径之外的剩余高度，长 XML 才能在固定窗高内滚动。
            VStack(alignment: .leading, spacing: 4) {
                Text("rag.browser.chunk.contentLabel").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(verbatim: artifact.document.xml)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, minHeight: 250, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55))
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(18)
        .frame(
            width: interfaceScale.scaled(680),
            height: interfaceScale.scaled(540),
            alignment: .topLeading
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("rag.browser.repositoryInsights.title")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                export()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("rag.browser.repositoryInsights.download")
            .accessibilityLabel(Text("rag.browser.repositoryInsights.download"))
            SheetCloseButton(action: { dismiss() })
        }
    }

    /// 左下角与 RepoContext / 普通分片同款：可用态 + 更新时间 · tokens。
    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("rag.browser.repositoryInsights.available", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)

                HStack(spacing: 6) {
                    Text(
                        String(
                            format: String.l10n("search.detail.time.updated.format"),
                            RelativeTimeText.pastEvent(artifact.document.generatedAt, locale: locale)
                        )
                    )
                    .help(
                        Text(
                            artifact.document.generatedAt,
                            format: .dateTime.year().month().day().hour().minute()
                        )
                    )
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Text(
                        verbatim: String(
                            format: String.l10n("rag.browser.chunks.tokenCountFormat"),
                            tokenCount
                        )
                    )
                    .font(.caption.monospaced())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let exportErrorMessage {
                    Text(exportErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = RepositoryInsightsXMLExport.defaultFilename(
            repositoryFullName: artifact.document.repositoryFullName
        )
        panel.title = String.l10n("rag.browser.repositoryInsights.download.panelTitle")
        panel.prompt = String.l10n("rag.browser.repositoryInsights.download.action")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RepositoryInsightsXMLExport.write(artifact.document.xml, to: url)
            exportErrorMessage = nil
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}
