//
//  CodebaseMemoryPanel.swift
//  Starcat
//
//  CodebaseMemory 3D 图谱 Sheet UI。
//  布局对齐 CodeFlowPanel（同款 header + ScrollView + footer）。
//
//  关键约束：
//  - Sheet 关闭时不杀 UI 子进程（用户继续在浏览器交互）
//  - App 退出时由 willTerminate 兜底杀（见 StarcatApp）
//  - Pro 门控走 ProPaywallSheet

import SwiftUI

struct CodebaseMemoryPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencies.self) private var dependencies
    @State private var viewModel: CodebaseMemoryViewModel
    @State private var showsDetails: Bool
    @State private var isDetailsHeaderHovered = false
    @State private var paywallContext: ProPaywallContext?

    /// 当前 sheet 载荷中的 repo。
    ///
    /// 这里故意不用 `@State`：repo 是父级 sheet item 的输入，不是 Panel 自己拥有的可变状态。
    /// 每次打开入口都会由 `CodebaseMemorySheetItem.id` 强制重建 Panel，避免旧 ViewModel 串到新 repo。
    private let repo: Repo

    init(repo: Repo) {
        self.repo = repo
        let vm = CodebaseMemoryViewModel(repo: repo)
        _viewModel = State(initialValue: vm)
        _showsDetails = State(initialValue: vm.storedProject != nil)
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

                    executionDetailsCard
                }
                .padding(14)
            }

            Divider()
            footer
        }
        .frame(width: 520)
        .task {
            guard requireAccess() else { return }
            // 即使 SwiftUI 复用 presentation host，也以当前 sheet item 的 repo 重新校准 ViewModel。
            viewModel.refreshRepo(repo: repo)
            await viewModel.prepare()
        }
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .onDisappear { viewModel.cancel() }
        .onChange(of: viewModel.state) { _, state in
            if case .failed = state { showsDetails = true }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    Circle().fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("codebaseMemory.panel.title")
                    .font(.headline)
                Text(repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            SheetCloseButton(
                action: { dismiss() },
                iconFont: .system(size: 16, weight: .medium),
                frameSize: 26
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Branch Section

    private var branchSection: some View {
        HStack(spacing: 8) {
            Text("codebaseMemory.panel.branch.title")
                .font(.callout)
            Spacer()
            if viewModel.isLoadingBranches {
                ProgressView().controlSize(.small)
            } else {
                Picker(
                    selection: Binding(
                        get: { viewModel.selectedBranchName },
                        set: { viewModel.selectBranch($0) }
                    )
                ) {
                    ForEach(viewModel.branches) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Version Banner

    @ViewBuilder
    private var versionBanner: some View {
        switch viewModel.versionStatus {
        case .unknown:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("codebaseMemory.version.checking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .current:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("codebaseMemory.version.current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .updateAvailable(let generated, let latest):
            Label(
                String(format: String.l10n("codebaseMemory.version.updateAvailableFormat"), generated, latest),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        case .branchChanged(let generated, let selected):
            Label(
                String(format: String.l10n("codebaseMemory.version.branchChangedFormat"), generated, selected),
                systemImage: "arrow.triangle.branch"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Overview Card（4 组精简摘要，展开区有详细步骤）

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewRow(
                titleKey: "codebaseMemory.overview.prepare.title",
                detailKey: "codebaseMemory.overview.prepare.detail",
                statuses: [.resolveBinary, .resolveRevision]
            )
            Divider().padding(.leading, 34)
            overviewRow(
                titleKey: "codebaseMemory.overview.download.title",
                detailKey: "codebaseMemory.overview.download.detail",
                statuses: [.download]
            )
            Divider().padding(.leading, 34)
            overviewRow(
                titleKey: "codebaseMemory.overview.index.title",
                detailKey: "codebaseMemory.overview.index.detail",
                statuses: [.extract, .index]
            )
            Divider().padding(.leading, 34)
            overviewRow(
                titleKey: "codebaseMemory.overview.launch.title",
                detailKey: "codebaseMemory.overview.launch.detail",
                statuses: [.startUI, .openBrowser]
            )
        }
        .padding(.horizontal, 14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func overviewRow(
        titleKey: LocalizedStringKey,
        detailKey: LocalizedStringKey,
        statuses: [CodebaseMemoryExecutionStep.ID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                overviewStatusIcon(for: statuses)
                Text(titleKey).font(.callout.weight(.medium))
                Spacer()
            }
            Text(detailKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func overviewStatusIcon(for ids: [CodebaseMemoryExecutionStep.ID]) -> some View {
        let relevant = viewModel.steps.filter { ids.contains($0.id) }
        let hasFailed = relevant.contains { $0.status == .failed }
        let allSucceeded = relevant.allSatisfy { $0.status == .succeeded || $0.status == .skipped || $0.status == .handedOff }
        let anyRunning = relevant.contains { $0.status == .running }
        let allPending = relevant.allSatisfy { $0.status == .pending }

        if hasFailed {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        } else if anyRunning {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        } else if allSucceeded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        } else if allPending {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
    }

    // MARK: - Execution Row（展开区每个步骤的详细信息）

    private var executionDetailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsDetails.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        .animation(.easeInOut(duration: 0.18), value: showsDetails)
                        .frame(width: 14)
                    Text("codebaseMemory.panel.executionDetails")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .background(
                isDetailsHeaderHovered ? Color.secondary.opacity(0.06) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isDetailsHeaderHovered = hovering
                }
            }

            if showsDetails {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                        executionRow(step)
                        if index < viewModel.steps.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: showsDetails)
    }

    private func executionRow(_ step: CodebaseMemoryExecutionStep) -> some View {
        HStack(spacing: 8) {
            Group {
                switch step.status {
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                case .running:
                    ProgressView().controlSize(.small)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .skipped:
                    Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
                case .handedOff:
                    Image(systemName: "arrow.up.forward.circle").foregroundStyle(.blue)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.id.displayTitle)
                    .font(.caption.weight(.medium))
                if let detail = step.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let duration = step.durationMilliseconds {
                Text("\(duration) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.isRunning {
                Button("common.cancel") { viewModel.cancel() }
            }
            if viewModel.storedProject != nil, !viewModel.isRunning {
                Button("codebaseMemory.panel.regenerate") {
                    guard requireAccess() else { return }
                    viewModel.regenerate()
                }
                .disabled(!viewModel.canGenerate)
            }
            Button(actionTitle) {
                guard requireAccess() else { return }
                viewModel.start()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isRunning || (viewModel.storedProject == nil && !viewModel.canGenerate))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var actionTitle: LocalizedStringKey {
        switch viewModel.state {
        case .ready, .succeeded:
            return "codebaseMemory.panel.openInBrowser"
        default:
            if viewModel.storedProject != nil {
                return "codebaseMemory.panel.openInBrowser"
            }
            return "codebaseMemory.panel.start"
        }
    }

    private var footerStatus: String {
        switch viewModel.state {
        case .idle, .preparing:
            return ""
        case .downloading:
            return String.l10n("codebaseMemory.status.downloading")
        case .extracting:
            return String.l10n("codebaseMemory.status.extracting")
        case .indexing:
            return String.l10n("codebaseMemory.status.indexing")
        case .startingUI:
            return String.l10n("codebaseMemory.status.startingUI")
        case .ready:
            return String.l10n("codebaseMemory.status.ready")
        case .succeeded:
            let gen = viewModel.storedProject?.metadata.generation.generationCount ?? 0
            return String(format: String.l10n("codebaseMemory.status.succeededFormat"), gen)
        case .failed:
            return ""
        }
    }

    // MARK: - Pro Gating

    private func requireAccess() -> Bool {
        if viewModel.paywallContext != nil {
            paywallContext = viewModel.paywallContext
            return false
        }
        return true
    }
}

// MARK: - Preview

#if DEBUG
struct CodebaseMemoryPanel_Previews: PreviewProvider {
    static var previews: some View {
        CodebaseMemoryPanel(repo: .makeMinimal(owner: "apple", name: "swift"))
    }
}
#endif
