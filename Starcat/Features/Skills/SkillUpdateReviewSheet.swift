//
//  SkillUpdateReviewSheet.swift
//  Starcat
//
//  固定工作区展示 B/L/R 文件证据与原文。进入写入后才禁止关闭，
//  不用默认勾选的覆盖选项绕过本地修改保护。
//

import SwiftUI

struct SkillUpdateReviewSheet: View {
    let viewModel: SkillWorkspaceViewModel
    let entryID: UUID
    let rollback: Bool
    let close: () -> Void
    @State private var preview: PreparedSkillUpdate?
    @State private var isBusy = true
    @State private var isCommitting = false
    @State private var approvedLocalChanges = false
    @State private var manifest = 1
    @State private var result: SkillOperationResult?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringKey(rollback ? "skills.update.rollback" : "skills.update.review")).font(.headline)
                Spacer()
                SheetCloseButton(action: close).disabled(isCommitting)
            }
            if let preview {
                Text(verbatim: preview.content.plan.entry.manifestName).font(.title3)
                if let commit = preview.content.plan.revision.upstreamCommit {
                    Text(verbatim: commit).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if preview.hasLocalChanges {
                    Text("skills.update.localChanges").font(.caption).foregroundStyle(.secondary)
                    Toggle("skills.update.backup", isOn: $approvedLocalChanges).disabled(isBusy || result != nil)
                }
                if preview.isUnchanged { Text("skills.update.same").foregroundStyle(.secondary) }
                List {
                    Section("skills.update.local") { differences(preview.localDifferences) }
                    Section("skills.update.remote") { differences(preview.remoteDifferences) }
                    if !preview.assignments.isEmpty {
                        Section("skills.assignment.title") {
                            ForEach(Array(preview.assignments.enumerated()), id: \.element.id) { index, assignment in
                                VStack(alignment: .leading) {
                                    Text(verbatim: assignment.target.names)
                                    Text(verbatim: assignment.targetPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .listRowSurface(index: index)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                Picker("SKILL.md", selection: $manifest) {
                    Text("skills.update.base").tag(0).disabled(preview.baseManifest == nil)
                    Text("skills.update.local").tag(1)
                    Text("skills.update.remote").tag(2)
                }
                .pickerStyle(.segmented)
                ScrollView {
                    Text(verbatim: manifest == 0 ? preview.baseManifest ?? "" : manifest == 1 ? preview.localManifest : preview.remoteManifest)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 155)
                .nativeDetailTransition(value: manifest)
            } else {
                Spacer()
                if isBusy { ListLoadingSkeleton(rowCount: 5, rowHeight: 48) }
                Spacer()
            }
            if let result {
                Text(LocalizedStringKey("skills.operation.result.\(result.status.rawValue)")).foregroundStyle(.secondary)
            }
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
            if isBusy && preview != nil { ProgressView().controlSize(.small) }
            Divider()
            HStack {
                Spacer()
                Button("common.close", action: close).disabled(isCommitting).keyboardShortcut(.cancelAction)
                if let preview, result == nil {
                    if preview.hasLocalChanges {
                        Button("skills.update.keepCopy") { saveCopy(preview) }.disabled(isBusy)
                    }
                    Button("skills.update.confirm") { execute(preview) }
                        .disabled(isBusy || (preview.hasLocalChanges && !approvedLocalChanges))
                }
            }
        }
        .padding(20)
        .task {
            guard let service = viewModel.libraryEnvironment?.contentUpdates else { isBusy = false; return }
            defer { isBusy = false }
            do {
                let prepared = if rollback { try await service.prepareRollback(entryID: entryID) }
                    else { try await service.prepare(entryID: entryID) }
                if Task.isCancelled { await service.discard(prepared) }
                else { preview = prepared }
            } catch { message = error.localizedDescription }
        }
        .onDisappear {
            if let preview, let service = viewModel.libraryEnvironment?.contentUpdates {
                Task { await service.discard(preview) }
            }
        }
    }

    private func differences(_ files: [SkillFileDifference]) -> some View {
        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
            HStack {
                Text(verbatim: file.path).font(.caption.monospaced())
                Spacer()
                Text(LocalizedStringKey("skills.update.diff.\(file.kind.rawValue)")).foregroundStyle(.secondary)
            }
            .listRowSurface(index: index)
        }
    }

    private func execute(_ preview: PreparedSkillUpdate) {
        guard let service = viewModel.libraryEnvironment?.contentUpdates, !isBusy else { return }
        isBusy = true
        isCommitting = true
        let approved = approvedLocalChanges
        Task {
            let outcome = await service.execute(preview, replacingLocalChanges: approved)
            result = outcome
            message = outcome.message
            isBusy = false
            isCommitting = false
            viewModel.refreshLibrary()
        }
    }

    private func saveCopy(_ preview: PreparedSkillUpdate) {
        guard let service = viewModel.libraryEnvironment?.contentUpdates, !isBusy else { return }
        isBusy = true
        isCommitting = true
        Task {
            let outcome = await service.saveLocalCopy(preview)
            message = outcome.isSuccess ? String.l10n("skills.operation.result.succeeded") : outcome.message
            isBusy = false
            isCommitting = false
            viewModel.refreshLibrary()
        }
    }
}
