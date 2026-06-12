//
//  CodeFlowPanel.swift
//  Starcat
//
//  代码图谱入口与执行面板。CodeFlow 在默认浏览器打开，不嵌入 WebView。
//

import SwiftUI

struct CodeFlowButton: View {
    let repo: Repo
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label("代码图谱", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.body)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("使用 CodeFlow 在浏览器中查看代码结构")
        .sheet(isPresented: $isPresented) { CodeFlowPanel(repo: repo) }
    }
}

private struct CodeFlowPanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CodeFlowViewModel

    init(repo: Repo) {
        _viewModel = State(initialValue: CodeFlowViewModel(repo: repo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("CodeFlow 代码图谱", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }

            VStack(alignment: .leading, spacing: 10) {
                stepRow("拉取仓库", step: .cloning)
                stepRow("准备 CodeFlow 页面", step: .preparing)
                stepRow("浏览器打开", step: .opening)
            }

            if case .failed(let message) = viewModel.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !viewModel.log.isEmpty {
                ScrollView {
                    Text(viewModel.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                if isRunning {
                    Button("取消") { viewModel.cancel() }
                } else {
                    Button(actionTitle) { viewModel.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .onDisappear { viewModel.cancel() }
    }

    private var isRunning: Bool {
        switch viewModel.state {
        case .cloning, .preparing, .opening: return true
        default: return false
        }
    }

    private var actionTitle: String {
        switch viewModel.state {
        case .failed: return "重试"
        case .succeeded: return "重新打开代码图谱"
        default: return "打开代码图谱"
        }
    }

    private func stepRow(_ title: String, step: CodeFlowViewModel.State) -> some View {
        let status = stepStatus(for: step)
        return HStack(spacing: 8) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
                .frame(width: 18)
            Text(title)
            if status == .active { ProgressView().controlSize(.small) }
        }
    }

    private func stepStatus(for step: CodeFlowViewModel.State) -> StepStatus {
        let order: [CodeFlowViewModel.State] = [.cloning, .preparing, .opening]
        guard let target = order.firstIndex(of: step) else { return .pending }
        let current: Int
        switch viewModel.state {
        case .cloning: current = 0
        case .preparing: current = 1
        case .opening: current = 2
        case .succeeded: current = 3
        case .failed, .idle: current = -1
        }
        if current > target { return .completed }
        if current == target { return .active }
        return .pending
    }
}

private enum StepStatus {
    case pending, active, completed

    var systemImage: String {
        switch self {
        case .pending: return "circle"
        case .active: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .active: return .accentColor
        case .completed: return .green
        }
    }
}
