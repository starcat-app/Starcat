//
//  TagTaxonomyBootstrapView.swift
//  Starcat
//
//  首次标签体系与增量扩词共用的确认工作台。
//
//  该视图嵌入 BatchAIWorkspaceView 的固定尺寸窗口：左侧选择/改名候选标签，右侧展示
//  来源与样例仓库。确认前只改内存状态；持久化与进入逐仓审核由 HomeView 回调统一执行。
//

import Observation
import SwiftUI

@MainActor
@Observable
final class TagTaxonomyBootstrapReviewModel {
    let session: TagTaxonomyBootstrapSession
    var candidates: [TagTaxonomyCandidate]
    var selectedCandidateIDs: Set<String>
    var focusedCandidateID: String?
    var operationError: String?

    init(session: TagTaxonomyBootstrapSession) {
        self.session = session
        self.candidates = session.candidates
        self.selectedCandidateIDs = session.defaultSelectedCandidateIDs
        self.focusedCandidateID = session.candidates.first(where: {
            session.defaultSelectedCandidateIDs.contains($0.id)
        })?.id ?? session.candidates.first?.id
    }

    var focusedCandidate: TagTaxonomyCandidate? {
        guard let focusedCandidateID else { return nil }
        return candidates.first { $0.id == focusedCandidateID }
    }

    var selectedCandidates: [TagTaxonomyCandidate] {
        candidates.filter { selectedCandidateIDs.contains($0.id) }
    }

    var selectedCount: Int { selectedCandidateIDs.count }

    var targetCoverageCount: Int {
        session.targetCoverage(selectedCandidateIDs: selectedCandidateIDs)
    }

    var hasValidSelection: Bool {
        guard !selectedCandidates.isEmpty else { return false }
        let normalizedNames = selectedCandidates.map {
            AITagSuggestionPolicy.normalizedDisplayName($0.name)
        }
        guard normalizedNames.allSatisfy({ !$0.isEmpty }) else { return false }
        let canonicalNames = normalizedNames.map(AITagSuggestionPolicy.canonicalKey)
        return canonicalNames.allSatisfy { !$0.isEmpty }
            && Set(canonicalNames).count == canonicalNames.count
            && targetCoverageCount > 0
    }

    func toggleCandidate(_ candidateID: String) {
        operationError = nil
        if selectedCandidateIDs.contains(candidateID) {
            selectedCandidateIDs.remove(candidateID)
        } else {
            selectedCandidateIDs.insert(candidateID)
        }
        focusedCandidateID = candidateID
    }

    func updateName(_ name: String, candidateID: String) {
        guard let index = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        candidates[index].name = name
        operationError = nil
    }
}

