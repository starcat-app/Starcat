//
//  SkillImportSheet.swift
//  Starcat
//
//  单任务原生导入表单：先读取来源并生成预览，再显式确认入库。
//  不把预览等同于写入许可，关闭窗口也不撤销已进入提交区间的事务。
//

import SwiftUI
import UniformTypeIdentifiers

/// Sheet 只负责一次导入；下载、授权快照和目录提交都留在独立服务中。
struct SkillImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let viewModel: SkillWorkspaceViewModel
    var repositoryImport: SkillRepositoryImportRequest? = nil
    @State private var source = 0
    @State private var repository = ""
    @State private var ref = ""
    @State private var directory = ""
    @State private var localDirectory: URL?
    @State private var showsFolderPicker = false
    @State private var preview: PreparedSkillImport?
    @State private var isBusy = false
    @State private var isCommitting = false
    @State private var message: String?
    @State private var result: SkillOperationResult?
    @State private var work: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("skills.import.title").font(.headline)
                Spacer()
                SheetCloseButton(action: {
                    work?.cancel()
                    if !isCommitting { dismiss() }
                })
                .disabled(isCommitting)
            }
            if result?.isSuccess == true {
                Label("skills.import.success", systemImage: "checkmark.circle")
                    .foregroundStyle(.primary)
            } else if let preview {
                LabeledContent("skills.import.name", value: preview.plan.entry.manifestName)
                Text(verbatim: preview.plan.entry.summary).foregroundStyle(.secondary).lineLimit(3)
                LabeledContent("skills.import.files") {
                    Text(preview.fileCount, format: .number.locale(locale))
                }
                LabeledContent("skills.import.bytes") {
                    Text(preview.plan.fingerprint.byteCount, format: .number.locale(locale))
                }
                Text(verbatim: preview.plan.source.canonicalLocator)
                    .font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                if let commit = preview.plan.revision.upstreamCommit {
                    Text(verbatim: commit).font(.caption.monospaced()).textSelection(.enabled)
                }
            } else if let repositoryImport {
                Text(verbatim: repositoryImport.repo.fullName).font(.headline)
                Text(verbatim: repositoryImport.skill.directory).font(.caption.monospaced()).textSelection(.enabled)
                Text(verbatim: repositoryImport.skill.commitSHA).font(.caption.monospaced()).textSelection(.enabled)
                Text("skills.import.repositoryNotice").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("skills.import.title", selection: $source) {
                    Text("skills.import.local").tag(0)
                    Text("skills.import.github").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().disabled(isBusy)
                if source == 0 {
                    HStack {
                        Text(verbatim: localDirectory?.path ?? "")
                            .font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("skills.import.choose") { showsFolderPicker = true }
                            .disabled(isBusy)
                    }
                } else {
                    TextField("skills.import.repository", text: $repository)
                        .disabled(isBusy)
                    TextField("skills.import.ref", text: $ref)
                        .disabled(isBusy)
                    TextField("skills.import.directory", text: $directory)
                        .disabled(isBusy)
                }
            }
            Text("skills.import.notice").font(.caption).foregroundStyle(.secondary)
            if isBusy {
                ProgressView(isCommitting ? "skills.import.committing" : "skills.import.preparing")
                    .controlSize(.small)
            }
            if let message {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(4).textSelection(.enabled)
            }
            Divider()
            HStack {
                Spacer()
                if result?.isSuccess == true {
                    Button("common.close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("common.cancel") {
                        work?.cancel()
                        if !isCommitting { dismiss() }
                    }
                    .keyboardShortcut(.cancelAction)
                    if let preview {
                        Button("skills.import.confirm") { perform(preview) }
                            .keyboardShortcut(.defaultAction).disabled(isBusy)
                    } else {
                        Button("skills.import.preview", action: prepare)
                            .keyboardShortcut(.defaultAction)
                            .disabled(isBusy || (repositoryImport == nil && (source == 0 ? localDirectory == nil : repository.isEmpty)))
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 520)
        .task { if repositoryImport != nil { prepare() } }
        .fileImporter(isPresented: $showsFolderPicker, allowedContentTypes: [.folder]) { selection in
            switch selection {
            case .success(let url): localDirectory = url
            case .failure(let error): message = error.localizedDescription
            }
        }
        .onDisappear {
            if !isCommitting {
                work?.cancel()
                if let preview, let service = viewModel.libraryEnvironment?.imports {
                    Task { await service.discard(preview) }
                }
            }
        }
    }

    /// 请求参数先取值，异步返回时不混入用户在另一来源表单中的新输入。
    private func prepare() {
        if viewModel.libraryEnvironment == nil { viewModel.startLibrary() }
        guard !isBusy, let service = viewModel.libraryEnvironment?.imports else { return }
        let request = SkillGitHubImportRequest(repository: repository, ref: ref, directory: directory)
        let local = localDirectory
        let useLocal = source == 0
        isBusy = true
        message = nil
        work = Task {
            defer { isBusy = false }
            do {
                let prepared: PreparedSkillImport
                if let repositoryImport {
                    prepared = try await service.prepareRepositorySkill(repositoryImport)
                } else if useLocal {
                    guard let local else { throw SkillImportError.source }
                    prepared = try await service.prepareLocal(local)
                } else { prepared = try await service.prepareGitHub(request) }
                if Task.isCancelled { await service.discard(prepared); return }
                preview = prepared
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    private func perform(_ preview: PreparedSkillImport) {
        guard !isBusy, let service = viewModel.libraryEnvironment?.imports else { return }
        isBusy = true
        isCommitting = true
        work = Task {
            let outcome = await service.execute(preview)
            result = outcome
            message = outcome.isSuccess ? nil : outcome.message
            isBusy = false
            isCommitting = false
            self.preview = nil
            viewModel.refreshLibrary()
        }
    }
}
