//
//  SkillRemovalReviewSheet.swift
//  Starcat
//
//  从本机库移除前展示全部受管分配及已发现路径。审核与提交分开，
//  部分卸载或恢复失败保留逐项结果，窗口关闭不取消已确认的文件提交。
//

import SwiftUI

/// 固定 AppKit sheet 内滚动展示影响范围，长路径和多目标不参与窗口尺寸回传。
struct SkillRemovalReviewSheet: View {
    let viewModel: SkillWorkspaceViewModel
    let entryID: UUID
    let close: () -> Void
    @State private var plan: SkillRemovalPlan?
    @State private var outcome: SkillRemovalOutcome?
    @State private var message: String?
    @State private var isBusy = true
    @State private var isCommitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("skills.removal.title").font(.headline)
                Spacer()
                SheetCloseButton(action: close).disabled(isCommitting)
            }
            Text("skills.removal.notice").foregroundStyle(.secondary)
            Text("skills.removal.externalNotice").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let plan {
                        Text(verbatim: plan.entry.manifestName).font(.title3)
                        ForEach(plan.assignments) { assignment in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: assignment.target.names).font(.headline)
                                ForEach(assignment.target.configuredPaths, id: \.self) { path in
                                    Text(verbatim: path).font(.caption.monospaced())
                                }
                                if let result = outcome?.assignmentResults.first(where: { $0.id == assignment.id }) {
                                    Text(LocalizedStringKey("skills.operation.result.\(result.status.rawValue)"))
                                        .foregroundStyle(.secondary)
                                    if let message = result.message {
                                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        Divider()
                        ForEach(plan.discoveredPaths, id: \.self) { path in
                            Text(verbatim: path).font(.caption.monospaced())
                        }
                    }
                    if let outcome {
                        Text(LocalizedStringKey("skills.operation.result.\(outcome.result.status.rawValue)"))
                            .foregroundStyle(.secondary)
                    }
                    if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            if isBusy { ProgressView().controlSize(.small) }
            Divider()
            HStack {
                Spacer()
                Button("common.close", action: close).disabled(isCommitting).keyboardShortcut(.cancelAction)
                if let plan, outcome == nil {
                    Button("skills.removal.confirm", role: .destructive) { execute(plan) }.disabled(isBusy)
                }
            }
        }
        .padding(20)
        .task {
            guard let service = viewModel.libraryEnvironment?.removals else { isBusy = false; return }
            defer { isBusy = false }
            do {
                let prepared = try await service.prepare(entryID: entryID)
                if !Task.isCancelled { plan = prepared }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    /// 提交任务独立于 SwiftUI 的可见生命周期；完成后刷新一致快照并保留结果供核对。
    private func execute(_ plan: SkillRemovalPlan) {
        guard let service = viewModel.libraryEnvironment?.removals, !isBusy else { return }
        isBusy = true
        isCommitting = true
        Task {
            let completed = await service.execute(plan)
            outcome = completed
            message = completed.result.message
            isBusy = false
            isCommitting = false
            viewModel.refreshLibrary()
        }
    }
}
