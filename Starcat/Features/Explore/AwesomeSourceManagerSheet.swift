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
import Kingfisher

struct AwesomeSourceManagerSheet: View {
    let store: AwesomeStore

    @Environment(\.locale) private var locale
    @State private var enabledIDs: Set<String> = []
    @State private var customSourceInput = ""
    @State private var actionError: String?
    @State private var isSaving = false
    @State private var initialized = false
    @State private var pendingConfirmation: AwesomeSourceConfirmation?

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 12)
    ]

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
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 620)
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
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.sources) { source in
                    HStack(alignment: .top, spacing: 6) {
                        sourceCard(source)
                        if source.kind == .custom {
                            Button(role: .destructive) {
                                pendingConfirmation = .delete(source)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(Text("awesome.sources.removeCustom"))
                            .accessibilityLabel(Text("awesome.sources.removeCustom"))
                        }
                    }
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

    private func sourceCard(_ source: AwesomeSource) -> some View {
        let selected = enabledIDs.contains(source.id)
        return Button {
            guard source.isAvailable else { return }
            if selected { enabledIDs.remove(source.id) } else { enabledIDs.insert(source.id) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    AwesomeSourceImage(source: source)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(source.displayName)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if source.featured {
                                Label("awesome.sources.featured", systemImage: "sparkles")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                            }
                            Spacer(minLength: 0)
                        }
                        Text(source.repoFullName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let summary = source.localizedSummary(languageCode: locale.language.languageCode?.identifier) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 22, height: 22)
                }

                Divider()

                HStack(spacing: 14) {
                    sourceMetadata(
                        systemImage: "star.fill",
                        value: source.sourceStars.formatted(.number.notation(.compactName))
                    )
                    sourceMetadata(
                        systemImage: "square.stack.3d.up.fill",
                        value: String(
                            format: String.l10n("awesome.sources.repoCountFormat"),
                            source.githubRepoCount
                        )
                    )
                    Spacer(minLength: 0)
                    sourceSyncStatus(source)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: selected ? 2 : 1)
            }
            .shadow(color: Color.black.opacity(selected ? 0.08 : 0.035), radius: 6, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(source.isAvailable ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!source.isAvailable)
        .accessibilityLabel(Text(source.displayName))
        .accessibilityValue(Text(selected ? "awesome.sources.selected" : "awesome.sources.notSelected"))
    }

    private func sourceMetadata(systemImage: String, value: String) -> some View {
        Label(value, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private func sourceSyncStatus(_ source: AwesomeSource) -> some View {
        if !source.isAvailable {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .help(Text("awesome.sources.unavailable"))
                .accessibilityLabel(Text("awesome.sources.unavailable"))
        } else if store.sourceRefreshErrors[source.id] != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .help(Text("awesome.sources.stale"))
                .accessibilityLabel(Text("awesome.sources.stale"))
        } else if let lastSyncedAt = source.lastSyncedAt {
            Label {
                Text(lastSyncedAt, style: .relative)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "clock")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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

private struct AwesomeSourceImage: View {
    let source: AwesomeSource
    @State private var usesOwnerFallback = false

    var body: some View {
        Group {
            if let url = activeURL {
                KFImage(url)
                    .resizable()
                    .placeholder { symbolFallback }
                    .fade(duration: 0.15)
                    .onFailure { _ in
                        if !usesOwnerFallback, ownerAvatarURL != nil {
                            usesOwnerFallback = true
                        }
                    }
                    .scaledToFill()
            } else {
                symbolFallback
            }
        }
        .frame(width: 58, height: 58)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        }
    }

    private var ownerAvatarURL: URL? {
        let owner = source.repoFullName.split(separator: "/").first.map(String.init)
        return owner.flatMap { URL(string: "https://github.com/\($0).png?size=104") }
    }

    private var activeURL: URL? {
        // 首选内容管理图片；首次失败后切到来源 owner avatar。两者都走 Kingfisher
        // 同一内存/磁盘缓存，avatar 再失败时保持 SF Symbol，不进入循环重试。
        guard !usesOwnerFallback else { return ownerAvatarURL }
        return source.imageURL ?? ownerAvatarURL
    }

    private var symbolFallback: some View {
        Image(systemName: "sparkles.rectangle.stack")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }
}
