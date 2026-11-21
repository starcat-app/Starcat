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

/// 来源、版本与分项结果保留在报告快照中，浏览详情时不需要再读取 Skill 文件。
struct SkillEvaluationReportDetail: View {
    let cached: SkillEvaluationCached
    let sources: [SkillEvaluationSubject: String]
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    private var report: SkillEvaluationRecord { cached.report }

    private var checks: [SkillEvaluationCheck] {
        // 早期快速检查快照没有 harness 分项。只在展示时补一个缺失状态，原报告仍可核对。
        guard report.mode == .quick, !report.checks.contains(where: { $0.id == "harness" }) else {
            return report.checks
        }
        return report.checks + [SkillEvaluationCheck(id: "harness", state: .incomplete, score: nil, details: [])]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("skills.evaluation.report.comparison")
                .font(interfaceScale.font(.rowTitle))
                .accessibilityAddTraits(.isHeader)
            // 相似性报告中的成对编号与快照顺序一致，版本与来源也按同一条目展示。
            ForEach(Array(report.subjects.enumerated()), id: \.element) { index, subject in
                subjectRow(subject, index: index)
            }
            Divider()
            if cached.stale {
                Label("skills.evaluation.state.stale", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            reportField(Text("skills.evaluation.report.status"), Text(SkillEvaluationPanelStatus(report.state).title))
            reportField(Text("skills.evaluation.mode.title"), Text(report.mode.panelTitle))
            reportField(
                Text("skills.evaluation.report.runDate"),
                Text(report.createdAt, format: .dateTime.year().month().day().hour().minute().locale(locale))
            )
            reportField(Text("skills.evaluation.report.toolVersion"), Text(verbatim: report.toolVersion))
            if let model = report.model {
                reportField(Text("skills.evaluation.configuration.endpoint"), Text(verbatim: model.endpoint))
                if !model.chat.isEmpty {
                    reportField(Text("skills.evaluation.configuration.chat"), Text(verbatim: model.chat))
                }
                if let embedding = model.embedding {
                    reportField(Text("skills.evaluation.configuration.embedding"), Text(verbatim: embedding))
                }
            }
            Divider()
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                    if check.id == "harness" {
                        checkDetails(check).padding(10)
                    } else {
                        checkDetails(check).padding(10).listRowSurface(index: index)
                    }
                }
            }
        }
        .font(interfaceScale.font(.body))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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

    private func checkDetails(_ check: SkillEvaluationCheck) -> some View {
        let lines = check.details.map { SkillEvaluationReportLine(checkID: check.id, raw: $0) }
        return VStack(alignment: .leading, spacing: 6) {
            reportField(
                checkTitle(check.id).font(interfaceScale.font(.rowTitle, weight: .semibold)),
                Text(SkillEvaluationPanelStatus(check.state).title).font(interfaceScale.font(.caption))
            )
            .accessibilityAddTraits(.isHeader)
            if let score = check.score {
                reportField(Text("skills.evaluation.report.score"), exactNumber(String(score)))
            }
            if check.id == "harness", !lines.contains(.note(.harnessScope)) {
                reportLine(.note(.harnessScope))
            }
            ForEach(lines.indices, id: \.self) { index in
                reportLine(lines[index])
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
    private func reportLine(_ line: SkillEvaluationReportLine) -> some View {
        switch line {
        case .note(let term):
            Text(LocalizedStringKey(term.rawValue)).foregroundStyle(.secondary)
        case .metric(let term, let value):
            reportField(Text(LocalizedStringKey(term.rawValue)), exactNumber(value))
        case .pair(let first, let second, let score):
            reportField(Text("skills.evaluation.detail.items \(number(first)) \(number(second))"), exactNumber(score))
        case .finding(let label, let severity, let locations):
            VStack(alignment: .leading, spacing: 4) {
                let title = findingTitle(label)
                if let severity {
                    reportField(title, severityTitle(severity))
                } else {
                    title
                }
                ForEach(locations.indices, id: \.self) { index in
                    locationText(locations[index]).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        case .original(let value):
            Text(verbatim: value).foregroundStyle(.secondary)
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
    private func reportField(_ label: Text, _ value: Text) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                value.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                value
            }
        }
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
