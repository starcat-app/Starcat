//
//  ReleaseAssetRowView.swift
//  Starcat
//
//  Release 资产行共用 UI：文件名 / 大小 / 复制链接 / 应用内下载。
//
//  三处消费方：
//  - `ReleaseTimelineView`（compact + 父级 copy toast）
//  - `ActivityDetailView`（standard + CopyFeedbackButton）
//  - `ActivityReleaseDetailContent` / 洞察发布节奏（列表斑马纹 + 圆形下载进度）
//
//  下载反馈：
//  - 行内成功态对齐 CopyFeedbackButton：绿色 checkmark.circle.fill，1.5s 复位
//  - Toast 由父级挂底部（含保存目录 +「打开」）；无回调时走行内 toast
//

import SwiftUI

struct ReleaseAssetRowView: View {

    enum Layout {
        /// 时间线单行：文件名与大小同一行。
        case compact
        /// 活动页：文件名 + 大小上下叠放。
        case standard
    }

    /// 下载结束结果；父级用它组路径 Toast。
    typealias DownloadFinish = ReleaseAssetDownloadToastSupport.Finish

    let asset: ReleaseAsset
    var layout: Layout = .standard
    /// 非 nil 时启用斑马纹 + hover 聚焦（列表语境）。
    var rowIndex: Int? = nil
    /// 父视图接管复制反馈（如时间线底部 toast）；nil 时用行内 `CopyFeedbackButton`。
    var onCopyLink: ((String) -> Void)?
    /// 父视图接管下载结果 toast；nil 时用行内 `.toast`。
    var onDownloadFinished: ((DownloadFinish) -> Void)?

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isHovered = false
    /// 保存面板弹出期间也要占住按钮，避免连点；真正的圆环进度见 `downloadProgress`。
    @State private var isDownloadSessionActive = false
    /// nil = 尚未开始传字节；非 nil = 圆形进度 0...1。
    @State private var downloadProgress: Double?
    /// 对齐复制按钮：成功后绿色勾勾 1.5s。
    @State private var didDownloadSucceed = false
    @State private var successResetTask: Task<Void, Never>?
    /// 仅无父级回调时使用。
    @State private var inlineDownloadToast: String?
    @State private var inlineDownloadDirectory: URL?

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
        .padding(.vertical, layout == .compact ? 4 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(listRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: rowIndex == nil ? 0 : 4, style: .continuous))
        .onHover { hovering in
            guard rowIndex != nil else { return }
            isHovered = hovering
        }
        .modifier(ReleaseAssetDownloadToastModifier(
            message: $inlineDownloadToast,
            directoryURL: $inlineDownloadDirectory,
            enabled: onDownloadFinished == nil
        ))
    }

    @ViewBuilder
    private var listRowBackground: some View {
        if let rowIndex {
            // 与 RAG 分片列表同口径：奇数行极淡 primary，hover 用 accent。
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    isHovered
                        ? Color.accentColor.opacity(0.10)
                        : (rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045))
                )
        } else {
            Color.clear
        }
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
        // compact 用 captionSmall、standard 用 caption，进度环直径跟 SF Symbol 字号对齐，
        // 不能铺满外层 18pt 热区，否则会比下载/绿勾图标显大一圈。
        let iconFont = interfaceScale.font(layout == .compact ? .captionSmall : .caption)
        let ringSide: CGFloat = layout == .compact ? 11 : 12
        let label = Group {
            if let downloadProgress {
                ReleaseAssetDownloadProgressRing(progress: downloadProgress, side: ringSide)
            } else if didDownloadSucceed {
                Image(systemName: "checkmark.circle.fill")
                    .font(iconFont)
                    .foregroundStyle(Color.green)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(iconFont)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
        }
        .frame(width: 18, height: 18)

        if layout == .compact {
            Button { Task { await startDownload() } } label: { label }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .disabled(isDownloadSessionActive)
                .help("releases.downloadAsset")
        } else {
            Button { Task { await startDownload() } } label: { label }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(isDownloadSessionActive)
                .help("releases.downloadAsset")
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file)
    }

    private func startDownload() async {
        guard !isDownloadSessionActive else { return }
        isDownloadSessionActive = true
        defer {
            isDownloadSessionActive = false
            downloadProgress = nil
        }

        let outcome = await ReleaseAssetDownloadCoordinator.download(
            asset: asset,
            onProgress: { fraction in
                Task { @MainActor in
                    downloadProgress = fraction
                }
            }
        )
        switch outcome {
        case .saved(let fileURL):
            showDownloadSuccess(fileURL: fileURL)
        case .cancelled:
            break
        case .failed:
            presentFailure()
        }
    }

    private func showDownloadSuccess(fileURL: URL) {
        flashSuccessCheckmark()
        if let onDownloadFinished {
            onDownloadFinished(.saved(fileURL))
            return
        }
        let payload = ReleaseAssetDownloadToastSupport.successMessage(forFileURL: fileURL)
        inlineDownloadDirectory = payload.directoryURL
        inlineDownloadToast = payload.message
    }

    private func presentFailure() {
        if let onDownloadFinished {
            onDownloadFinished(.failed)
            return
        }
        inlineDownloadDirectory = nil
        inlineDownloadToast = String.l10n("releases.download.failed")
    }

    /// 与 CopyFeedbackButton 同口径：1.5s 绿色勾勾后复位。
    private func flashSuccessCheckmark() {
        successResetTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            didDownloadSucceed = true
        }
        successResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) {
                didDownloadSucceed = false
            }
        }
    }
}

// MARK: - Thin progress ring

/// 行内下载进度环。外层仍是 18pt 点击热区，圆环本身按旁路 SF Symbol 字号缩小，
/// 避免铺满热区后比 `arrow.down.circle` / 绿色勾勾显大。
private struct ReleaseAssetDownloadProgressRing: View {
    let progress: Double
    /// 与 compact captionSmall / standard caption 的 glyph 直径对齐。
    let side: CGFloat

    private var lineWidth: CGFloat { max(1, side / 11) }

    var body: some View {
        let clamped = min(1, max(0, progress))
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: side, height: side)
        .accessibilityLabel(Text("releases.downloadAsset"))
        .accessibilityValue(Text("\(Int((clamped * 100).rounded()))%"))
    }
}

// MARK: - Toast gate

/// 有父级 toast 回调时不挂行内 overlay，避免在列表中间「冒泡」。
private struct ReleaseAssetDownloadToastModifier: ViewModifier {
    @Binding var message: String?
    @Binding var directoryURL: URL?
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .toast(
                    message: $message,
                    icon: directoryURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    duration: ReleaseAssetDownloadToastSupport.duration,
                    iconColor: directoryURL == nil ? Color.orange : Color.green,
                    bottomPadding: ReleaseAssetDownloadToastSupport.bottomPadding,
                    actionLabel: directoryURL == nil ? nil : "releases.download.openFolder",
                    onAction: {
                        if let url = directoryURL {
                            ReleaseAssetDownloadToastSupport.openDirectory(url)
                        }
                    }
                )
                .onChange(of: message) { _, newValue in
                    if newValue == nil {
                        directoryURL = nil
                    }
                }
        } else {
            content
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
