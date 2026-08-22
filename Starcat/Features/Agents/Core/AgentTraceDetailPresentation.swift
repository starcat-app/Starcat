//
//  AgentTraceDetailPresentation.swift
//  Starcat
//
//  把不同 Agent Runtime 的 Trace 明细转换为稳定、可扫描的结构化展示。
//
//  持久化层继续保存经过裁剪的 Provider 原文，避免为每一种 Runtime 建一套数据库
//  schema；本层只做确定性解析，不调用模型猜测字段语义。无法可靠识别的数据始终回退
//  到原文，因此历史 Run 也能立即获得结构化展示而无需迁移。
//

import Foundation
import MarkdownUI
import SwiftUI

struct AgentTraceDetailPresentation: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        let label: String
        let content: Content
    }

    enum Content: Equatable, Sendable {
        case text(String)
        case markdown(String)
        case code(String)
        case error(String)
        case structured(AgentTraceStructuredValue)
    }

    let sections: [Section]
    /// 只有发生结构化转换时才提供原文入口；普通文本不重复展示两次。
    let rawPayload: String?
}

struct AgentTraceStructuredField: Equatable, Sendable {
    let key: String
    let value: AgentTraceStructuredValue
}

/// Trace 的完整事实仍由持久化层保存；这里仅限制时间线首屏需要参与 SwiftUI 测量的内容量。
/// Runtime 返回的大段 Markdown、压缩 JSON 或上百行表格若直接进入嵌套 ScrollView，会让
/// 展开动画期间的 `sizeThatFits` 在主线程反复遍历整棵视图树，最终表现为应用卡死。
enum AgentTracePresentationBudget {
    static let textCharacters = 8_000
    static let codeCharacters = 12_000
    static let rawPayloadCharacters = 20_000
    static let jsonParseCharacters = 256_000
    static let objectFields = 40
    static let collectionItems = 50
    static let nestingDepth = 8

    static var truncationMarker: String {
        "\n\n… \(String.l10n("agent.workspace.trace.contentTruncated"))"
    }

    static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + truncationMarker
    }
}

/// Trace 持久化继续使用 Runtime/工具的稳定标识；展示层按当前 App 语言给已知工具换成
/// 可读标题。未知工具保持原名，避免第三方 Runtime 的新事件被错误翻译。
enum AgentTraceTitlePresentation {
    private static let toolTitleKeys: [String: String] = [
        "agent_parse_goal": "agent.workspace.trace.tool.agentParseGoal",
        "context_resolve_repos": "agent.workspace.trace.tool.contextResolveRepos",
        "repo_cluster_topics": "agent.workspace.trace.tool.repoClusterTopics",
        "knowledge_search": "agent.workspace.trace.tool.knowledgeSearch",
        "external_search": "agent.workspace.trace.tool.externalSearch",
        "artifact_build_weekly_report": "agent.workspace.trace.tool.buildWeeklyReport",
        "agent_parse_repo_insight_goal": "agent.workspace.trace.tool.parseRepoInsightGoal",
        "context_select_repo": "agent.workspace.trace.tool.contextSelectRepo",
        "artifact_build_repo_insight": "agent.workspace.trace.tool.buildRepoInsight",
        "agent_parse_repo_alternatives_goal": "agent.workspace.trace.tool.parseRepoAlternativesGoal",
        "artifact_build_repo_alternatives": "agent.workspace.trace.tool.buildRepoAlternatives",
        "tag_inspect_untagged": "agent.workspace.trace.tool.inspectUntagged",
        "tag_preview_untagged": "agent.workspace.trace.tool.previewUntagged",
        "tag_apply_untagged": "agent.workspace.trace.tool.applyUntagged",
    ]

    static func title(for event: AgentTraceEvent) -> String {
        // 固定类别按当前 App 语言即时解析，避免历史 Trace 把生成时的英文标题永久写死。
        switch event.kind {
        case .message:
            return String.l10n("agent.workspace.trace.kind.message")
        case .plan:
            return String.l10n("agent.workspace.trace.kind.plan")
        case .todo:
            return String.l10n("agent.workspace.trace.kind.todo")
        case .request:
            return String.l10n("agent.workspace.trace.kind.request")
        case .reasoningSummary:
            return String.l10n("agent.workspace.trace.kind.thinking")
        case .commentary:
            return String.l10n("agent.workspace.trace.kind.commentary")
        case .fileChange:
            return String.l10n("agent.workspace.trace.kind.fileChanges")
        case .webSearch:
            return String.l10n("agent.workspace.trace.kind.webSearch")
        case .warning:
            return String.l10n("agent.workspace.trace.kind.warning")
        case .compaction:
            return String.l10n("agent.workspace.trace.kind.contextCompaction")
        default:
            break
        }

        guard event.kind == .tool, let key = toolTitleKeys[event.title] else {
            return event.title
        }
        return String.l10n(key)
    }
}

