//
//  RAGInferenceBackendCard.swift
//  Starcat
//
//  RAG 设置页的推理后端选择行：统一展示选中态、CLI 安装状态、版本和恢复入口。
//

import SwiftUI

/// 单个 RAG 推理后端状态卡片。
struct RAGInferenceBackendCard: View {
    let backend: RAGInferenceBackend
    let inspection: RAGCLIRuntimeInspection?
    let isSelected: Bool
    let interfaceScale: InterfaceScale
    let onSelect: () -> Void

    private var isSelectable: Bool {
        backend == .api || inspection?.isAvailable == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(10)) {
            Button(action: onSelect) {
                HStack(spacing: interfaceScale.scaled(12)) {
                    backendIcon

                    VStack(alignment: .leading, spacing: interfaceScale.scaled(2)) {
                        Text(LocalizedStringKey(backend.titleKey))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(LocalizedStringKey(backend.hintKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: interfaceScale.scaled(8))
                    statusBadge

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        // 17pt semibold 在卡片行里比标题和状态 pill 都重，收到
                        // 15pt medium 与设置页 icon-only glyph 同级。
                        .font(interfaceScale.font(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!isSelectable)

            if backend.isCLI {
                Divider()
                cliMetadata
            }
        }
        .padding(interfaceScale.scaled(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        // 未选中时沿用外层原生 Form 的分组底色，避免旧卡片灰底叠出另一层背景。
        .background(
            isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.52) : Color.secondary.opacity(0.16),
                    lineWidth: isSelected ? 1 : 0.5
                )
        }
        .opacity(isSelectable || isSelected ? 1 : 0.76)
        .accessibilityElement(children: .contain)
    }

    private var backendIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
            switch backend {
            case .api:
                Image(systemName: backend.systemImage)
                    .font(interfaceScale.font(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            case .codexCLI:
                // OpenAI 未公开独立 Codex 矢量标识，因此复用官方 Blossom，并以模板模式适配明暗主题。
                Image("chatgpt")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: interfaceScale.scaled(22), height: interfaceScale.scaled(22))
            case .claudeCLI:
                // 卡片标题已显示产品名，这里使用 Anthropic 官方 Claude Spark，避免重复完整字标。
                Image("claudecode")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: interfaceScale.scaled(22), height: interfaceScale.scaled(22))
            }
        }
        .frame(width: interfaceScale.scaled(36), height: interfaceScale.scaled(36))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch backend {
        case .api:
            RAGBackendStatusBadge(
                titleKey: "rag.workspace.inference.status.builtIn",
                tint: .accentColor,
                interfaceScale: interfaceScale
            )
        case .codexCLI, .claudeCLI:
            switch inspection ?? .checking {
            case .checking:
                HStack(spacing: interfaceScale.scaled(5)) {
                    ProgressView()
                        .controlSize(.small)
                    Text("rag.workspace.inference.status.checking")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            case .available:
                RAGBackendStatusBadge(
                    titleKey: "rag.workspace.inference.status.ready",
                    tint: .green,
                    interfaceScale: interfaceScale
                )
            case .notInstalled:
                RAGBackendStatusBadge(
                    titleKey: "rag.workspace.inference.status.notInstalled",
                    tint: .orange,
                    interfaceScale: interfaceScale
                )
            case .failed:
                RAGBackendStatusBadge(
                    titleKey: "rag.workspace.inference.status.failed",
                    tint: .red,
                    interfaceScale: interfaceScale
                )
            }
        }
    }

    @ViewBuilder
    private var cliMetadata: some View {
        switch inspection ?? .checking {
        case .checking:
            Text("rag.workspace.inference.status.checkingDetail")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let executableURL, let version):
            VStack(alignment: .leading, spacing: interfaceScale.scaled(5)) {
                Label {
                    Text(verbatim: version)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark.seal")
                }
                Label {
                    Text(verbatim: executableURL.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(executableURL.path)
                } icon: {
                    Image(systemName: "terminal")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .notInstalled:
            unavailableMetadata(
                detailKey: "rag.workspace.inference.status.notInstalledDetail",
                technicalDetail: nil
            )
        case .failed(let detail):
            unavailableMetadata(
                detailKey: "rag.workspace.inference.status.failedDetail",
                technicalDetail: detail
            )
        }
    }

    private func unavailableMetadata(
        detailKey: LocalizedStringKey,
        technicalDetail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(6)) {
            HStack(alignment: .firstTextBaseline, spacing: interfaceScale.scaled(8)) {
                Text(detailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: interfaceScale.scaled(8))

                if let installationURL = backend.installationURL {
                    Link(destination: installationURL) {
                        Label("rag.workspace.inference.installGuide", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                }
            }

            if let technicalDetail, !technicalDetail.isEmpty {
                Text(verbatim: technicalDetail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if isSelected && !isSelectable {
                Label("rag.workspace.inference.status.selectedUnavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.orange)
            }
        }
    }
}

/// 稳定宽度的状态 pill；颜色只承担可用性语义，不作为装饰。
private struct RAGBackendStatusBadge: View {
    let titleKey: LocalizedStringKey
    let tint: Color
    let interfaceScale: InterfaceScale

    var body: some View {
        Text(titleKey)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, interfaceScale.scaled(8))
            // 垂直内边距 4→3：卡片里和 15pt 勾选图标并排时胶囊更轻，不抢选中态。
            .padding(.vertical, interfaceScale.scaled(3))
            .background(tint.opacity(0.12), in: Capsule())
    }
}