struct TagTaxonomyBootstrapView: View {
    @Bindable var model: TagTaxonomyBootstrapReviewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards
            HStack(alignment: .top, spacing: AIOrganizationLayout.gap) {
                candidatePanel
                evidencePanel
            }
            .frame(width: AIOrganizationLayout.innerWidth, height: AIOrganizationLayout.panelHeight, alignment: .top)
        }
        .padding(AIOrganizationLayout.padding)
        .frame(width: AIOrganizationLayout.windowSize.width, height: AIOrganizationLayout.contentHeight, alignment: .topLeading)
    }

    private var summaryCards: some View {
        HStack(spacing: 8) {
            summaryCard(
                title: String.l10n(primaryRepositoryMetricKey),
                value: model.session.corpusRepositoryCount.formatted(.number.locale(locale)),
                icon: "shippingbox",
                tint: .purple
            )
            summaryCard(
                title: String.l10n(secondaryMetricKey),
                value: secondaryMetricValue.formatted(.number.locale(locale)),
                icon: model.session.kind == .bootstrap ? "doc.text" : "sparkles",
                tint: .orange
            )
            summaryCard(
                title: String.l10n("batchAI.taxonomy.metric.selected"),
                value: model.selectedCount.formatted(.number.locale(locale)),
                icon: "tag",
                tint: .blue
            )
            summaryCard(
                title: String.l10n("batchAI.taxonomy.metric.coverage"),
                value: coverageText,
                icon: "scope",
                tint: .green
            )
        }
        .frame(width: AIOrganizationLayout.innerWidth, height: AIOrganizationLayout.summaryHeight)
    }

    private func summaryCard(title: String, value: String, icon: String, tint: Color) -> some View {
        AIOrganizationSummaryCard(title: title, value: value, symbol: icon, tint: tint)
    }

    private var candidatePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidateTitleKey)
                        .font(interfaceScale.font(.body, weight: .semibold))
                    Text(candidateSubtitleKey)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(verbatim: "\(model.selectedCount)/\(model.candidates.count)")
                    .font(interfaceScale.font(.captionStrong).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            if model.candidates.isEmpty {
                ContentUnavailableView(
                    "batchAI.taxonomy.empty.title",
                    systemImage: "tag.slash",
                    description: Text("batchAI.taxonomy.empty.message")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
            }
        }
        .padding(10)
        // 保留候选区稍宽的比例；首次引导和扩词同样必须装入缩小后的工作区。
        .frame(width: 460, height: AIOrganizationLayout.panelHeight, alignment: .topLeading)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private func candidateRow(_ candidate: TagTaxonomyCandidate) -> some View {
        let isSelected = model.selectedCandidateIDs.contains(candidate.id)
        let isFocused = model.focusedCandidateID == candidate.id

        return HStack(spacing: 8) {
            Button {
                model.toggleCandidate(candidate.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(isSelected ? "batchAI.taxonomy.candidate.deselect" : "batchAI.taxonomy.candidate.select")

            TextField(
                "batchAI.taxonomy.candidate.placeholder",
                text: Binding(
                    get: {
                        model.candidates.first(where: { $0.id == candidate.id })?.name ?? candidate.name
                    },
                    set: { model.updateName($0, candidateID: candidate.id) }
                )
            )
            .textFieldStyle(.plain)
            .font(interfaceScale.font(.body).weight(.semibold))
            .foregroundStyle(isSelected ? .primary : .secondary)

            Text(
                verbatim: String(
                    format: String.l10n("batchAI.taxonomy.supportFormat"),
                    locale: locale,
                    candidate.supportCount
                )
            )
            .font(interfaceScale.font(.caption).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Button {
                model.focusedCandidateID = candidate.id
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("batchAI.taxonomy.evidence.title")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            isFocused ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.focusedCandidateID = candidate.id }
    }

    @ViewBuilder
    private var evidencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("batchAI.taxonomy.evidence.title")
                .font(interfaceScale.font(.body, weight: .semibold))
            if let candidate = model.focusedCandidate {
                Text(verbatim: candidate.name)
                    .font(interfaceScale.font(.panelTitle))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ForEach(orderedSignals(candidate.signals), id: \.self) { signal in
                        Text(signalTitleKey(signal))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06),
                                in: Capsule()
                            )
                    }
                }

                Divider()

                evidenceFact(
                    title: "batchAI.taxonomy.evidence.globalSupport",
                    value: candidate.supportCount
                )
                evidenceFact(
                    title: "batchAI.taxonomy.evidence.targetSupport",
                    value: candidate.targetSupportCount
                )

                Text("batchAI.taxonomy.evidence.samples")
                    .font(interfaceScale.font(.captionStrong))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(candidate.sampleRepositoryNames, id: \.self) { fullName in
                            Label {
                                Text(verbatim: fullName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "shippingbox")
                            }
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "batchAI.taxonomy.evidence.empty",
                    systemImage: "info.circle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: AIOrganizationLayout.innerWidth - 460 - AIOrganizationLayout.gap,
               height: AIOrganizationLayout.panelHeight, alignment: .topLeading)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private func evidenceFact(title: LocalizedStringKey, value: Int) -> some View {
        HStack {
            Text(title)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value, format: .number.locale(locale))
                .font(interfaceScale.font(.captionStrong).monospacedDigit())
        }
    }

    private var coverageText: String {
        "\(model.targetCoverageCount)/\(model.session.targetRepositories.count)"
    }

    private var primaryRepositoryMetricKey: String {
        model.session.kind == .bootstrap
            ? "batchAI.taxonomy.metric.corpus"
            : "batchAI.expansion.metric.uncovered"
    }

    private var secondaryMetricKey: String {
        model.session.kind == .bootstrap
            ? "batchAI.taxonomy.metric.readme"
            : "batchAI.expansion.metric.candidates"
    }

    private var secondaryMetricValue: Int {
        model.session.kind == .bootstrap
            ? model.session.cachedReadmeCount
            : model.session.candidates.count
    }

    private var candidateTitleKey: LocalizedStringKey {
        model.session.kind == .bootstrap
            ? "batchAI.taxonomy.candidates.title"
            : "batchAI.expansion.candidates.title"
    }

    private var candidateSubtitleKey: LocalizedStringKey {
        model.session.kind == .bootstrap
            ? "batchAI.taxonomy.candidates.subtitle"
            : "batchAI.expansion.candidates.subtitle"
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
                    : Color(nsColor: .controlBackgroundColor)
            )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.85 : 0.45))
    }

    private func orderedSignals(_ signals: Set<TagTaxonomySignalKind>) -> [TagTaxonomySignalKind] {
        TagTaxonomySignalKind.allCases.filter(signals.contains)
    }

    private func signalTitleKey(_ signal: TagTaxonomySignalKind) -> LocalizedStringKey {
        switch signal {
        case .topic: "batchAI.taxonomy.signal.topic"
        case .language: "batchAI.taxonomy.signal.language"
        case .description: "batchAI.taxonomy.signal.description"
        case .readme: "batchAI.taxonomy.signal.readme"
        case .llm: "batchAI.expansion.signal.llm"
        }
    }
}