enum AgentTraceRowPresentation {
    /// 展开区已经包含同一摘要时，主行只保留标题，避免用户连续看到两份相同文本。
    static func shouldShowSummary(for event: AgentTraceEvent, isExpanded: Bool) -> Bool {
        guard isExpanded, let summary = event.summary else { return true }
        return !event.details.contains { detail in
            detail.value.trimmingCharacters(in: .whitespacesAndNewlines)
                == summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

indirect enum AgentTraceStructuredValue: Equatable, Sendable {
    case scalar(String)
    case object([AgentTraceStructuredField])
    case list([AgentTraceStructuredValue])
    case table(columns: [String], rows: [[String]])
}

enum AgentTraceDetailPresentationBuilder {
    private static let toolResultEnvelopeKeys: Set<String> = [
        "status", "summary", "detail", "output", "log", "sources",
    ]

    static func make(event: AgentTraceEvent) -> AgentTraceDetailPresentation {
        var sections: [AgentTraceDetailPresentation.Section] = []
        var rawBlocks: [String] = []
        var didStructure = false

        let displayTitle = AgentTraceTitlePresentation.title(for: event)
        if event.kind == .tool, displayTitle != event.title {
            sections.append(.init(
                label: String.l10n("agent.workspace.trace.toolID"),
                content: .code(event.title)
            ))
        }

        for detail in event.details {
            let boundedRawValue = AgentTracePresentationBudget.bounded(
                detail.value,
                limit: AgentTracePresentationBudget.rawPayloadCharacters
            )
            rawBlocks.append("\(detail.label)\n\(boundedRawValue)")
            if detail.format == .json,
               let json = decodeJSON(detail.value),
               let envelope = toolResultEnvelope(
                    json,
                    eventSummary: event.summary
               ) {
                sections.append(contentsOf: envelope)
                didStructure = true
                continue
            }

            let result = content(for: detail)
            sections.append(.init(label: detail.label, content: result.content))
            didStructure = didStructure || result.didStructure
        }

        return AgentTraceDetailPresentation(
            sections: sections,
            rawPayload: didStructure
                ? AgentTracePresentationBudget.bounded(
                    rawBlocks.joined(separator: "\n\n"),
                    limit: AgentTracePresentationBudget.rawPayloadCharacters
                )
                : nil
        )
    }

    /// Starcat dynamic tool 的结果是稳定 envelope。先拆出摘要、业务输出、日志与来源，
    /// 再对内部文本做严格格式识别，避免用户看到 JSON 包着多行文本的双重序列化结果。
    private static func toolResultEnvelope(
        _ value: AgentJSONValue,
        eventSummary: String?
    ) -> [AgentTraceDetailPresentation.Section]? {
        guard let object = value.objectValue,
              !toolResultEnvelopeKeys.isDisjoint(with: object.keys)
        else { return nil }

        var sections: [AgentTraceDetailPresentation.Section] = []
        var emittedText: Set<String> = []

        if let summary = object["summary"]?.stringValue?.traceNonBlank,
           summary != eventSummary?.traceNonBlank {
            sections.append(.init(
                label: String.l10n("agent.workspace.trace.summary"),
                content: .text(summary)
            ))
            emittedText.insert(summary)
        }

        appendEnvelopeText(
            object["detail"]?.stringValue,
            label: String.l10n("agent.workspace.trace.detail"),
            to: &sections,
            emittedText: &emittedText
        )
        appendEnvelopeText(
            object["output"]?.stringValue,
            label: String.l10n("agent.workspace.trace.output"),
            to: &sections,
            emittedText: &emittedText
        )

        if let log = object["log"]?.stringValue?.traceNonBlank {
            sections.append(.init(
                label: String.l10n("agent.workspace.trace.log"),
                content: .code(log)
            ))
        }
        if let sources = object["sources"]?.externalArray, !sources.isEmpty {
            sections.append(.init(
                label: String.l10n("agent.workspace.trace.sources"),
                content: .structured(structuredValue(from: .array(sources)))
            ))
        }

        return sections.isEmpty ? nil : sections
    }

    private static func appendEnvelopeText(
        _ value: String?,
        label: String,
        to sections: inout [AgentTraceDetailPresentation.Section],
        emittedText: inout Set<String>
    ) {
        guard let value = value?.traceNonBlank, emittedText.insert(value).inserted else { return }
        sections.append(.init(label: label, content: content(fromText: value)))
    }

    private static func content(
        for detail: AgentTraceDetail
    ) -> (content: AgentTraceDetailPresentation.Content, didStructure: Bool) {
        switch detail.format {
        case .json:
            guard detail.value.count <= AgentTracePresentationBudget.jsonParseCharacters else {
                return (.code(AgentTracePresentationBudget.bounded(
                    detail.value,
                    limit: AgentTracePresentationBudget.codeCharacters
                )), false)
            }
            guard let json = decodeJSON(detail.value) else {
                return (.code(AgentTracePresentationBudget.bounded(
                    detail.value,
                    limit: AgentTracePresentationBudget.codeCharacters
                )), false)
            }
            return (.structured(structuredValue(from: json)), true)
        case .code:
            return (.code(AgentTracePresentationBudget.bounded(
                detail.value,
                limit: AgentTracePresentationBudget.codeCharacters
            )), false)
        case .markdown:
            return (.markdown(AgentTracePresentationBudget.bounded(
                detail.value,
                limit: AgentTracePresentationBudget.textCharacters
            )), false)
        case .error:
            return (.error(AgentTracePresentationBudget.bounded(
                detail.value,
                limit: AgentTracePresentationBudget.textCharacters
            )), false)
        case .text:
            if detail.value.count <= AgentTracePresentationBudget.jsonParseCharacters,
               let json = decodeJSON(detail.value) {
                return (.structured(structuredValue(from: json)), true)
            }
            if let fields = keyValueFields(from: detail.value) {
                return (.structured(.object(fields)), true)
            }
            return (.text(AgentTracePresentationBudget.bounded(
                detail.value,
                limit: AgentTracePresentationBudget.textCharacters
            )), false)
        }
    }

    private static func content(fromText text: String) -> AgentTraceDetailPresentation.Content {
        if let json = decodeJSON(text) {
            return .structured(structuredValue(from: json))
        }
        if let fields = keyValueFields(from: text) {
            return .structured(.object(fields))
        }
        return .text(text)
    }

    private static func decodeJSON(_ text: String) -> AgentJSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentJSONValue.self, from: data)
    }

    private static func structuredValue(
        from value: AgentJSONValue,
        depth: Int = 0
    ) -> AgentTraceStructuredValue {
        guard depth < AgentTracePresentationBudget.nestingDepth else {
            return .scalar(String.l10n("agent.workspace.trace.contentTruncated"))
        }

        switch value {
        case .object(let object):
            let keys = Array(object.keys.sorted().prefix(AgentTracePresentationBudget.objectFields))
            var fields = keys.map { key in
                AgentTraceStructuredField(
                    key: key,
                    value: structuredValue(from: object[key] ?? .null, depth: depth + 1)
                )
            }
            if object.count > keys.count {
                fields.append(.init(
                    key: "…",
                    value: .scalar(String.l10n("agent.workspace.trace.contentTruncated"))
                ))
            }
            return .object(fields)
        case .array(let values):
            if let table = table(from: values) { return table }
            var items = values.prefix(AgentTracePresentationBudget.collectionItems).map {
                structuredValue(from: $0, depth: depth + 1)
            }
            if values.count > items.count {
                items.append(.scalar(String.l10n("agent.workspace.trace.contentTruncated")))
            }
            return .list(Array(items))
        case .string(let text):
            if text.count <= AgentTracePresentationBudget.jsonParseCharacters,
               let nested = decodeJSON(text) {
                return structuredValue(from: nested, depth: depth + 1)
            }
            if let fields = keyValueFields(from: text) {
                return .object(fields)
            }
            return .scalar(AgentTracePresentationBudget.bounded(
                text,
                limit: AgentTracePresentationBudget.textCharacters
            ))
        case .number(let number):
            return .scalar(numberText(number))
        case .bool(let value):
            return .scalar(value ? "true" : "false")
        case .null:
            return .scalar("null")
        }
    }

    private static func table(from values: [AgentJSONValue]) -> AgentTraceStructuredValue? {
        guard values.count > 1 else { return nil }
        let objects = values.compactMap(\.objectValue)
        guard objects.count == values.count else { return nil }
        let columns = Array(Set(objects.flatMap(\.keys))).sorted()
        guard !columns.isEmpty, columns.count <= 8 else { return nil }

        var rows: [[String]] = []
        for object in objects.prefix(AgentTracePresentationBudget.collectionItems) {
            var row: [String] = []
            for column in columns {
                guard let cell = scalarText(object[column] ?? .null) else { return nil }
                row.append(cell)
            }
            rows.append(row)
        }
        if objects.count > rows.count {
            rows.append([
                String.l10n("agent.workspace.trace.contentTruncated")
            ] + Array(repeating: "", count: max(0, columns.count - 1)))
        }
        return .table(columns: columns, rows: rows)
    }

    private static func scalarText(_ value: AgentJSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number(let number):
            return numberText(number)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object, .array: return nil
        }
    }

