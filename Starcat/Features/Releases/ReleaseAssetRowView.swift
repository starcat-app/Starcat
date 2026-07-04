//
//  ReleaseAssetRowView.swift
//  Starcat
//
//  Release 资产行共用 UI：文件名 / 大小 / 复制链接 / 应用内下载。
//
//  三处消费方：
//  - `ReleaseTimelineView`（compact + 父级 copy toast）
//  - `ActivityDetailView`（standard + CopyFeedbackButton）
//  - `ActivityReleaseDetailContent`（standard）
//

import SwiftUI

struct ReleaseAssetRowView: View {

    enum Layout {
        /// 时间线单行：文件名与大小同一行。
        case compact
        /// 活动页：文件名 + 大小上下叠放。
        case standard
    }

    let asset: ReleaseAsset
    var layout: Layout = .standard
    /// 父视图接管复制反馈（如时间线底部 toast）；nil 时用行内 `CopyFeedbackButton`。
    var onCopyLink: ((String) -> Void)?

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isDownloading = false
    @State private var downloadToast: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ReleaseAssetIcon.systemName(for: asset.name))
                .foregroundStyle(.secondary)
                .font(interfaceScale.font(layout == .compact ? .caption : .iconSmall))
                .frame(width: layout == .compact ? 16 : 18)

            if layout == .compact {
                Text(verbatim: asset.name)
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: asset.name)
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: formattedSize)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if layout == .compact {
                Text(verbatim: formattedSize)
                    .font(interfaceScale.font(.captionSmall, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            copyControl
            downloadButton
        }
        .padding(.horizontal, layout == .compact ? 6 : 0)
        .padding(.vertical, layout == .compact ? 2 : 4)
        .toast(message: $downloadToast, icon: "arrow.down.circle.fill")
    }

    @ViewBuilder
    private var copyControl: some View {
        if let onCopyLink {
            Button {
                onCopyLink(asset.browserDownloadUrl)
            } label: {
                Label("releases.copyDownloadLink", systemImage: "doc.on.clipboard")
                    .font(interfaceScale.font(.captionSmall))
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .help("releases.copyDownloadLink")
        } else {
            CopyFeedbackButton(
                providesContent: { asset.browserDownloadUrl },
                tooltip: "releases.copyDownloadLink"
            ) { didCopy in
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .font(interfaceScale.font(layout == .compact ? .captionSmall : .caption))
                    .foregroundStyle(didCopy ? Color.green : Color.primary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        let label = Group {
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(interfaceScale.font(layout == .compact ? .captionSmall : .caption))
            }
        }
        .frame(width: 18, height: 18)

        if layout == .compact {
            Button { Task { await startDownload() } } label: { label }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .disabled(isDownloading)
                .help("releases.downloadAsset")
        } else {
            Button { Task { await startDownload() } } label: { label }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(isDownloading)
                .help("releases.downloadAsset")
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file)
    }

    private func startDownload() async {
        guard !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }

        let outcome = await ReleaseAssetDownloadCoordinator.download(asset: asset)
        switch outcome {
        case .saved:
            downloadToast = "releases.download.success"
        case .cancelled:
            break
        case .failed:
            downloadToast = "releases.download.failed"
        }
    }
}

// MARK: - Icon helper

enum ReleaseAssetIcon {
    static func systemName(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".dmg") { return "internaldrive" }
        if lower.hasSuffix(".pkg") { return "shippingbox.fill" }
        if lower.hasSuffix(".zip") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return "doc.zipper" }
        if lower.hasSuffix(".exe") || lower.hasSuffix(".msi") { return "pc" }
        if lower.hasSuffix(".deb") || lower.hasSuffix(".rpm") || lower.hasSuffix(".appimage") { return "terminal" }
        if lower.hasSuffix(".app") { return "macwindow" }
        return "doc"
    }
}
