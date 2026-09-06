//
//  AIOrganizationWorkspaceControls.swift
//  Starcat
//
//  AI 标签整理与 GitHub Lists 分组整理共用的工作区操作组件。
//
//  两种整理的数据模型和行内审核内容不同，但任务生命周期与底部批量应用语义必须一致：
//  顶部只负责暂停、终止和隐藏窗口，底部只负责放弃会话与应用已选结果。
//  将这两处交互收口为共享组件，可以避免后续其中一个窗口再次出现重复关闭按钮或按钮错位。
//

import SwiftUI

/// 整理工作区标题栏右侧的任务生命周期控制。
///
/// `canContinue` 用于已经终止但仍保留未完成任务的会话；它与合作式暂停不同，继续时需要
/// 重新创建 Worker。关闭按钮始终只隐藏窗口，不隐式暂停、终止或清空会话。
struct AIOrganizationTaskControls: View {
    let isRunning: Bool
    let isPaused: Bool
    let isStopping: Bool
    let canContinue: Bool
    let pauseTitle: LocalizedStringKey
    let resumeTitle: LocalizedStringKey
    let stopTitle: LocalizedStringKey
    let onPause: () -> Void
    let onResume: () -> Void
    let onContinue: () -> Void
    let onStop: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                Button {
                    isPaused ? onResume() : onPause()
                } label: {
                    Label(
                        isPaused ? resumeTitle : pauseTitle,
                        systemImage: isPaused ? "play.fill" : "pause.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .help(isPaused ? resumeTitle : pauseTitle)
                .disabled(isStopping)

                Button(role: .destructive, action: onStop) {
                    Label(stopTitle, systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .help(stopTitle)
                .disabled(isStopping)
            } else if canContinue {
                Button(action: onContinue) {
                    Label(resumeTitle, systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                }
                .help(resumeTitle)
                .disabled(isStopping)
            }

            SheetCloseButton(action: onClose)
        }
    }
}

/// 整理审核页统一的底部操作区。
///
/// 关闭入口固定在标题栏，因此这里不再重复放置“关闭”。选择摘要由各业务层提供，组件只负责
/// 保持“放弃在左、批量应用在右”的布局契约。
struct AIOrganizationReviewFooter: View {
    let discardTitle: LocalizedStringKey
    let canDiscard: Bool
    let selectionSummary: String
    let canApply: Bool
    let isApplying: Bool
    var showsApplyActions = true
    var showsSelectionControls = false
    var canSelectAll = false
    var canClearSelection = false
    var onSelectAll: () -> Void = {}
    var onClearSelection: () -> Void = {}
    /// 非应用类批量动作（批量重试/忽略/取消忽略）的按钮标题。
    /// 非 nil 时右侧主按钮从「应用选中项」切换为该动作，`canApply` 不再参与判断。
    var bulkActionTitle: LocalizedStringKey?
    var canRunBulkAction = false
    var onBulkAction: () -> Void = {}
    let onDiscard: () -> Void
    let onApply: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 10) {
            if canDiscard {
                Button(discardTitle, role: .destructive, action: onDiscard)
            }

            if showsApplyActions, showsSelectionControls {
                Button("batchAI.panel.review.selectAllRepositories", action: onSelectAll)
                    .disabled(!canSelectAll || isApplying)
                Button("batchAI.panel.review.clearRepositorySelection", action: onClearSelection)
                    .disabled(!canClearSelection || isApplying)
            }

            Spacer()

            if showsApplyActions {
                Text(verbatim: selectionSummary)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let bulkActionTitle {
                    Button(bulkActionTitle, action: onBulkAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRunBulkAction || isApplying)
                } else {
                    Button("githubStarLists.aiGrouping.applySelected", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canApply || isApplying)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(height: 58)
    }
}
