//
//  SkillEvaluationReportDetail.swift
//  Starcat
//
//  展示评估报告中的分项、兼容矩阵和证据，使用报告快照与当前 App 语言。
//

import SwiftUI

/// 筛选和列表共享同一优先级，过期报告仍保留原始结论供详情查看。
enum SkillEvaluationPanelStatus: CaseIterable, Hashable {
    case all, notRun, stale, findings, passed, incomplete

    init(_ cached: SkillEvaluationCached?) {
        guard let cached else { self = .notRun; return }
        self = cached.stale ? .stale : Self(cached.report.state)
    }

    init(_ state: SkillEvaluationState) {
        switch state {
        case .findings: self = .findings
        case .passed: self = .passed
        case .incomplete: self = .incomplete
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .all: "skills.evaluation.filter.all"
        case .notRun: "skills.evaluation.state.notRun"
        case .stale: "skills.evaluation.state.stale"
        case .findings: "skills.evaluation.state.findings"
        case .passed: "skills.evaluation.state.passed"
        case .incomplete: "skills.evaluation.state.incomplete"
        }
    }
}

extension SkillEvaluationMode {
    var panelSymbol: String {
        switch self {
        case .quick: "checklist"
        case .security: "shield.lefthalf.filled"
        case .rubric: "star.bubble"
        case .context: "doc.on.doc"
        case .similarity: "square.stack"
        }
    }

    var panelTitle: LocalizedStringKey {
        switch self {
        case .quick: "skills.evaluation.mode.quick"
        case .security: "skills.evaluation.mode.security"
        case .rubric: "skills.evaluation.mode.rubric"
        case .context: "skills.evaluation.mode.context"
        case .similarity: "skills.evaluation.mode.similarity"
        }
    }

    var consentScope: LocalizedStringKey {
        switch self {
        case .rubric: "skills.evaluation.consent.rubric"
        case .context: "skills.evaluation.consent.context"
        case .similarity: "skills.evaluation.consent.similarity"
        case .quick, .security: "skills.evaluation.consent.scope"
        }
    }
}

/// 评估列表与详情使用相同的文字和图形，颜色只补充状态。
struct SkillEvaluationStatusBadge: View {
    let status: SkillEvaluationPanelStatus
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    private var appearance: (symbol: String, color: Color) {
        switch status {
        case .passed: ("checkmark.circle.fill", .green)
        case .findings: ("exclamationmark.circle.fill", .orange)
        case .incomplete: ("exclamationmark.circle", .orange)
        case .stale: ("clock.badge.exclamationmark", .orange)
        case .all, .notRun: ("circle", .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: appearance.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(status.title)
                .foregroundStyle(.primary)
        }
        .font(interfaceScale.font(.caption, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(appearance.color.opacity(0.12), in: Capsule())
    }
}

extension View {
    /// 复用 Skills 安装面板的表面，保持评估卡片与承载底色的明度差。
    func skillEvaluationCard(_ colorScheme: ColorScheme) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(RepoSkillPanelStyle.panelColor(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.10))
                    .allowsHitTesting(false)
            }
    }
}

/// 确认页和报告都可核对完整地址。确认页的模型选择保持在可见区域。
struct SkillEvaluationConnectionDetails: View {
    let modelEndpoint: String
    var chat: String?
    var embedding: String?
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        let title = Text("skills.evaluation.configuration.connectionDetails")
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                connectionField("skills.evaluation.configuration.endpoint", modelEndpoint)
                if let chat, !chat.isEmpty { connectionField("skills.evaluation.configuration.chat", chat) }
                if let embedding { connectionField("skills.evaluation.configuration.embedding", embedding) }
            }
            .textSelection(.enabled)
        } label: {
            title.font(interfaceScale.font(.body, weight: .semibold))
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: title))
    }

    private func connectionField(_ title: LocalizedStringKey, _ value: String) -> some View {
        SkillEvaluationDetailField(
            label: Text(title).foregroundStyle(.secondary),
            value: Text(verbatim: value).font(interfaceScale.font(.code))
        )
    }
}

