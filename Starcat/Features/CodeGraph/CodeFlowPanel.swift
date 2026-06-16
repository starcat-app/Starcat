//
//  CodeFlowPanel.swift
//  Starcat
//
//  CodeFlow 执行面板：选择分支、检查生成版本、展示流水线并打开或重新生成图谱。
//

import SwiftUI

struct CodeFlowPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CodeFlowViewModel
    @State private var showsDetails: Bool
    private let repo: Repo

    init(repo: Repo) {
        self.repo = repo
        let viewModel = CodeFlowViewModel(repo: repo)
        _viewModel = State(initialValue: viewModel)
        _showsDetails = State(initialValue: viewModel.storedProject != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    branchSection
                    versionBanner
                    overviewCard

                    if case .failed(let message) = viewModel.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    DisclosureGroup("codeFlow.panel.executionDetails", isExpanded: $showsDetails) {
                        VStack(spacing: 0) {
                            ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                                executionRow(step)
                                if index < viewModel.steps.count - 1 {
                                    Divider().padding(.leading, 34)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    .font(.callout)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 520)

            Divider()
            footer
        }
        .frame(width: 520)
        .task { await viewModel.prepare() }
        .onDisappear { viewModel.cancel() }
        .onChange(of: viewModel.state) { _, state in
            if case .failed = state { showsDetails = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("codeFlow.panel.title").font(.headline)
                Text(repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
            .help("common.close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var branchSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("codeFlow.panel.branch.title").font(.callout.weight(.medium))
                Text("codeFlow.panel.branch.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isLoadingBranches {
                ProgressView().controlSize(.small)
            } else {
                CodeFlowBranchPicker(
                    branches: viewModel.branches,
                    selection: viewModel.selectedBranchName,
                    onSelect: viewModel.selectBranch
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var versionBanner: some View {
        switch viewModel.versionStatus {
        case .unknown:
            EmptyView()
        case .checking:
            Label("codeFlow.version.checking", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .current:
            Label("codeFlow.version.current", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .updateAvailable(let generated, let latest):
            Label("codeFlow.version.updateAvailableFormat \(generated) \(latest)", systemImage: "arrow.up.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .branchChanged(let generated, let selected):
            Label("codeFlow.version.branchChangedFormat \(generated) \(selected)", systemImage: "arrow.triangle.branch")
                .foregroundStyle(.orange)
                .font(.caption)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewRow(
                titleKey: "codeFlow.overview.download.title",
                detailKey: "codeFlow.overview.download.detail",
                statuses: ["resolveRevision", "download"]
            )
            Divider().padding(.leading, 34)
            overviewRow(
                titleKey: "codeFlow.overview.prepare.title",
                detailKey: "codeFlow.overview.prepare.detail",
                statuses: ["generatePage"]
            )
            Divider().padding(.leading, 34)
            overviewRow(
                titleKey: "codeFlow.overview.openBrowser.title",
                detailKey: "codeFlow.overview.openBrowser.detail",
                statuses: ["openBrowser", "browserAnalysis"]
            )
        }
        .padding(.horizontal, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerStatus).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if isRunning { Button("common.cancel") { viewModel.cancel() } }
            if viewModel.storedProject != nil, !isRunning {
                Button("codeFlow.action.regenerate") { viewModel.regenerate() }
                    .disabled(!viewModel.canGenerate)
            }
            Button(actionTitle) { viewModel.start() }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || (viewModel.storedProject == nil && !viewModel.canGenerate))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isRunning: Bool {
        switch viewModel.state {
        case .downloading, .preparing, .opening: return true
        default: return false
        }
    }

    private var actionTitle: LocalizedStringKey {
        if viewModel.storedProject == nil {
            return isFailed ? "codeFlow.action.retry" : "codeFlow.action.open"
        }
        return "codeFlow.action.openExisting"
    }

    private var isFailed: Bool {
        if case .failed = viewModel.state { return true }
        return false
    }

    private var footerStatus: LocalizedStringKey {
        switch viewModel.state {
        case .idle: return "codeFlow.state.idle"
        case .ready: return "codeFlow.state.ready"
        case .downloading: return "codeFlow.state.downloading"
        case .preparing: return "codeFlow.state.preparing"
        case .opening: return "codeFlow.state.opening"
        case .succeeded: return "codeFlow.state.succeeded"
        case .failed: return "codeFlow.state.failed"
        }
    }

    private func overviewRow(
        titleKey: LocalizedStringKey,
        detailKey: LocalizedStringKey,
        statuses ids: Set<String>
    ) -> some View {
        let rows = viewModel.steps.filter { ids.contains($0.id) }
        let status: CodeFlowViewModel.RuntimeStepStatus
        if rows.contains(where: { $0.status == .failed }) { status = .failed }
        else if rows.contains(where: { $0.status == .running }) { status = .running }
        else if rows.allSatisfy({ $0.status == .succeeded || $0.status == .handedOff }) { status = .succeeded }
        else { status = .pending }

        return HStack(spacing: 12) {
            statusIcon(status)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleKey).font(.callout.weight(.medium))
                Text(detailKey).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status == .running { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 11)
    }

    private func executionRow(_ step: CodeFlowViewModel.RuntimeStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(step.status).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.callout.weight(.medium))
                Text(step.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let duration = step.durationMilliseconds {
                Text("\(duration) ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            } else if step.status == .running {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func statusIcon(_ status: CodeFlowViewModel.RuntimeStepStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .handedOff:
            Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct CodeFlowBranchPicker: View {
    let branches: [CodeFlowBranch]
    let selection: String
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var query = ""

    private var filtered: [CodeFlowBranch] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? branches : branches.filter { $0.name.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                if selection.isEmpty {
                    Text("codeFlow.branchPicker.selectPrompt").lineLimit(1)
                } else {
                    Text(selection).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                TextField("codeFlow.branchPicker.searchPlaceholder", text: $query)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { branch in
                            Button {
                                onSelect(branch.name)
                                isPresented = false
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark")
                                        .opacity(branch.name == selection ? 1 : 0)
                                        .frame(width: 14)
                                    Text(branch.name).lineLimit(1)
                                    Spacer()
                                    Text(branch.shortSHA).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(width: 300, height: 240)
            }
            .padding(10)
            .appLocaleEnvironment()
        }
    }
}
