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
            ContentUnavailableView(
                "awesome.sources.empty.title",
                systemImage: "sparkles.rectangle.stack",
                description: Text("awesome.sources.empty.subtitle")
            )
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(store.sources) { source in
                    HStack(alignment: .top, spacing: 6) {
                        sourceCard(source)
                        if source.kind == .custom {
                            Button(role: .destructive) {
                                removeCustomSource(source)
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

    private func sourceCard(_ source: AwesomeSource) -> some View {
        let selected = enabledIDs.contains(source.id)
        return Button {
            guard source.isAvailable else { return }
            if selected { enabledIDs.remove(source.id) } else { enabledIDs.insert(source.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AwesomeSourceImage(source: source)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(source.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if source.featured {
                            Text("awesome.sources.featured")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                    if let summary = source.localizedSummary(languageCode: locale.language.languageCode?.identifier) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(source.repoFullName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(String(format: String.l10n("awesome.sources.repoCountFormat"), source.githubRepoCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !source.isAvailable {
                        Text("awesome.sources.unavailable")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!source.isAvailable)
        .accessibilityLabel(Text(source.displayName))
        .accessibilityValue(Text(selected ? "awesome.sources.selected" : "awesome.sources.notSelected"))
    }

    private var customSourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("awesome.sources.custom.title")
                .font(.headline)
            Text("awesome.sources.custom.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                let previousIDs = Set(store.sources.map(\.id))
                try await store.addCustomSource(input: value)
                if let addedID = Set(store.sources.map(\.id)).subtracting(previousIDs).first {
                    enabledIDs.insert(addedID)
                }
                customSourceInput = ""
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func removeCustomSource(_ source: AwesomeSource) {
        isSaving = true
        actionError = nil
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
}

private struct AwesomeSourceImage: View {
    let source: AwesomeSource

    var body: some View {
        Group {
            if let imageURL = source.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: fallback
                    case .empty: ProgressView()
                    @unknown default: fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var fallback: some View {
        let owner = source.repoFullName.split(separator: "/").first.map(String.init)
        if let owner,
           let avatarURL = URL(string: "https://github.com/\(owner).png?size=104") {
            AsyncImage(url: avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                symbolFallback
            }
        } else {
            symbolFallback
        }
    }

    private var symbolFallback: some View {
        Image(systemName: "sparkles.rectangle.stack")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
    }
}
