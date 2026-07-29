//
//  RepositoryInsightsXMLViewer.swift
//  Starcat
//
//  知识库浏览器中的仓库洞察 XML 只读详情。
//
//  与可编辑 RepoContext 的关键差异：洞察 XML 是结构化缓存投影，用户只能复制、导出、
//  删除或重新生成，不能手改后写回，否则页面 / AI / RAG 会出现三份事实。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metadata
            xmlContent
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
            CopyFeedbackButton(
                providesContent: { artifact.document.xml },
                tooltip: "rag.browser.repositoryInsights.copy"
            ) { didCopy in
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
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

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(verbatim: artifact.document.repositoryFullName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(verbatim: "insights.xml")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            Text(
                verbatim: String(
                    format: String.l10n("rag.browser.chunks.tokenCountFormat"),
                    TokenEstimator.estimate(text: artifact.document.xml)
                )
            )
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var xmlContent: some View {
        ScrollView {
            Text(verbatim: artifact.document.xml)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55))
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("rag.browser.repositoryInsights.available", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            Text(verbatim: "·")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(
                String(
                    format: String.l10n("search.detail.time.updated.format"),
                    RelativeTimeText.pastEvent(artifact.document.generatedAt, locale: locale)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(
                Text(
                    artifact.document.generatedAt,
                    format: .dateTime.year().month().day().hour().minute()
                )
            )
            if let exportErrorMessage {
                Text(exportErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer()
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
