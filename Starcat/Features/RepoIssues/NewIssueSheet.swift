//
//  NewIssueSheet.swift
//  Starcat
//
//  新建 Issue 的 macOS Sheet（从 Issues 列表浮层「新建」进入，浮层先收起再弹本表单）。
//
//  布局（对齐 dong4j 2026-11-01 设计图右侧 02）：
//  标题行（新建 Issue + 关闭钮）→ 提交到 <owner/repo> → 标题输入（打开即聚焦）→
//  描述（编辑 / 预览切换，MarkdownUI 渲染预览）→ 草稿状态提示 → 取消 / 提交。
//
//  关键约束：
//  - 草稿按仓库自动保存：走 `DiskIssueDraftCache`（文件 JSON，非 GRDB），onChange
//    防抖 + onDisappear flush；提交成功删除草稿后不再回写（`hasSubmitted` 守卫）。
//  - 提交失败保留输入（不 dismiss），错误内联展示；映射对齐 composer 的
//    `submitErrorMessage` 惯例（403/404 → 私仓 / 权限提示）。
//  - 文案走 `String.l10n(key, defaultValue:)`，xcstrings 由国际化批处理任务后补。
//  - 第一版不做富文本格式化工具条（B/I/链接），Markdown 手写 + 预览够用。
//

import MarkdownUI
import SwiftUI

struct NewIssueSheet: View {
    let repo: Repo
    let client: any GitHubAPIClientProtocol
    /// 提交成功回调（传回新 issue，Scaffold 驱动浮层刷新 + 高亮）。
    let onCreated: (GitHubRepoIssue) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var issueBody = ""
    @State private var mode: Mode = .edit
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var hasSubmitted = false
    @State private var isDraftSaved = false
    @State private var persistDebounceTask: Task<Void, Never>?
    @FocusState private var isTitleFocused: Bool

    private var draftCache: DiskIssueDraftCache { .shared }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBody: String { issueBody.trimmingCharacters(in: .whitespacesAndNewlines) }

