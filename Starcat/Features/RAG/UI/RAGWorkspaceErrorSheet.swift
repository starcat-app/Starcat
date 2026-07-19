//
//  RAGWorkspaceErrorSheet.swift
//  Starcat
//
//  RAG 工作台 / 知识库浏览器的用户可见错误提示。
//
//  关键约束：界面只展示友好文案，不暴露 CancellationError / GRDB / HTTP 等内部细节；
//  技术细节仅随「反馈」邮件发给开发者；视觉与键盘行为交给 macOS 原生 alert。
//

import AppKit
import SwiftUI

/// RAG 错误反馈收件人（与 About / 菜单「联系作者」一致）。
enum RAGWorkspaceFeedbackMail {
    static let address = "dong4j@gmail.com"

    /// 打开系统邮件客户端；正文附带版本与技术细节供排障。
    static func open(for error: RAGWorkspaceError) {
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
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: String.l10n("rag.workspace.error.feedback.subject")),
            URLQueryItem(name: "body", value: body)
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 工作台只向用户暴露下一步操作；底层 Provider、HTTP 与数据库细节保留在 `technicalDetail`，
/// 仅随反馈邮件发送。这样既能恢复问题，也不会把内部错误字符串当成产品文案。
enum RAGWorkspaceErrorKind: Equatable {
    case configuration
    case embeddingConfiguration
    case embeddingRequest
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
        case .embeddingConfiguration: return "rag.workspace.error.embeddingConfiguration.title"
        case .embeddingRequest: return "rag.workspace.error.embeddingRequest.title"
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
        case .embeddingConfiguration: return "rag.workspace.error.embeddingConfiguration.message"
        case .embeddingRequest: return "rag.workspace.error.embeddingRequest.message"
        case .authentication: return "rag.workspace.error.authentication.message"
        case .network: return "rag.workspace.error.network.message"
        case .timeout: return "rag.workspace.error.timeout.message"
        case .planner: return "rag.workspace.error.planner.message"
        case .attachment: return "rag.workspace.error.attachment.message"
        case .generation: return "rag.workspace.error.generation.message"
        case .unknown: return "rag.workspace.error.message"
        }
    }

    /// 向量化领域错误本身已经是本地化、可执行的产品文案，直接展示具体原因；
    /// 其他错误仍用固定文案，避免把 HTTP / GRDB 等内部细节暴露给用户。
    var messageText: String {
        switch kind {
        case .embeddingConfiguration, .embeddingRequest:
            return technicalDetail
        case .configuration, .authentication, .network, .timeout, .planner, .attachment, .generation, .unknown:
            return String.l10n(messageKey)
        }
    }

    var action: RAGWorkspaceErrorAction {
        switch kind {
        case .configuration, .embeddingConfiguration, .embeddingRequest, .authentication: return .openAISettings
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
        if let error = error as? AIEmbeddingError {
            if error.isConfigurationIssue { return .embeddingConfiguration }
            switch error {
            case .authenticationRejected: return .authentication
            case .networkUnavailable, .rateLimited: return .network
            case .timedOut: return .timeout
            case .modelRequestRejected, .invalidResponse, .emptyResponse, .requestFailed:
                return .embeddingRequest
            case .missingProvider, .providerUnavailable, .missingAPIKey, .missingModel, .incompatibleModel:
                return .embeddingConfiguration
            }
        }
        if let error = error as? AIClientError {
            switch error {
            case .missingAPIKey, .invalidBaseURL, .authenticationRejected, .paymentRequired: return .configuration
            case .emptyResponse, .responseTruncated: return .generation
            case .modelListRequestFailed, .rateLimited, .networkUnavailable, .timedOut: return .network
            case .requestRejected, .requestFailed: return .generation
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

extension View {
    /// 用系统 alert 呈现 RAG 错误。macOS 负责应用图标、窗口附着、按钮顺序与 Return/Esc，
    /// 避免自绘大圆角 Sheet 与桌面平台交互习惯冲突。
    func ragWorkspaceErrorAlert(
        error: Binding<RAGWorkspaceError?>,
        onAction: @escaping (RAGWorkspaceError) -> Void
    ) -> some View {
        modifier(RAGWorkspaceErrorAlertModifier(error: error, onAction: onAction))
    }
}

private struct RAGWorkspaceErrorAlertModifier: ViewModifier {
    @Binding var error: RAGWorkspaceError?
    let onAction: (RAGWorkspaceError) -> Void

    private var isPresented: Binding<Bool> {
        Binding(
            get: { error != nil },
            set: { isPresented in
                if !isPresented { error = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        let titleKey = LocalizedStringKey(error?.titleKey ?? "rag.workspace.error.title")

        content.alert(
            titleKey,
            isPresented: isPresented,
            presenting: error
        ) { presentedError in
            if presentedError.action != .dismiss {
                Button(LocalizedStringKey(presentedError.actionKey)) {
                    onAction(presentedError)
                    error = nil
                }
                .keyboardShortcut(.defaultAction)
            }

            Button("rag.workspace.error.feedback") {
                RAGWorkspaceFeedbackMail.open(for: presentedError)
                error = nil
            }

            if presentedError.action == .dismiss {
                Button("common.close") { error = nil }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("common.close", role: .cancel) { error = nil }
            }
        } message: { presentedError in
            Text(presentedError.messageText)
        }
    }
}
