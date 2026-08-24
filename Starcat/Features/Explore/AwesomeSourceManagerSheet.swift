//
//  AwesomeSourceManagerSheet.swift
//  Starcat
//
//  首次选择与后续管理共用的卡片式 Awesome 来源 Sheet。
//
//  勾选只保存在本地 draft；只有“完成”会写入 Repository。关闭/取消不会改变订阅，也不会
//  完成首次设置。自定义来源的 URL、README 和解析结果始终停留在当前账户数据库。
//

import SwiftUI

struct AwesomeSourceManagerSheet: View {
    let store: AwesomeStore

    @Environment(\.locale) private var locale
    @State private var enabledIDs: Set<String> = []
    @State private var customSourceInput = ""
    @State private var actionError: String?
    @State private var isSaving = false
    @State private var initialized = false
    @State private var pendingConfirmation: AwesomeSourceConfirmation?

    /// 来源选择是桌面宽 Sheet，固定三列比 adaptive 更能保持卡片位置和视觉节奏。
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 280), spacing: 14, alignment: .top),
        count: 3
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    errorBanner
                    sourceGrid
                    customSourceSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 1_000, idealWidth: 1_100, minHeight: 600, idealHeight: 700)
        .task {
            guard !initialized else { return }
            initialized = true
            enabledIDs = Set(store.sources.filter(\.isEnabled).map(\.id))
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            confirmationActions
        } message: {
            confirmationMessage
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("awesome.sources.title")
                    .font(.title3.weight(.semibold))
                Text("awesome.sources.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SheetCloseButton { store.dismissSourceManager() }
        }
        .padding(20)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = actionError ?? store.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var sourceGrid: some View {
        if store.sources.isEmpty, store.isLoading || store.isRefreshing {
            ProgressView("awesome.sources.loading")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if store.sources.isEmpty {
            emptySourceState
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(store.sources) { source in
                    AwesomeSourceCard(
                        source: source,
                        summary: source.localizedSummary(languageCode: locale.language.languageCode?.identifier),
                        isSelected: enabledIDs.contains(source.id),
                        hasRefreshError: store.sourceRefreshErrors[source.id] != nil,
                        onToggle: { toggleSource(source) },
                        onDelete: source.kind == .custom
                            ? { pendingConfirmation = .delete(source) }
                            : nil
                    )
                }
            }
        }
    }

    private var emptySourceState: some View {
        // ContentUnavailableView 在 Sheet 的 ScrollView 中会用自带的大块留白撑开内容，
        // 这里使用紧凑空态，让用户仍能在同一视野内看到自定义来源入口。
        VStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("awesome.sources.empty.title")
                .font(.headline)
            Text("awesome.sources.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("action.retry") {
                Task { await store.presentSourceManager() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toggleSource(_ source: AwesomeSource) {
        guard source.isAvailable else { return }
        if enabledIDs.contains(source.id) {
            enabledIDs.remove(source.id)
        } else {
            enabledIDs.insert(source.id)
        }
    }

    private var customSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("awesome.sources.custom.title")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("awesome.sources.custom.placeholder", text: $customSourceInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCustomSource)
                Button("awesome.sources.custom.add", action: addCustomSource)
                    .disabled(customSourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("common.cancel") { store.dismissSourceManager() }
                .keyboardShortcut(.cancelAction)
            Button("awesome.sources.done") { saveSelection() }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
        }
        .padding(20)
    }

    private func addCustomSource() {
        let value = customSourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isSaving = true
        actionError = nil
        Task {
            defer { isSaving = false }
            do {
                pendingConfirmation = .add(try await store.previewCustomSource(input: value))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func saveCustomSource(_ preview: AwesomeCustomSourcePreview) {
        isSaving = true
        actionError = nil
        pendingConfirmation = nil
        Task {
            defer { isSaving = false }
            do {
                try await store.addCustomSource(preview)
                // 这里只改 Sheet draft；真正订阅仍由底部“完成”统一提交。
                enabledIDs.insert(preview.source.id)
                customSourceInput = ""
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func removeCustomSource(_ source: AwesomeSource) {
        isSaving = true
        actionError = nil
        pendingConfirmation = nil
        Task {
            defer { isSaving = false }
            do {
                try await store.removeCustomSource(id: source.id)
                enabledIDs.remove(source.id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func saveSelection() {
        isSaving = true
        actionError = nil
        Task {
            defer { isSaving = false }
            do {
                if store.hasCompletedSourceSetup {
                    try await store.updateSourceSelection(enabledIDs)
                } else {
                    try await store.completeSourceSelection(enabledIDs)
                }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .add(let preview):
            String(
                format: String.l10n("awesome.sources.custom.confirm.titleFormat"),
                preview.source.displayName
            )
        case .delete(let source):
            String(
                format: String.l10n("awesome.sources.custom.delete.titleFormat"),
                source.displayName
            )
        case nil:
            ""
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch pendingConfirmation {
        case .add(let preview):
            Button("awesome.sources.custom.confirm.add") { saveCustomSource(preview) }
            Button("common.cancel", role: .cancel) { pendingConfirmation = nil }
        case .delete(let source):
            Button("awesome.sources.custom.delete.confirm", role: .destructive) {
                removeCustomSource(source)
            }
            Button("common.cancel", role: .cancel) { pendingConfirmation = nil }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var confirmationMessage: some View {
        switch pendingConfirmation {
        case .add(let preview):
            Text(String(
                format: String.l10n("awesome.sources.custom.confirm.messageFormat"),
                preview.source.githubRepoCount,
                preview.source.externalEntryCount
            ))
        case .delete:
            Text("awesome.sources.custom.delete.message")
        case nil:
            EmptyView()
        }
    }
}

private enum AwesomeSourceConfirmation {
    case add(AwesomeCustomSourcePreview)
    case delete(AwesomeSource)
}