/// 窄栏或长译文可以纵排。诊断字段保留完整文本供选中和复制。
struct SkillEvaluationDetailField<Value: View>: View {
    let label: Text
    let value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                value.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                label
                value
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 来源、版本与分项结果保留在报告快照中，浏览详情时不需要再读取 Skill 文件。
struct SkillEvaluationReportDetail: View {
    let cached: SkillEvaluationCached
    let sources: [SkillEvaluationSubject: String]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var expandedQuickChecks: Set<String> = ["harness"]

    private var report: SkillEvaluationRecord { cached.report }

    private var checks: [SkillEvaluationCheck] {
        // 早期快速检查快照没有 harness 分项。只在展示时补一个缺失状态，原报告仍可核对。
        guard report.mode == .quick, !report.checks.contains(where: { $0.id == "harness" }) else {
            return report.checks
        }
        return report.checks + [SkillEvaluationCheck(id: "harness", state: .incomplete, score: nil, details: [])]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            ForEach(checks, id: \.id) { check in
                if report.mode == .quick {
                    quickSection(check)
                } else {
                    reportSection(check)
                }
            }
            if report.mode == .similarity {
                let title = Text("skills.evaluation.report.comparison")
                DisclosureGroup {
                    ForEach(Array(report.subjects.enumerated()), id: \.element) { index, subject in
                        subjectRow(subject, index: index)
                            .padding(8)
                            .listRowSurface(index: index)
                    }
                } label: {
                    title.font(interfaceScale.font(.body, weight: .semibold))
                }
                .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: title))
                .padding(12)
                .skillEvaluationCard(colorScheme)
            }
            runDetails
            if report.mode.requiresAI, let model = report.model {
                SkillEvaluationConnectionDetails(modelEndpoint: model.endpoint, chat: model.chat, embedding: model.embedding)
                    .padding(12)
                    .skillEvaluationCard(colorScheme)
            }
        }
        .font(interfaceScale.font(.body))
        .textSelection(.enabled)
    }

    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                summarySubject.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                summaryResult.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                summarySubject
                summaryResult
            }
        }
        .padding(16)
        .skillEvaluationCard(colorScheme)
    }

    private var summarySubject: some View {
        let title = report.mode == .similarity
            ? Text(report.mode.panelTitle) : report.names.first.map { Text(verbatim: $0) } ?? Text(report.mode.panelTitle)
        return VStack(alignment: .leading, spacing: 5) {
            Text(report.mode == .similarity ? "skills.evaluation.report.comparison" : report.mode.panelTitle)
                .font(interfaceScale.font(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            title
                .font(interfaceScale.font(.workspaceTitle))
                .accessibilityAddTraits(.isHeader)
            if report.mode != .similarity, let subject = report.subjects.first, let source = sources[subject] {
                Text(verbatim: source)
                    .font(interfaceScale.font(.code))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(source)
            }
            Text(report.createdAt, format: .dateTime.year().month().day().hour().minute().locale(locale))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var summaryResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let metric = SkillEvaluationHeadlineMetric(report) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(metric.titleKey))
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                    exactNumber(metric.value)
                        .font(interfaceScale.font(.workspaceTitle))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            SkillEvaluationStatusBadge(status: SkillEvaluationPanelStatus(report.state))
            if cached.stale { SkillEvaluationStatusBadge(status: .stale) }
        }
    }

    private var runDetails: some View {
        let title = Text("skills.evaluation.report.runDetails")
        return DisclosureGroup {
            reportField(Text("skills.evaluation.report.toolVersion"), Text(verbatim: report.toolVersion))
            if report.mode != .similarity, let version = report.versions.first {
                reportField(Text("skills.evaluation.report.versions"), Text(verbatim: version).font(interfaceScale.font(.code)))
            }
        } label: {
            title.font(interfaceScale.font(.body, weight: .semibold))
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: title))
        .padding(12)
        .skillEvaluationCard(colorScheme)
    }

    private func subjectRow(_ subject: SkillEvaluationSubject, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if report.mode == .similarity { Text(verbatim: number(index + 1)).fixedSize() }
                if report.names.indices.contains(index) { Text(verbatim: report.names[index]) }
            }
            if let source = sources[subject] {
                Text(verbatim: source).foregroundStyle(.secondary)
            }
            if report.versions.indices.contains(index) {
                reportField(
                    Text("skills.evaluation.report.versions"),
                    Text(verbatim: report.versions[index]).font(interfaceScale.font(.code))
                )
            }
        }
    }

    private func quickSection(_ check: SkillEvaluationCheck) -> some View {
        let title = checkTitle(check.id)
        let status = SkillEvaluationPanelStatus(check.state)
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedQuickChecks.contains(check.id) },
            set: { expanded in
                if expanded { expandedQuickChecks.insert(check.id) }
                else { expandedQuickChecks.remove(check.id) }
            }
        )) {
            if let score = check.score {
                reportField(Text("skills.evaluation.report.score"), exactNumber("\(score)/100"))
            }
            evidence(check)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    title.fixedSize()
                    Spacer(minLength: 0)
                    SkillEvaluationStatusBadge(status: status).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    SkillEvaluationStatusBadge(status: status)
                }
            }
            .font(interfaceScale.font(.rowTitle, weight: .semibold))
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: title, accessibilityHint: Text(status.title)))
        .padding(12)
        .skillEvaluationCard(colorScheme)
    }

    private func reportSection(_ check: SkillEvaluationCheck) -> some View {
        let title: LocalizedStringKey = switch check.id {
        case "rubric": "skills.evaluation.report.criteria"
        case "security": "skills.evaluation.report.scanResults"
        case "context-optimization": "skills.evaluation.detail.duplicateContent"
        case "similarity": "skills.evaluation.report.overlapPairs"
        default: report.mode.panelTitle
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(interfaceScale.font(.rowTitle, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            evidence(check)
        }
        .padding(12)
        .skillEvaluationCard(colorScheme)
    }

    private func evidence(_ check: SkillEvaluationCheck) -> some View {
        let lines = check.details.map { SkillEvaluationReportLine(checkID: check.id, raw: $0) }
        let showBars = check.id == "quality" || check.id == "rubric"
        return VStack(alignment: .leading, spacing: 4) {
            if check.state == .passed && ["security", "context-optimization", "similarity"].contains(check.id) {
                Text("skills.evaluation.detail.noFindings")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            if check.id == "harness", !lines.contains(.note(.harnessScope)) {
                reportLine(.note(.harnessScope), showBars: false)
            }
            ForEach(lines.indices, id: \.self) { index in
                reportLine(lines[index], showBars: showBars)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .listRowSurface(index: index)
            }
            if check.id == "harness" {
                harnessMatrix(check.harnessProfiles)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 每行保持 Agent、结论与规则相邻。沿用报告容器的滚动、文本选择和详情过渡。
    private func harnessMatrix(_ profiles: [SkillEvaluationHarnessProfile]?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(SkillEvaluationHarnessRow.rows(for: profiles).enumerated()), id: \.element.id) { index, row in
                VStack(alignment: .leading, spacing: 4) {
                    let agent = row.agent.map { Text(verbatim: $0.name) }
                        ?? Text("skills.evaluation.harness.unknownAgent \(row.id)")
                    reportField(agent.font(interfaceScale.font(.body, weight: .semibold)), harnessStatus(row.status))
                    if !row.rules.isEmpty {
                        reportField(
                            Text("skills.evaluation.harness.rules"),
                            Text(verbatim: row.rules.joined(separator: ", ")).font(interfaceScale.font(.code))
                        )
                    } else if case .reported = row.status {
                        Text("skills.evaluation.harness.noRules").foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(8)
                .listRowSurface(index: index)
            }
        }
    }

    private func harnessStatus(_ status: SkillEvaluationHarnessRow.Status) -> Text {
        switch status {
        case .reported(.loads): Text("skills.evaluation.harness.loads")
        case .reported(.degraded): Text("skills.evaluation.harness.degraded")
        case .reported(.notLoaded): Text("skills.evaluation.harness.notLoaded")
        case .missing: Text("skills.evaluation.harness.missing")
        case .unknown: Text("skills.evaluation.harness.unknown")
        }
    }

    @ViewBuilder
    private func reportLine(_ line: SkillEvaluationReportLine, showBars: Bool) -> some View {
        switch line {
        case .note(let term):
            Text(LocalizedStringKey(term.rawValue))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .metric(let term, let value):
            let label = Text(LocalizedStringKey(term.rawValue))
            if showBars, let fraction = ratingFraction(value) {
                ratingRow(label, value: value, fraction: fraction)
            } else {
                reportField(label, exactNumber(value).monospacedDigit())
            }
        case .pair(let first, let second, let score):
            pairRow(first: first, second: second, score: score)
        case .finding(let label, let severity, let locations):
            VStack(alignment: .leading, spacing: 4) {
                let title = findingTitle(label).font(interfaceScale.font(.body, weight: .semibold))
                if let severity {
                    reportField(title, severityTitle(severity)
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(severityColor(severity).opacity(0.12), in: Capsule()))
                } else {
                    title
                }
                ForEach(locations.indices, id: \.self) { index in
                    locationText(locations[index])
                        .font(interfaceScale.font(.code))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case .original(let value):
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ratingFraction(_ value: String) -> Double? {
        let parts = value.split(separator: "/")
        guard parts.count == 2, let score = Double(parts[0]), let maximum = Double(parts[1]),
              maximum > 0, (0...maximum).contains(score) else { return nil }
        return score / maximum
    }

    private func ratingRow(_ label: Text, value: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            reportField(label, exactNumber(value).monospacedDigit())
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.secondary)
                            .frame(width: geometry.size.width * fraction)
                    }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    /// 同名 Skill 仍可用序号追溯到报告中的版本和来源，不用当前列表的排序猜配对。
    private func pairRow(first: Int, second: Int, score: String) -> some View {
        let ordinals = Text("skills.evaluation.detail.items \(number(first)) \(number(second))")
        let names = report.names
        let hasNames = names.indices.contains(first - 1) && names.indices.contains(second - 1)
        let title = hasNames
            ? Text(verbatim: "\(names[first - 1]) ↔ \(names[second - 1])") : ordinals
        return VStack(alignment: .leading, spacing: 4) {
            reportField(title.font(interfaceScale.font(.body, weight: .semibold)), exactNumber(score).monospacedDigit())
            if hasNames {
                ordinals.font(interfaceScale.font(.caption)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func severityColor(_ severity: SkillEvaluationReportLine.Severity) -> Color {
        switch severity {
        case .critical, .high: .red
        case .medium: .orange
        case .low, .info: .secondary
        }
    }

    private func findingTitle(_ label: SkillEvaluationReportLine.FindingLabel) -> Text {
        switch label {
        case .term(let term): Text(LocalizedStringKey(term.rawValue))
        case .rule(let code): Text(verbatim: code).font(interfaceScale.font(.code))
        }
    }

    private func severityTitle(_ severity: SkillEvaluationReportLine.Severity) -> Text {
        switch severity {
        case .critical: Text("insights.repo.securityAdvisory.severity.critical")
        case .high: Text("insights.repo.securityAdvisory.severity.high")
        case .medium: Text("insights.repo.securityAdvisory.severity.medium")
        case .low: Text("insights.repo.securityAdvisory.severity.low")
        case .info: Text("skills.evaluation.detail.information")
        }
    }

    private func locationText(_ location: SkillEvaluationReportLine.Location) -> Text {
        let file: Text = switch location.file {
        case .manifest: Text(verbatim: "SKILL.md")
        case .attachment(let index): Text("skills.evaluation.detail.attachment \(number(index))")
        }
        guard let line = location.line else { return file }
        return Text("skills.evaluation.detail.fileLine \(file) \(number(line))")
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.never).locale(locale))
    }

    private func exactNumber(_ value: String) -> Text {
        // 展示小数分隔符，保留 Parser 报告的全部有效位与分母。
        Text(verbatim: value.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? "."))
    }

    /// 紧凑栏宽、界面放大或长译文下改用纵排，避免截断模型标识、状态和规则号。
    private func reportField<Value: View>(_ label: Text, _ value: Value) -> some View {
        SkillEvaluationDetailField(label: label, value: value)
    }

    private func checkTitle(_ id: String) -> Text {
        switch id {
        case "schema": Text("skills.evaluation.check.schema")
        case "quality": Text("skills.evaluation.check.quality")
        case "harness": Text("skills.evaluation.check.harness")
        case "security": Text("skills.evaluation.mode.security")
        case "rubric": Text("skills.evaluation.mode.rubric")
        case "context-optimization": Text("skills.evaluation.mode.context")
        case "similarity": Text("skills.evaluation.mode.similarity")
        default: Text(verbatim: id)
        }
    }
}
