//
//  AgentKnowledgeAuditView.swift
//  Starcat
//
//  Knowledge retrieval 审计的共享展示组件。
//
//  Timeline 展开区与 Inspector 必须读取同一份持久化 audit，避免实时运行与历史回放
//  出现两套口径。组件只展示脱敏计数、来源和限制，不渲染分片正文。
//

import SwiftUI

struct AgentKnowledgeAuditView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let audit: AgentKnowledgeRetrievalAudit
    var showsTitle = true

    private var metrics: AgentKnowledgeAuditMetrics { audit.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Label("agent.workspace.knowledgeAudit.title", systemImage: "text.magnifyingglass")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                metricCard("agent.workspace.knowledgeAudit.candidates", value: metrics.candidateCount)
                metricCard("agent.workspace.knowledgeAudit.keywordHits", value: metrics.keywordHitCount)
                metricCard("agent.workspace.knowledgeAudit.semanticHits", value: metrics.semanticHitCount)
                metricCard("agent.workspace.knowledgeAudit.evidence", value: metrics.finalEvidenceCount)
            }

            VStack(alignment: .leading, spacing: 7) {
                auditRow(
                    title: String.l10n("agent.workspace.knowledgeAudit.scopeMode"),
                    value: scopeModeTitle
                )
                auditRow(
                    title: String.l10n("agent.workspace.knowledgeAudit.frozenRepositories"),
                    value: "\(audit.frozenRepoIDs.count)"
                )
                if !audit.explicitRepoIDs.isEmpty {
                    auditRow(
                        title: String.l10n("agent.workspace.knowledgeAudit.explicitRepositories"),
                        value: "\(audit.explicitRepoIDs.count)"
                    )
                }
            }

            if let diagnostics = audit.diagnostics {
                auditSection(
                    title: String.l10n("agent.workspace.knowledgeAudit.outcome"),
                    icon: "checkmark.seal",
                    content: diagnostics.debugPayload()
                )
            }

            if !audit.citations.isEmpty {
                citationSection
            }

            if !audit.limitations.isEmpty {
                auditSection(
                    title: String.l10n("agent.workspace.knowledgeAudit.limitations"),
                    icon: "exclamationmark.triangle",
                    content: audit.limitations.map(localizedLimitation).joined(separator: "\n")
                )
            }
        }
    }

    private func metricCard(_ titleKey: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value, format: .number)
                .font(interfaceScale.font(.rowTitle, weight: .semibold))
                .foregroundStyle(.primary)
            Text(titleKey)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func auditRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func auditSection(title: String, icon: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(content)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var citationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("agent.workspace.timeline.sources", systemImage: "link")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(audit.citations) { citation in
                citationRow(citation)
            }
        }
    }

    @ViewBuilder
    private func citationRow(_ citation: AgentKnowledgeCitationAudit) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text("[\(citation.marker)] \(citation.repoFullName) / \(citation.sectionTitle)")
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(citation.source) · \(citation.hitKind) · \(citation.score, format: .number.precision(.fractionLength(3)))")
                .font(interfaceScale.font(.captionSmall, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let sourceURL = citation.sourceURL, let url = URL(string: sourceURL) {
            Link(destination: url) {
                HStack(spacing: 6) {
                    content
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            content
        }
    }

    private var scopeModeTitle: String {
        switch audit.scopeMode {
        case .only: return String.l10n("rag.workspace.repoMode.only")
        case .prefer: return String.l10n("rag.workspace.repoMode.prefer")
        case .exclude: return String.l10n("rag.workspace.repoMode.exclude")
        }
    }

    private func localizedLimitation(_ limitation: String) -> String {
        switch limitation {
        case "No relevant indexed evidence was found in the provided repository scope.":
            String.l10n("agent.workspace.knowledgeAudit.limitation.noEvidence")
        case "Some matched chunks were omitted by the knowledge evidence budget.":
            String.l10n("agent.workspace.knowledgeAudit.limitation.evidenceBudget")
        case "Vector retrieval was unavailable; keyword retrieval remained active.":
            String.l10n("agent.workspace.knowledgeAudit.limitation.vectorUnavailable")
        case "Keyword retrieval was unavailable; vector retrieval remained active.":
            String.l10n("agent.workspace.knowledgeAudit.limitation.keywordUnavailable")
        default:
            limitation
        }
    }
}
