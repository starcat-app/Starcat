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

    @Environment(\.colorScheme) private var colorScheme

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
                            .font(ragFont(.body, scale: interfaceScale, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(LocalizedStringKey(backend.hintKey))
                            .font(ragFont(.caption, scale: interfaceScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: interfaceScale.scaled(8))
                    statusBadge

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(interfaceScale.font(size: 17, weight: .semibold))
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
        .background(
            isSelected
                ? Color.accentColor.opacity(0.10)
                : StarcatSurface.raisedCard(colorScheme: colorScheme),
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
            Image(systemName: backend.systemImage)
                .font(interfaceScale.font(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
                        .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
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
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
        case .available(let executableURL, let version):
            VStack(alignment: .leading, spacing: interfaceScale.scaled(5)) {
                Label {
                    Text(verbatim: version)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "checkmark.seal")
                }
                Label {
                    Text(verbatim: executableURL.path)
                        .font(ragFont(.caption, scale: interfaceScale, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(executableURL.path)
                } icon: {
                    Image(systemName: "terminal")
                }
            }
            .font(ragFont(.caption, scale: interfaceScale))
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
                    .font(ragFont(.caption, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: interfaceScale.scaled(8))

                if let installationURL = backend.installationURL {
                    Link(destination: installationURL) {
                        Label("rag.workspace.inference.installGuide", systemImage: "arrow.up.right.square")
                            .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
                    }
                }
            }

            if let technicalDetail, !technicalDetail.isEmpty {
                Text(verbatim: technicalDetail)
                    .font(ragFont(.caption, scale: interfaceScale, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if isSelected && !isSelectable {
                Label("rag.workspace.inference.status.selectedUnavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption, scale: interfaceScale, weight: .medium))
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
            .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, interfaceScale.scaled(8))
            .padding(.vertical, interfaceScale.scaled(4))
            .background(tint.opacity(0.12), in: Capsule())
    }
}
