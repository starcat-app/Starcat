//
//  DiagnosticIssue.swift
//  Starcat
//
//  严重故障的固定摘要词表。业务入口选择问题类型，面板只翻译 key，
//  不从技术消息或任意异常文本推测原因。
//

import Foundation

/// 摘要不决定准入；调用方仍须明确最终结果与实际功能影响。
enum DiagnosticIssue: String, CaseIterable, Sendable {
    case generic = "diagnostics.issue.generic"
    case databaseUnavailable = "diagnostics.issue.databaseUnavailable"
    case chatHistoryUnavailable = "diagnostics.issue.chatHistoryUnavailable"
    case credentialsUnavailable = "diagnostics.issue.credentialsUnavailable"
    case settingsUnavailable = "diagnostics.issue.settingsUnavailable"
    case dataSaveFailed = "diagnostics.issue.dataSaveFailed"
    case dataCleanupFailed = "diagnostics.issue.dataCleanupFailed"
    case runtimeUnavailable = "diagnostics.issue.runtimeUnavailable"
    case syncFailed = "diagnostics.issue.syncFailed"
    case contentUnavailable = "diagnostics.issue.contentUnavailable"
    case aiUnavailable = "diagnostics.issue.aiUnavailable"
    case searchUnavailable = "diagnostics.issue.searchUnavailable"
    case knowledgeUnavailable = "diagnostics.issue.knowledgeUnavailable"
    case codeAnalysisUnavailable = "diagnostics.issue.codeAnalysisUnavailable"
    case readmeUnavailable = "diagnostics.issue.readmeUnavailable"
    case serviceUnavailable = "diagnostics.issue.serviceUnavailable"
    case exportFailed = "diagnostics.issue.exportFailed"

    /// 未识别的历史摘要只能显示通用文案，不能退回原始 message。
    static func summaryKey(for key: String?) -> String {
        key.flatMap(Self.init(rawValue:))?.rawValue ?? Self.generic.rawValue
    }
}
