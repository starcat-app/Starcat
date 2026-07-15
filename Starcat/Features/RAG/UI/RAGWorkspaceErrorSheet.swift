//
//  RAGWorkspaceErrorSheet.swift
//  Starcat
//
//  RAG 工作台 / 知识库浏览器的用户可见错误面板。
//
//  关键约束：界面只展示友好文案，不暴露 CancellationError / GRDB / HTTP 等内部细节；
//  技术细节仅随「反馈」邮件发给开发者，避免用户面对无法理解的系统异常串。
//

import AppKit
import SwiftUI

/// RAG 错误反馈收件人（与 About / 菜单「联系作者」一致）。
enum RAGWorkspaceFeedbackMail {
    static let address = "dong4j@gmail.com"
}

/// 工作台只向用户暴露下一步操作；底层 Provider、HTTP 与数据库细节保留在 `technicalDetail`，
/// 仅随反馈邮件发送。这样既能恢复问题，也不会把内部错误字符串当成产品文案。
enum RAGWorkspaceErrorKind: Equatable {
    case configuration
    case authentication
    case network
    case timeout
    case planner
    case attachment
    case generation
    case unknown
}

enum RAGWorkspaceErrorAction: Equatable {
    case retry
    case openAISettings
    case checkNetwork
    case removeAttachments
    case dismiss
}

struct RAGWorkspaceError: Identifiable {
    let id = UUID()
    let kind: RAGWorkspaceErrorKind
    let technicalDetail: String

    init(error: Error) {
        technicalDetail = error.localizedDescription
        kind = Self.classify(error: error, detail: technicalDetail)
    }

    init(technicalDetail: String) {
        self.technicalDetail = technicalDetail
        kind = Self.classify(error: nil, detail: technicalDetail)
    }

    var titleKey: String {
        switch kind {
        case .configuration, .authentication: return "rag.workspace.error.configuration.title"
        case .network, .timeout: return "rag.workspace.error.network.title"
        case .planner: return "rag.workspace.error.planner.title"
        case .attachment: return "rag.workspace.error.attachment.title"
        case .generation: return "rag.workspace.error.generation.title"
        case .unknown: return "rag.workspace.error.title"
        }
    }

    var messageKey: String {
        switch kind {
        case .configuration: return "rag.workspace.error.configuration.message"
        case .authentication: return "rag.workspace.error.authentication.message"
        case .network: return "rag.workspace.error.network.message"
        case .timeout: return "rag.workspace.error.timeout.message"
        case .planner: return "rag.workspace.error.planner.message"
        case .attachment: return "rag.workspace.error.attachment.message"
        case .generation: return "rag.workspace.error.generation.message"
        case .unknown: return "rag.workspace.error.message"
        }
    }

    var action: RAGWorkspaceErrorAction {
        switch kind {
        case .configuration, .authentication: return .openAISettings
        case .network: return .checkNetwork
        case .timeout, .planner, .generation: return .retry
        case .attachment: return .removeAttachments
        case .unknown: return .dismiss
        }
    }

    var actionKey: String {
        switch action {
        case .retry: return "rag.workspace.error.action.retry"
        case .openAISettings: return "rag.workspace.error.action.openAISettings"
        case .checkNetwork: return "rag.workspace.error.action.checkNetwork"
        case .removeAttachments: return "rag.workspace.error.action.removeAttachments"
        case .dismiss: return "common.close"
        }
    }

    private static func classify(error: Error?, detail: String) -> RAGWorkspaceErrorKind {
        if error is RAGAttachmentError { return .attachment }
        if error is RAGQueryPlannerError { return .planner }
        if let error = error as? AIClientError {
            switch error {
            case .missingAPIKey, .invalidBaseURL: return .configuration
            case .emptyResponse, .responseTruncated: return .generation
            case .modelListRequestFailed: return .network
            }
        }
        if let error = error as? GitHubRemoteContextError,
           case .http(let status, _) = error {
            if status == 401 || status == 403 { return .authentication }
            if status == 408 || status == 504 { return .timeout }
            if status == 429 || status >= 500 { return .network }
        }
        if let error = error as? URLError {
            if error.code == .timedOut { return .timeout }
            return .network
        }
        let normalized = detail.lowercased()
        if normalized.contains("401") || normalized.contains("403") || normalized.contains("unauthorized") {
            return .authentication
        }
        if normalized.contains("timed out") || normalized.contains("timeout") || normalized.contains("超时") {
            return .timeout
        }
        if normalized.contains("network") || normalized.contains("offline") || normalized.contains("连接") {
            return .network
        }
        return .unknown
    }
}

/// 用 sheet 替代系统 alert：标题 + 友好说明 + 关闭 / 邮件反馈。
struct RAGWorkspaceErrorSheet: View {
    let error: RAGWorkspaceError
    let onAction: (RAGWorkspaceErrorAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(error.titleKey))
                        .font(.headline)
                    Text(LocalizedStringKey(error.messageKey))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SheetCloseButton(action: onDismiss)
            }

            HStack(spacing: 10) {
                if error.action != .dismiss {
                    Button(LocalizedStringKey(error.actionKey)) {
                        onAction(error.action)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("rag.workspace.error.feedback") {
                    openFeedbackMail()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button(error.action == .dismiss ? LocalizedStringKey(error.actionKey) : "common.close") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 打开系统邮件客户端；正文附带版本与技术细节供排障。
    private func openFeedbackMail() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let trimmedDetail = error.technicalDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = """
        \(String.l10n("rag.workspace.error.feedback.bodyIntro"))

        ---
        Starcat \(version) (\(build))
        \(ISO8601DateFormatter.shared.string(from: Date()))

        \(trimmedDetail.isEmpty ? String.l10n("rag.workspace.error.feedback.noDetail") : trimmedDetail)
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = RAGWorkspaceFeedbackMail.address
        components.queryItems = [
            URLQueryItem(name: "subject", value: String.l10n("rag.workspace.error.feedback.subject")),
            URLQueryItem(name: "body", value: body)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}
