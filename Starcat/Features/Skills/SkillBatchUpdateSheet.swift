//
//  SkillBatchUpdateSheet.swift
//  Starcat
//
//  固定选择的批量更新审核。条目结果与当前运行项分开表达；
//  重试回到审核，用户可以逐项查看冻结版本、正文和受影响分配。
//

import SwiftUI

struct SkillBatchUpdateSheet: View {
    let viewModel: SkillWorkspaceViewModel
    let entryIDs: [UUID]
    let close: () -> Void
    @State private var rows: [SkillBatchUpdateRow] = []
    @State private var selectedID: UUID?
    @State private var manifest = 2
    @State private var runningID: UUID?
    @State private var isBusy = false
    @State private var isRunning = false
    @State private var isReview = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?

    private var service: SkillBatchUpdateService? { viewModel.libraryEnvironment?.batchUpdates }
    private var selected: PreparedSkillUpdate? { rows.first { $0.id == selectedID }?.preview }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("skills.update.batch.title").font(.headline)
                Spacer()
                SheetCloseButton(action: close).disabled(isBusy)
            }
            Text("skills.update.batch.notice").font(.caption).foregroundStyle(.secondary)
            Text(verbatim: "\(rows.filter { $0.result != nil }.count)/\(rows.count)").monospacedDigit()
            List(selection: $selectedID) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: row.name).font(.headline)
                            Spacer()
                            if row.id == runningID { ProgressView().controlSize(.small) }
                            if let result = row.result {
                                Text(LocalizedStringKey("skills.operation.result.\(result.status.rawValue)")).foregroundStyle(.secondary)
                            }
                        }
                        if let preview = row.preview {
                            if let commit = preview.content.plan.revision.upstreamCommit {
                                Text(verbatim: commit).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if preview.isUnchanged { Text("skills.update.same").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let error = row.result?.message {
                            Text(verbatim: error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .tag(row.id)
                }
            }
            .listStyle(.inset)
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("skills.update.remote").font(.headline)
                        ForEach(selected.remoteDifferences) { file in
                            HStack {
                                Text(verbatim: file.path).font(.caption.monospaced())
                                Spacer()
                                Text(LocalizedStringKey("skills.update.diff.\(file.kind.rawValue)")).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(selected.assignments) { assignment in
                            Text(verbatim: "\(assignment.target.names) · \(assignment.targetPath)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                Picker("SKILL.md", selection: $manifest) {
                    Text("skills.update.base").tag(0).disabled(selected.baseManifest == nil)
                    Text("skills.update.local").tag(1)
                    Text("skills.update.remote").tag(2)
                }
                .pickerStyle(.segmented)
                ScrollView {
                    Text(verbatim: manifest == 0 ? selected.baseManifest ?? "" : manifest == 1 ? selected.localManifest : selected.remoteManifest)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
            }
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            if isBusy && !isRunning { ProgressView("skills.import.preparing").controlSize(.small) }
            Divider()
            HStack {
                Spacer()
                if isBusy {
                    Button("common.cancel") { work?.cancel() }
                } else {
                    Button("common.close", action: close).keyboardShortcut(.cancelAction)
                    if isReview {
                        Button("skills.batch.confirm", action: execute).disabled(!rows.contains(where: \.isReady))
                    } else if rows.contains(where: { $0.result?.canRetry == true }) {
                        Button("skills.batch.retry") { prepare(retrying: true) }
                    }
                }
            }
        }
        .padding(20)
        .task { prepare(retrying: false) }
        .onDisappear {
            if !isRunning {
                work?.cancel()
                if let service { let rows = rows; Task { await service.discard(rows) } }
            }
        }
    }

    /// 关闭前等待准备取消收尾，防止丢失临时下载的所有权。
    private func prepare(retrying: Bool) {
        guard let service, !isBusy else { return }
        isBusy = true
        work = Task {
            defer { isBusy = false }
            do {
                let prepared = if retrying { try await service.retryPreview(rows) }
                    else { try await service.prepare(entryIDs: entryIDs) }
                if Task.isCancelled { await service.discard(prepared); return }
                rows = prepared
                selectedID = rows.first(where: \.isReady)?.id ?? rows.first?.id
                isReview = rows.contains(where: \.isReady)
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
