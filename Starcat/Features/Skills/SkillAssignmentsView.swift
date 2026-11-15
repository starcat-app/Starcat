//
//  SkillAssignmentsView.swift
//  Starcat
//
//  将自有分配与只读发现位置并列展示。任何写操作先生成含目标与共享影响的预览，
//  用户确认后才执行，界面不使用乐观 Toggle 冒充 Agent 已加载。
//

import SwiftUI

struct SkillAssignmentsView: View {
    let item: SkillLibraryItem
    let viewModel: SkillWorkspaceViewModel
    @State private var targets: [SkillAssignmentTarget] = []
    @State private var observations: [SkillAssignmentObservation] = []
    @State private var preview: SkillAssignmentPlan?
    @State private var isBusy = false
    @State private var hasLoadedAssignments = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if item.managementKind == .managed, viewModel.libraryEnvironment != nil {
                HStack {
                    Text("skills.assignment.title").font(.headline)
                    Spacer()
                    Menu("skills.assignment.assign") {
                        ForEach(targets) { target in
                            Button(target.names) { prepare(.assign, targetID: target.id) }
                        }
                    }
                    .disabled(isBusy || targets.isEmpty)
                }
                if !hasLoadedAssignments {
                    ListLoadingSkeleton(rowCount: 3, rowHeight: 72)
                } else if targets.isEmpty {
                    Text("skills.assignment.noTargets").foregroundStyle(.secondary)
                }
                Text("skills.assignment.notice").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(observations.enumerated()), id: \.element.id) { index, observation in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: observation.assignment.target.names).font(.headline)
                        Text(verbatim: observation.assignment.targetPath).font(.caption.monospaced())
                        Text(LocalizedStringKey("skills.assignment.state.\(observation.state.rawValue)"))
                            .foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            if observation.assignment.desiredState == .paused {
                                Button("skills.assignment.resume") {
                                    prepare(.resume, assignmentID: observation.id)
                                }
                            } else {
                                Button("skills.assignment.pause") {
                                    prepare(.pause, assignmentID: observation.id)
                                }
                            }
                            Button("skills.assignment.uninstall", role: .destructive) {
                                prepare(.uninstall, assignmentID: observation.id)
                            }
                        }
                        .disabled(isBusy)
                    }
                    .padding(6)
                    .listRowSurface(index: index)
                    Divider()
                }
                if isBusy { ProgressView().controlSize(.small) }
                if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            }
            Text("skills.assignment.discovered").font(.headline)
            ForEach(Array(item.locations.enumerated()), id: \.element.id) { index, location in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: location.agentNames.joined(separator: " · ")).font(.headline)
                    Text(verbatim: location.path).font(.caption.monospaced())
                    if location.resolvedPath != location.path, let resolved = location.resolvedPath {
                        Text(verbatim: resolved).font(.caption.monospaced())
                    }
                    Text(LocalizedStringKey("skills.detail.location.\(location.state.rawValue)"))
                        .foregroundStyle(.secondary)
                    Text(LocalizedStringKey(location.isShared ? "skills.detail.shared" : "skills.detail.visibility.unverified"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .listRowSurface(index: index)
            }
            if item.locations.isEmpty { Text("skills.detail.assignments.none").foregroundStyle(.secondary) }
        }
        .task(id: viewModel.contentRefreshID) { await load() }
        .sheet(item: $preview) { plan in
            SkillAssignmentReviewSheet(plan: plan, isBusy: isBusy, cancel: { preview = nil }) {
                execute(plan)
            }
            .appLocaleEnvironment()
        }
    }

    private func load() async {
        // 刷新沿用现有列表；只有首载缺少快照时显示骨架，不影响真实分配操作进度。
        defer { if !Task.isCancelled { hasLoadedAssignments = true } }
        guard let service = viewModel.libraryEnvironment?.assignments else { return }
        do {
            let targets = try await service.targets()
            let observations = try await service.observations(entryID: item.id)
            guard !Task.isCancelled else { return }
            self.targets = targets
            self.observations = observations
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }

    private func prepare(_ action: SkillAssignmentAction, targetID: String? = nil, assignmentID: UUID? = nil) {
        guard let service = viewModel.libraryEnvironment?.assignments, !isBusy else { return }
        isBusy = true
        message = nil
        Task {
            defer { isBusy = false }
            do {
                preview = try await service.prepare(entryID: item.id, action: action, targetID: targetID, assignmentID: assignmentID)
            } catch { message = error.localizedDescription }
        }
    }

    private func execute(_ plan: SkillAssignmentPlan) {
        guard let service = viewModel.libraryEnvironment?.assignments, !isBusy else { return }
        isBusy = true
        Task {
            let result = await service.execute(plan)
            message = result.isSuccess ? String.l10n("skills.assignment.success") : result.message
            isBusy = false
            preview = nil
            await load()
            viewModel.refreshLibrary()
        }
    }
}

/// 单项预览明确列出物理目录和全部逻辑入口，暂停／卸载都只作用于这一份链接。
private struct SkillAssignmentReviewSheet: View {
    let plan: SkillAssignmentPlan
    let isBusy: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(LocalizedStringKey(plan.action.titleKey)).font(.headline)
                Spacer()
                SheetCloseButton(action: cancel).disabled(isBusy)
            }
            Text(verbatim: plan.entry.manifestName).font(.title3)
            Text(verbatim: plan.target.names)
            ForEach(plan.target.configuredPaths, id: \.self) { path in
                Text(verbatim: path).font(.caption.monospaced()).textSelection(.enabled)
            }
            Text(verbatim: plan.target.resolvedParent).font(.caption.monospaced()).textSelection(.enabled)
            Text("skills.assignment.notice").font(.caption).foregroundStyle(.secondary)
            if isBusy { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                Button("common.cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(plan.action.titleKey), action: confirm).keyboardShortcut(.defaultAction)
            }
            .disabled(isBusy)
        }
        .padding(20).frame(width: 520)
        .interactiveDismissDisabled(isBusy)
    }
}