    /// 复用 JSON 编码器输出数字，避免超大整数经过 `Int(Double)` 转换时触发溢出崩溃。
    private static func numberText(_ number: Double) -> String {
        (try? AgentJSONValue.number(number).jsonString()) ?? String(number)
    }

    /// 只在每个非空行都符合 `key: value` 时结构化。任何自由文本行都会让整段回退，
    /// 避免把 Markdown、URL 或错误栈里的冒号误判成业务字段。
    private static func keyValueFields(from text: String) -> [AgentTraceStructuredField]? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }

        var fields: [AgentTraceStructuredField] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let separator = trimmed.firstIndex(of: ":")
            else { return nil }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let valueStart = trimmed.index(after: separator)
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || "_.-".contains($0) })
            else { return nil }
            fields.append(.init(key: key, value: .scalar(value)))
        }
        return fields
    }
}

/// Runtime 详情的统一 renderer。Runtime/Tool 仍决定事件内容，本视图只决定同一种数据形态
/// 在 macOS 时间线里的稳定布局，避免 Adapter 直接拼 SwiftUI 或 UI 猜 Provider 协议。
struct AgentTraceDetailsView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isRawExpanded = false

    let event: AgentTraceEvent

    private var presentation: AgentTraceDetailPresentation {
        AgentTraceDetailPresentationBuilder.make(event: event)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let attempt = event.attempt {
                Text("\(String.l10n("action.retry")) \(attempt)")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(presentation.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.label)
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                        .foregroundStyle(.secondary)
                    contentView(section.content)
                }
            }

            if let rawPayload = presentation.rawPayload {
                Button {
                    // 原始 payload 可能接近展示预算上限；禁用高度动画，避免动画帧内反复
                    // 测量整段等宽文本。折叠状态仍立即更新，不影响整行点击契约。
                    isRawExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isRawExpanded ? "chevron.down" : "chevron.right")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("agent.workspace.trace.rawData")
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if isRawExpanded {
                    codeBlock(rawPayload)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func contentView(_ content: AgentTraceDetailPresentation.Content) -> some View {
        switch content {
        case .text(let text):
            Text(text)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .markdown(let text):
            AgentTraceMarkdownText(markdown: text, tone: .primary)
        case .code(let text):
            codeBlock(text)
        case .error(let text):
            Text(text)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(Color.red)
                .textSelection(.enabled)
        case .structured(let value):
            AgentTraceStructuredValueView(value: value)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(interfaceScale.font(.code, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
    }
}

/// Runtime 的 reasoning summary 与 commentary 都可能包含强调、列表和行内代码。
/// MarkdownUI 不继承外层 SwiftUI 字号，因此这里显式绑定 Trace 的紧凑排版。
struct AgentTraceMarkdownText: View {
    enum Tone {
        case primary
        case secondary
    }

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let markdown: String
    let tone: Tone

    var body: some View {
        Markdown(markdown)
            .markdownTheme(traceTheme)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var traceTheme: Theme {
        Theme()
            .text {
                ForegroundColor(tone == .primary ? .primary : .secondary)
                FontSize(interfaceScale.scaled(StarcatTypography.captionSmall.pointSize))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(.secondary.opacity(0.10))
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: .zero, bottom: .em(0.3))
            }
            .list { configuration in
                configuration.label
                    .markdownMargin(top: .zero, bottom: .em(0.3))
            }
    }
}

private struct AgentTraceStructuredValueView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let value: AgentTraceStructuredValue

    var body: some View {
        switch value {
        case .scalar(let text):
            Text(text)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .object(let fields):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 10) {
                        Text(field.key)
                            .font(interfaceScale.font(.captionSmall, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 88, idealWidth: 112, maxWidth: 152, alignment: .leading)
                        AgentTraceStructuredValueView(value: field.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .list(let values):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        AgentTraceStructuredValueView(value: value)
                    }
                }
            }
        case .table(let columns, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        ForEach(columns, id: \.self) { column in
                            Text(column)
                                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(interfaceScale.font(.captionSmall))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension String {
    /// Trace payload 经常包含只有换行的字段；结构化展示时把它视为缺失值。
    var traceNonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
