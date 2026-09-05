//
//  AmbientRootView.swift
//  Starcat
//
//  AppKit hosting root：统一承载 geometry debounce、Reduce Motion 与加载四态。
//  固定深色媒体画布是本功能的明确视觉例外，不改变 Starcat 其它窗口的系统主题。
//

import SwiftUI

/// Ambient 全屏 SwiftUI 根视图。
struct AmbientRootView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var stableMetrics: AmbientGridMetrics?

    let viewModel: AmbientViewModel
    let onExit: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let candidateMetrics = AmbientGridMetrics(size: proxy.size)
            let displayedMetrics = stableMetrics ?? candidateMetrics
            let candidateLayout = candidateMetrics.isUsable
                ? candidateMetrics.layout(displayScale: displayScale)
                : nil

            ZStack {
                Color.black.ignoresSafeArea()
                content(metrics: displayedMetrics)
            }
            .task(id: candidateLayout) {
                guard let candidateLayout else { return }
                // 全屏切换会连续送出过渡 geometry；短 debounce 可避免反复重建整张网格。
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                stableMetrics = candidateMetrics
                viewModel.configure(layout: candidateLayout, reduceMotion: reduceMotion)
            }
        }
        .overlay(alignment: .topTrailing) {
            AmbientExitButton(action: onExit)
                .padding(18)
        }
        .onChange(of: reduceMotion) { _, newValue in
            viewModel.updateReduceMotion(newValue)
        }
        .onExitCommand(perform: onExit)
    }

    @ViewBuilder
    private func content(metrics: AmbientGridMetrics) -> some View {
        switch viewModel.state {
        case .idle, .loading:
            AmbientStatusView(kind: .loading, onRetry: nil)
        case .empty:
            AmbientStatusView(kind: .empty, onRetry: nil)
        case .failed:
            AmbientStatusView(kind: .failed, onRetry: viewModel.retry)
        case .loaded(let snapshots):
            AmbientGridView(
                snapshots: snapshots,
                metrics: metrics,
                changedSlotIDs: viewModel.changedSlotIDs,
                flipDuration: AmbientGridConfig.defaultFlipDuration,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// loading / empty / failed 的低干扰居中状态。
private struct AmbientStatusView: View {
    enum Kind: Equatable {
        case loading
        case empty
        case failed

        var systemImage: String {
            switch self {
            case .loading: ""
            case .empty: "sparkles"
            case .failed: "exclamationmark.triangle"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .loading: "ambient.loading"
            case .empty: "ambient.empty.title"
            case .failed: "ambient.error.title"
            }
        }

        var messageKey: LocalizedStringKey? {
            switch self {
            case .loading: nil
            case .empty: "ambient.empty.message"
            case .failed: "ambient.error.message"
            }
        }
    }

    let kind: Kind
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if kind == .loading {
                ProgressView()
                    .controlSize(.large)
                Text(kind.titleKey)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: kind.systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(kind.titleKey)
                    .font(.title2)
                    .bold()
                    .foregroundStyle(.primary)
                if let messageKey = kind.messageKey {
                    Text(messageKey)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let onRetry {
                    Button("ambient.retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 视觉上只显示图标，但保留本地化文本供 VoiceOver 与 Voice Control 使用。
private struct AmbientExitButton: View {
    let action: () -> Void

    var body: some View {
        Button("ambient.exit", systemImage: "xmark.circle.fill", action: action)
            .labelStyle(.iconOnly)
            .font(.title2)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ambient.exit")
    }
}
