//
//  CCSwitchImportPreviewSheet.swift
//  Starcat
//
//  从 CC Switch 导入 AI Provider 的预览 / 进度 / 结果 Sheet。
//
//  关键约束：
//  - 确认前不写 Keychain。可导项默认全选。
//  - 导入循环由调用方串行执行 `testAndFetchModels`；关闭按钮在进度期间取消 Task。
//  - 根视图必须 `.appLocaleEnvironment()`；右上角走 `SheetCloseButton`。
//

import SwiftUI

/// 一次导入会话。用 UUID 做 sheet identity，避免同一路径再次导入时不弹出。
struct CCSwitchImportSession: Identifiable {
    let id = UUID()
    let preview: CCSwitchImportPreview
}

struct CCSwitchImportResultRow: Identifiable, Equatable {
    var id: String
    var displayName: String
    var profileID: String
    var succeeded: Bool
    var statusText: String
}

struct CCSwitchImportOutcome: Equatable {
    var succeeded: [CCSwitchImportResultRow]
    var failed: [CCSwitchImportResultRow]
    var cancelled: Bool
}

/// CC Switch 导入预览 Sheet。
struct CCSwitchImportPreviewSheet: View {
    let preview: CCSwitchImportPreview
    let onImport: (
        _ candidates: [CCSwitchImportCandidate],
        _ progress: @MainActor (Int, Int, String) -> Void
    ) async -> CCSwitchImportOutcome
    let onSelectProfile: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<String>
    @State private var phase: Phase = .preview
    @State private var progressIndex = 0
    @State private var progressTotal = 0
    @State private var progressName = ""
    @State private var outcome: CCSwitchImportOutcome?
    @State private var importTask: Task<Void, Never>?

    private enum Phase: Hashable {
        case preview
        case progress
        case result
    }

    init(
        preview: CCSwitchImportPreview,
        onImport: @escaping (
            _ candidates: [CCSwitchImportCandidate],
            _ progress: @MainActor (Int, Int, String) -> Void
        ) async -> CCSwitchImportOutcome,
        onSelectProfile: @escaping (String) -> Void
    ) {
        self.preview = preview
        self.onImport = onImport
        self.onSelectProfile = onSelectProfile
        _selectedIDs = State(initialValue: Set(preview.importable.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .nativeDetailTransition(value: phase)
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .appLocaleEnvironment()
        .onDisappear {
            importTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            Text("settings.ai.provider.importCCSwitch.sheetTitle")
                .font(.headline)
            Spacer(minLength: 12)
            SheetCloseButton(
                action: close,
                frameSize: 28
            )
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preview:
            previewList
        case .progress:
            VStack(spacing: 12) {
                ProgressView()
                Text("\(progressIndex) / \(progressTotal)")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(progressName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        case .result:
            resultList
        }
    }

    private var previewList: some View {
        List {
            if !preview.importable.isEmpty {
                Section {
                    ForEach(preview.importable) { candidate in
                        Toggle(isOn: binding(for: candidate.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.displayName)
                                Text("\(candidate.provider.defaultProfileName) · \(candidate.baseURL) · \(candidate.maskedKey)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .listRowSurface(isSelected: selectedIDs.contains(candidate.id))
                    }
                }
            }
            if !preview.skipped.isEmpty {
                Section("settings.ai.provider.importCCSwitch.skippedSection") {
                    ForEach(preview.skipped) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.sourceName)
                            if let reason = candidate.skipReason {
                                Text(LocalizedStringKey(reason))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowSurface()
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var resultList: some View {
        let outcome = outcome ?? CCSwitchImportOutcome(succeeded: [], failed: [], cancelled: false)
        return List {
            if outcome.cancelled {
                Text("settings.ai.provider.importCCSwitch.result.cancelled")
                    .foregroundStyle(.secondary)
            }
            if !outcome.succeeded.isEmpty {
                Section("settings.ai.provider.importCCSwitch.result.success") {
                    ForEach(outcome.succeeded) { row in
                        Text(row.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowSurface()
                    }
                }
            }
            if !outcome.failed.isEmpty {
                Section("settings.ai.provider.importCCSwitch.result.failed") {
                    ForEach(outcome.failed) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayName)
                                Text(row.statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("settings.ai.provider.importCCSwitch.selectProvider") {
                                onSelectProfile(row.profileID)
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .listRowSurface()
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .preview:
                Button("settings.ai.provider.importCCSwitch.confirm") {
                    startImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidates.isEmpty)
            case .progress:
                EmptyView()
            case .result:
                Button("settings.ai.provider.importCCSwitch.done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private var selectedCandidates: [CCSwitchImportCandidate] {
        preview.importable.filter { selectedIDs.contains($0.id) }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }

    private func startImport() {
        let candidates = selectedCandidates
        guard !candidates.isEmpty else { return }
        phase = .progress
        progressTotal = candidates.count
        progressIndex = 0
        importTask = Task { @MainActor in
            let result = await onImport(candidates) { index, total, name in
                progressIndex = index
                progressTotal = total
                progressName = name
            }
            outcome = result
            phase = .result
        }
    }

    private func close() {
        importTask?.cancel()
        dismiss()
    }
}
