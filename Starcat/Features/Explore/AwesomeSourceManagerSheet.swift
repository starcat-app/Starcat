//
//  AwesomeSourceManagerSheet.swift
//  Starcat
//
//  首次选择与后续管理共用的卡片式 Awesome 来源 Sheet。
//
//  精选来源勾选只保存在本地 draft；只有“完成”会写入 Repository。自定义来源的“添加”
//  是独立的明确提交动作，校验成功后立即写入并启用，但 URL、README 和解析结果始终只
//  停留在当前账户数据库。
//

import AppKit
import SwiftUI

struct AwesomeSourceManagerSheet: View {
    private enum FocusedInput: Hashable {
        case search
        case customSource
    }

    let store: AwesomeStore

    @Environment(\.locale) private var locale
    @State private var enabledIDs: Set<String> = []
    @State private var customSourceInput = ""
    @State private var searchQuery = ""
    @State private var customSourceError: String?
    @State private var actionError: String?
    @State private var isSaving = false
    @State private var isAddingCustomSource = false
    @State private var initialized = false
    @State private var pendingConfirmation: AwesomeSourceConfirmation?
    @FocusState private var focusedInput: FocusedInput?

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
            // macOS 会默认把 Sheet 中第一个 TextField 设为 first responder。这里等待首帧
            // 挂载完成后清空焦点，只取消“自动聚焦”；用户主动点击时仍保留系统 Focus Ring。
            await Task.yield()
            focusedInput = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
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
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image("AwesomeBrandLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .frame(width: 58, height: 44)
                    .background(.background, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("awesome.sources.title")
                        .font(.title3.weight(.semibold))
                    Text("awesome.sources.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SyncIconButton(
                    isRefreshing: store.isCatalogRefreshing,
                    disabled: store.isCatalogRefreshing || isSaving || isAddingCustomSource,
                    tooltip: String.l10n("explore.refresh.tooltip")
                ) {
                    Task { await store.refreshSourceCatalog() }
                }
                SheetCloseButton { store.dismissSourceManager() }
            }

            TextField("awesome.search.placeholder", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focusedInput, equals: .search)
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
        } else if filteredSources.isEmpty {
            ContentUnavailableView.search(text: searchQuery)
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(filteredSources) { source in
                    AwesomeSourceCard(
                        source: source,
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

    private var filteredSources: [AwesomeSource] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.sources }

        let languageCode = locale.language.languageCode?.identifier
        return store.sources.filter { source in
            [
                source.displayName,
                source.repoFullName,
                source.repoDescription,
                source.localizedSummary(languageCode: languageCode)
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
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
                    .focused($focusedInput, equals: .customSource)
                    .onSubmit(addCustomSource)
                    .disabled(isAddingCustomSource)
                Button(action: addCustomSource) {
                    if isAddingCustomSource {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("awesome.sources.custom.add"))
                    } else {
                        Text("awesome.sources.custom.add")
                    }
                }
                .disabled(customSourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving || isAddingCustomSource)
            }
            if let customSourceError {
                Label(customSourceError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        isAddingCustomSource = true
        customSourceError = nil
        Task {
            defer { isAddingCustomSource = false }
            do {
                let preview = try await store.previewCustomSource(input: value)
                try await store.addCustomSource(preview)
                enabledIDs.insert(preview.source.id)
                customSourceInput = ""
            } catch {
                customSourceError = error.localizedDescription
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
        case .delete:
            Text("awesome.sources.custom.delete.message")
        case nil:
            EmptyView()
        }
    }
}

private enum AwesomeSourceConfirmation {
    case delete(AwesomeSource)
}
