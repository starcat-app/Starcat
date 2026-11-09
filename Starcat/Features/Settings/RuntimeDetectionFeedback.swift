//
//  RuntimeDetectionFeedback.swift
//  Starcat
//
//  三项 Runtime 共用的检测操作反馈，始终留在重新检测按钮左侧
//

import SwiftUI

/// 配置校验优先于版本比较，避免把版本相同但 Provider 等配置缺失的程序报告为就绪
struct RuntimeDetectionFeedback: View {
    let runtime: DownloadableRuntime
    let status: AgentRuntimeSettingsStatus
    let installedVersion: String?
    let isChecking: Bool
    var comparesDownloadVersion = true

    var body: some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: symbol)
                // 绿色只表达检测成功，说明文字继续使用次要文字色
                .foregroundStyle(!isChecking && status == .ready ? Color.green : Color.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(Text(verbatim: detail))
        .accessibilityHint(Text(verbatim: detail))
    }

    /// 始终输出一行；检测中只更新此处，不清空上次解析出的版本与路径
    private var message: String {
        if isChecking { return String.l10n("settings.integration.agentRuntime.detecting") }
        if case .failed(_, let summaryKey) = status { return String.l10n(summaryKey) }
        guard case .ready = status else {
            return String.l10n("settings.integration.agentRuntime.notConfigured")
        }
        guard comparesDownloadVersion else {
            return "\(String.l10n("settings.integration.agentRuntime.status.ready")) · \(installedVersion ?? "")"
        }
        let key = RuntimeDownloadVersionRelationship(
            installedVersion: installedVersion ?? "", availableVersion: runtime.executableVersion
        ).detectionMessageKey
        return String(format: String.l10n(key), runtime.version)
    }

    private var detail: String {
        if !isChecking, case .failed(let error, _) = status { return error }
        return [message, installedVersion ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var symbol: String {
        if isChecking { return "hourglass" }
        if case .failed = status { return "exclamationmark.triangle.fill" }
        return "checkmark.circle"
    }
}
