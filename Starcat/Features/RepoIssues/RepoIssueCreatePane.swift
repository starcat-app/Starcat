//
//  RepoIssueCreatePane.swift
//  Starcat
//
//  Issues 工作台右栏-新建态：标题 + Markdown 描述编辑器 + 发布账号 footer。
//  原独立 `NewIssueSheet` 的表单逻辑整体迁入（铁律：不留双轨，旧文件删除）。
//
//  关键约束：
//  - 草稿按仓库保存（DiskIssueDraftCache，防抖 + flush），切换详情/新建互不丢稿。
//  - 描述编辑器与评论框共用 `ImagePasteTextEditor`（纯 Markdown 手写，不做富文本
//    工具条；✨ AI 生成与剪贴板图片上传为业务阶段接线点）。
//  - 提交失败保留输入（不关闭工作台），错误内联展示。
//

import MarkdownUI
import SwiftUI

struct RepoIssueCreatePane: View {
    @Bindable var viewModel: RepoIssuesWorkspaceViewModel

    @Environment(AuthSession.self) private var authSession
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @FocusState private var isTitleFocused: Bool

    private enum ComposerMode: Hashable {
        case edit
        case preview
    }

    private var modeBinding: Binding<ComposerMode> {
        Binding(
            get: { viewModel.isCreatePreview ? .preview : .edit },
            set: { viewModel.isCreatePreview = ($0 == .preview) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 不用 ScrollView：描述编辑器直接吃掉标题区以下的全部剩余高度，
            // 底部不留白（2026-11-01 dong4j 反馈）。
            VStack(alignment: .leading, spacing: 14) {
                titleSection
                descriptionSection
                if let error = viewModel.createErrorMessage
                    ?? viewModel.uploadErrorMessage
                    ?? viewModel.aiErrorMessage {
                    Text(verbatim: error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .task {
            // 打开即聚焦标题（旧 NewIssueSheet 行为保留）。
            isTitleFocused = true
        }
        .onChange(of: viewModel.createTitle) { _, _ in
            viewModel.scheduleCreateDraftPersist()
        }
        .onChange(of: viewModel.createBody) { _, _ in
            viewModel.scheduleCreateDraftPersist()
        }
        .sheet(item: $viewModel.aiPaywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .onDisappear {
            viewModel.cancelGenerateIfNeededOnDisappear()
        }
    }

    // MARK: - 标题

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String.l10n("repo.issues.popover.newIssue", defaultValue: "新建 Issue"))
                .font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Text(String.l10n("repo.issues.sheet.submitTo", defaultValue: "提交到"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11))
                    Text(verbatim: viewModel.repo.fullName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }

            TextField(
                String.l10n("repo.issues.sheet.titlePlaceholder", defaultValue: "简明描述这个问题或建议"),
                text: $viewModel.createTitle
            )
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .focused($isTitleFocused)
        }
        .padding(.top, 6)
    }

    // MARK: - 描述

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头像（发布身份）+ 编辑/预览 合并一行，替代「描述」文案
            // （2026-11-01 dong4j 反馈）。富文本工具条按设计决策不做（纯 Markdown）。
            HStack(spacing: 8) {
                RemoteAvatar(
                    urlString: authSession.state.user?.avatarUrl,
                    size: 20,
                    fallbackSymbol: "person.crop.circle.fill",
                    showBorder: false
                )
                PillSegmentedControl(
                    items: [ComposerMode.edit, .preview],
                    selection: modeBinding,
                    title: { mode in
                        mode == .edit
                            ? LocalizedStringKey("repo.issues.sheet.tabEdit")
                            : LocalizedStringKey("repo.issues.sheet.tabPreview")
                    },
                    size: .compact
                )
                Spacer()
                Button {
                    viewModel.sparklesTapped()
                } label: {
                    if viewModel.isGeneratingIssue {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!viewModel.canGenerateIssue)
                .help(String.l10n(
                    viewModel.isGeneratingIssue
                        ? "repo.issues.create.stopGenerate"
                        : "repo.issues.create.aiGenerateHelp",
                    defaultValue: viewModel.isGeneratingIssue ? "停止生成" : "用 AI 生成规范 Issue（依据已输入的描述）"
                ))
            }
            .foregroundStyle(.secondary)

            editorArea
        }
    }

    @ViewBuilder
    private var editorArea: some View {
        if viewModel.isCreatePreview {
            ScrollView {
                let trimmed = viewModel.trimmedCreateBody
                if trimmed.isEmpty {
                    Text(String.l10n("repo.issues.sheet.emptyPreview", defaultValue: "暂无内容可预览"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Markdown(viewModel.createBody)
                        .markdownTheme(RepoIssueMarkdownTheme.content(baseFontSize: 13 * interfaceScale.multiplier))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            // 编辑器撑满剩余空间（外部 frame 控制），测高上限放大避免内部裁切；
            // NSTextView 至少铺满当前框，空白处可点进输入。
            ImagePasteTextEditor(
                text: $viewModel.createBody,
                placeholder: String.l10n("repo.issues.sheet.bodyPlaceholder", defaultValue: "描述这个 Issue，支持 Markdown，可粘贴剪切板图片…"),
                isEditable: !viewModel.isGeneratingIssue && !viewModel.isUploadingImage,
                maximumHeight: 4_000,
                onHeightChange: { _ in },
                onPasteImage: { payload, placeholder in
                    Task { await viewModel.uploadPastedImage(payload, placeholder: placeholder) }
                },
                onPasteImageError: { error in
                    viewModel.setUploadError(error)
                }
            )
            .frame(minHeight: 160, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )
            // AI 生成光晕：与通知评论框同款（贴圆角外圈，blur 不被裁切）。
            .padding(StarcatAIHaloMetrics.glowBleed)
            .overlay {
                StarcatAIGeneratingHalo(isActive: viewModel.isGeneratingIssue)
            }
        }
    }

    // MARK: - 底部（发布账号 + 操作）

    private var footer: some View {
        HStack(spacing: 8) {
            // 发布身份头像已上移到编辑/预览行（2026-11-01 dong4j 反馈），footer 只留操作。
            Spacer()
            Button(String.l10n("repo.issues.sheet.cancel", defaultValue: "取消")) {
                viewModel.flushCreateDraft()
                // 交互契约：取消新建 → 回到之前查看的 Issue，工作台保留。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    viewModel.cancelCreating()
                }
            }
            .keyboardShortcut(.cancelAction)
            .focusEffectDisabled()

            Button {
                Task { await viewModel.createIssue() }
            } label: {
                if viewModel.isCreatingIssue {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(String.l10n("repo.issues.create.submit", defaultValue: "创建 Issue"))
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .focusEffectDisabled()
            .disabled(
                viewModel.trimmedCreateTitle.isEmpty
                    || viewModel.isCreatingIssue
                    || viewModel.isUploadingImage
                    || viewModel.isGeneratingIssue
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Issue 内容 Markdown 主题

/// Issue 正文 / 评论的 Markdown 排版：GitHub 风格但按 App 内容规范收字号
/// （正文 13pt 基准 × 界面缩放、标题 semibold 1.1–1.15em、紧凑边距、无 h2 下划线），
/// 排版口径对齐 `GitHubNotificationIssueSummaryMarkdownView.summaryTheme`。
/// 2026-11-01 dong4j 反馈：直接用 `Theme.gitHub` 默认字号（正文 17 / h2 28）过大。
enum RepoIssueMarkdownTheme {
    @MainActor
    static func content(baseFontSize: CGFloat) -> Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(baseFontSize)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)) }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.1)) }
                    .markdownMargin(top: 10, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold) }
                    .markdownMargin(top: 8, bottom: 6)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); ForegroundColor(.secondary) }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: 8)
            }
    }
}
