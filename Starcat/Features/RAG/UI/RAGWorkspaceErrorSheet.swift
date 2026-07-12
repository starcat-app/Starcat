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

/// 用 sheet 替代系统 alert：标题 + 友好说明 + 关闭 / 邮件反馈。
struct RAGWorkspaceErrorSheet: View {
    /// 仅写入反馈邮件正文，不在 UI 上展示。
    let technicalDetail: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("rag.workspace.error.title")
                        .font(.headline)
                    Text("rag.workspace.error.message")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SheetCloseButton(action: onDismiss)
            }

            HStack(spacing: 10) {
                Button("rag.workspace.error.feedback") {
                    openFeedbackMail()
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button("common.close") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
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
        let trimmedDetail = technicalDetail.trimmingCharacters(in: .whitespacesAndNewlines)
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
