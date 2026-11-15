//
//  SkillBatchAssignmentSheet.swift
//  Starcat
//
//  固定审核区中的多选分配流程。已选条目在打开时冻结，刷新列表不会扩大操作范围。
//  每个物理目标展示共享影响、进度和结果，失败重试回到预览再次确认。
//

import SwiftUI

struct SkillBatchAssignmentSheet: View {
    let viewModel: SkillWorkspaceViewModel
    let entryIDs: [UUID]
    let close: () -> Void
    @State private var action = SkillAssignmentAction.assign
    @State private var targets: [SkillAssignmentTarget] = []
    @State private var targetIDs: Set<String> = []
    @State private var rows: [SkillBatchAssignmentRow] = []
    @State private var runningID: String?
    @State private var isBusy = false
    @State private var isRunning = false
    @State private var isReview = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("skills.batch.title").font(.headline)
                Spacer()
                SheetCloseButton(action: close).disabled(isBusy)
            }
            Text("skills.batch.notice").font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Picker("skills.assignment.title", selection: $action) {
                    ForEach(SkillAssignmentAction.allCases, id: \.self) { action in
                        Text(LocalizedStringKey(action.titleKey)).tag(action)
                    }
                }
                .disabled(isBusy)
                if action == .assign {
                    Text("skills.batch.targets").font(.headline)
                    ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                        Toggle(isOn: Binding(
                            get: { targetIDs.contains(target.id) },
                            set: { if $0 { targetIDs.insert(target.id) } else { targetIDs.remove(target.id) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(verbatim: target.names)
                                Text(verbatim: target.resolvedParent).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isBusy)
                        .padding(5)
                        .listRowSurface(index: index, isSelected: targetIDs.contains(target.id))
                    }
                    if targets.isEmpty { Text("skills.assignment.noTargets").foregroundStyle(.secondary) }
                }
                Spacer()
            } else {
                HStack {
                    Text(LocalizedStringKey(action.titleKey)).font(.headline)
                    Spacer()
                    Text(verbatim: "\(rows.filter { $0.result != nil }.count)/\(rows.count)").monospacedDigit()
                }
                List(Array(rows.enumerated()), id: \.element.id) { index, row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(verbatim: row.name).font(.headline)
                            Spacer()
                            if row.id == runningID { ProgressView().controlSize(.small) }
                            if let result = row.result {
                                Text(LocalizedStringKey("skills.operation.result.\(result.status.rawValue)"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let target = row.target {
                            Text(verbatim: target.names)
                            ForEach(target.configuredPaths, id: \.self) { path in
                                Text(verbatim: path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(verbatim: URL(fileURLWithPath: target.resolvedParent).appendingPathComponent(row.name).path)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if let message = row.result?.message {
                            Text(verbatim: message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowSurface(index: index)
                }
                .listStyle(.inset)
            }
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            if isBusy && !isRunning && rows.isEmpty { ListLoadingSkeleton(rowCount: 3) }
            Divider()
            HStack {
                Spacer()
                if isBusy {
                    Button("common.cancel") { work?.cancel() }
                } else {
                    Button("common.close", action: close).keyboardShortcut(.cancelAction)
                    if rows.isEmpty {
                        Button("skills.batch.review", action: prepare).disabled(action == .assign && targetIDs.isEmpty)
                    } else if isReview {
                        Button("skills.batch.confirm", action: execute).disabled(!rows.contains(where: \.isReady))
                    } else if rows.contains(where: { $0.result?.canRetry == true }) {
                        Button("skills.batch.retry", action: retry)
                    }
                }
            }
        }
        .padding(20)
        .task {
            do { targets = try await viewModel.libraryEnvironment?.assignments.targets() ?? [] }
            catch { message = error.localizedDescription }
        }
        .onDisappear { if !isRunning { work?.cancel() } }
    }

    /// 服务在 Direct 环境内惰性创建；预览与执行复用同一单项协调器。
    private var service: SkillBatchAssignmentService? { viewModel.libraryEnvironment?.batchAssignments }

    private func prepare() {
        guard let service, !isBusy else { return }
        let action = action
        let targetIDs = targetIDs
        isBusy = true
        work = Task {
            defer { isBusy = false }
            do {
                let prepared = try await service.prepare(entryIDs: entryIDs, action: action, targetIDs: targetIDs)
                guard !Task.isCancelled else { return }
                rows = prepared
                isReview = true
            } catch { message = error.localizedDescription }
        }
    }

    private func retry() {
        guard let service, !isBusy else { return }
        isBusy = true
        work = Task {
            defer { isBusy = false }
            do {
                rows = try await service.retryPreview(rows)
                isReview = true
            } catch { message = error.localizedDescription }
        }
    }

    private func execute() {
        guard let service, !isBusy else { return }
        isBusy = true
        isRunning = true
        work = Task {
            rows = await service.execute(rows) { event in
                switch event {
                case .started(let id): runningID = id
                case .finished(let id, let result):
                    if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].result = result }
                    runningID = nil
                }
            }
            isBusy = false
            isRunning = false
            isReview = false
            viewModel.refreshLibrary()
        }
    }
}