    enum Mode: Hashable {
        case edit
        case preview
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear(perform: loadDraft)
        .onDisappear(perform: flushDraft)
        .onChange(of: title) { _, _ in schedulePersistDraft() }
        .onChange(of: issueBody) { _, _ in schedulePersistDraft() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text(String.l10n("repo.issues.sheet.title", defaultValue: "新建 Issue"))
                .font(.headline)
            Spacer()
            SheetCloseButton {
                flushDraft()
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 目标仓库：提交前明确确认（设计要求）。
            HStack(spacing: 6) {
                Text(String.l10n("repo.issues.sheet.submitTo", defaultValue: "提交到"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11))
                    Text(verbatim: repo.fullName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }

            // 标题：打开即聚焦，方便立即输入（设计要求）。
            VStack(alignment: .leading, spacing: 5) {
                Text(String.l10n("repo.issues.sheet.titleLabel", defaultValue: "标题"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField(
                    String.l10n("repo.issues.sheet.titlePlaceholder", defaultValue: "简明描述这个问题或建议"),
                    text: $title
                )
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .focused($isTitleFocused)
                .onSubmit { isTitleFocused = false }
            }

            // 描述：编辑 / 预览切换（项目惯例 segmented，见 NoteEditorSheet）。
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(String.l10n("repo.issues.sheet.bodyLabel", defaultValue: "描述"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $mode) {
                        Text(String.l10n("repo.issues.sheet.tabEdit", defaultValue: "编辑")).tag(Mode.edit)
                        Text(String.l10n("repo.issues.sheet.tabPreview", defaultValue: "预览")).tag(Mode.preview)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }

                Group {
                    switch mode {
                    case .edit:
                        TextEditor(text: $issueBody)
                            .font(.system(.body, design: .default))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(alignment: .topLeading) {
                                if issueBody.isEmpty {
                                    Text(String.l10n("repo.issues.sheet.bodyPlaceholder", defaultValue: "描述这个 Issue，支持 Markdown…"))
                                        .font(.system(.body, design: .default))
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 13)
                                        .padding(.top, 16)
                                        .allowsHitTesting(false)
                                }
                            }
                    case .preview:
                        ScrollView {
                            let trimmed = trimmedBody
                            if trimmed.isEmpty {
                                Text(String.l10n("repo.issues.sheet.emptyPreview", defaultValue: "暂无内容可预览"))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            } else {
                                Markdown(issueBody)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            // 底部提示：左 Markdown 支持，右草稿状态（设计要求「草稿已自动保存」）。
            HStack(spacing: 8) {
                Text(String.l10n("repo.issues.sheet.markdownHint", defaultValue: "支持 Markdown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isDraftSaved {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                        Text(String.l10n("repo.issues.sheet.draftSaved", defaultValue: "草稿已自动保存"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(String.l10n("repo.issues.sheet.cancel", defaultValue: "取消")) {
                flushDraft()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .focusEffectDisabled()

            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 72)
                } else {
                    Text(String.l10n("repo.issues.sheet.submit", defaultValue: "提交 Issue"))
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .focusEffectDisabled()
            .disabled(trimmedTitle.isEmpty || isSubmitting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 草稿

    private func loadDraft() {
        if let snapshot = draftCache.load(repoFullName: repo.fullName) {
            title = snapshot.title
            issueBody = snapshot.body
        }
        isTitleFocused = true
    }

    private func schedulePersistDraft() {
        persistDebounceTask?.cancel()
        guard !hasSubmitted else { return }
        persistDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            persistDraftNow()
        }
    }

    private func persistDraftNow() {
        guard !hasSubmitted else { return }
        draftCache.upsert(repoFullName: repo.fullName, title: title, body: issueBody)
        withAnimation(.easeOut(duration: 0.2)) {
            isDraftSaved = true
        }
    }

    private func flushDraft() {
        persistDebounceTask?.cancel()
        persistDraftNow()
    }

    // MARK: - 提交

    private func submit() async {
        guard !repo.owner.isEmpty, !repo.name.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let issue = try await client.createRepoIssue(
                owner: repo.owner,
                repo: repo.name,
                title: trimmedTitle,
                body: trimmedBody.isEmpty ? nil : issueBody
            )
            hasSubmitted = true
            draftCache.remove(repoFullName: repo.fullName)
            onCreated(issue)
            dismiss()
        } catch {
            // 失败保留输入，不 dismiss；错误内联（对齐 composer submitErrorMessage 惯例）。
            errorMessage = Self.createErrorMessage(error)
        }
    }

    /// 创建失败文案映射；403/404 多为私仓或无权限（public_repo 只覆盖公开仓库）。
    nonisolated private static func createErrorMessage(_ error: Error) -> String {
        if let networkError = error as? NetworkError {
            switch networkError {
            case .notFound:
                return String.l10n("repo.issues.sheet.error.notFound", defaultValue: "无法在该仓库创建 Issue（可能是私有仓库或已关闭 Issues）")
            case .clientError(let code, _) where code == 403 || code == 404:
                return String.l10n("repo.issues.sheet.error.forbidden", defaultValue: "无法在该仓库创建 Issue（可能是私有仓库或权限不足）")
            case .clientError(let code, _) where code == 422:
                return String.l10n("repo.issues.sheet.error.validation", defaultValue: "GitHub 拒绝了这次提交，请检查标题与描述后重试")
            case .unauthorized:
                return String.l10n("repo.issues.sheet.error.unauthorized", defaultValue: "登录状态已失效，请重新登录 GitHub")
            case .rateLimited:
                return String.l10n("repo.issues.sheet.error.rateLimited", defaultValue: "GitHub 请求频率受限，请稍后再试")
            default:
                break
            }
        }
        return String.l10n("repo.issues.sheet.error.generic", defaultValue: "Issue 提交失败，请稍后再试")
    }
}
