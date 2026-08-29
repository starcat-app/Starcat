//
//  ReleaseAssetDownloadCoordinator.swift
//  Starcat
//
//  Release 资产下载 UI 协调：NSSavePanel + Downloader；Finder 打开由 Toast「打开」触发。
//
//  设计参考 `StarredExporter`：面板与网络/落盘分离，View 只 await 结果枚举。
//

import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Release 资产「保存到磁盘」流程协调器。
@MainActor
enum ReleaseAssetDownloadCoordinator {

    enum Outcome: Equatable {
        case saved(URL)
        case cancelled
        case failed(message: String)
    }

    /// 弹保存面板 → 下载。默认不自动弹 Finder；由 Toast「打开」打开保存目录。
    /// - Parameter onProgress: 字节进度 `0...1`，供行内圆形进度环使用。
    static func download(
        asset: ReleaseAsset,
        downloader: (any ReleaseAssetDownloading)? = nil,
        revealInFinder: Bool = false,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> Outcome {
        let worker = downloader ?? ReleaseAssetDownloader()
        let panel = NSSavePanel()
        panel.title = String.l10n("releases.download.savePanel.title")
        panel.message = String.l10n("releases.download.savePanel.message")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = asset.name
        if let type = contentType(for: asset.name) {
            panel.allowedContentTypes = [type]
        }

        let response = panel.runModal()
        guard response == .OK, let destination = panel.url else {
            return .cancelled
        }

        do {
            try await worker.download(asset: asset, to: destination, onProgress: onProgress)
            if revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            return .saved(destination)
        } catch is CancellationError {
            return .cancelled
        } catch let error as ReleaseAssetDownloadError {
            return .failed(message: error.localizedDescription)
        } catch let error as NetworkError {
            return .failed(message: networkMessage(error))
        } catch {
            return .failed(message: String.l10n("releases.download.failed"))
        }
    }

    // MARK: - Helpers

    private static func contentType(for filename: String) -> UTType? {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    private static func networkMessage(_ error: NetworkError) -> String {
        switch error {
        case .unauthorized:
            return String.l10n("releases.download.error.unauthorized")
        case .rateLimited:
            return String.l10n("releases.download.error.rateLimited")
        case .cancelled:
            return String.l10n("releases.download.cancelled")
        default:
            return String.l10n("releases.download.failed")
        }
    }
}

// MARK: - Toast helpers

/// 下载成功 Toast：文案含目录路径，「打开」只打开目录（不选中文件、不打开文件）。
enum ReleaseAssetDownloadToastSupport {
    /// 行回调结果，供父级组 Toast。
    enum Finish: Equatable {
        case saved(URL)
        case failed
    }

    /// 与详情页「添加到知识库」Toast 同高，避免贴底。
    static let bottomPadding: CGFloat = 30
    /// 带路径与操作按钮，略延长可读时间。
    static let duration: TimeInterval = 4.0

    static func successMessage(forFileURL fileURL: URL) -> (message: String, directoryURL: URL) {
        let directoryURL = fileURL.deletingLastPathComponent()
        let displayPath = (directoryURL.path as NSString).abbreviatingWithTildeInPath
        let message = String(
            format: String.l10n("releases.download.savedToFormat"),
            displayPath
        )
        return (message, directoryURL)
    }

    static func openDirectory(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// 父级把行回调转成 Toast 文案 + 可打开目录。
    static func apply(
        _ finish: Finish,
        message: inout String?,
        directoryURL: inout URL?
    ) {
        switch finish {
        case .saved(let fileURL):
            let payload = successMessage(forFileURL: fileURL)
            directoryURL = payload.directoryURL
            message = payload.message
        case .failed:
            directoryURL = nil
            message = String.l10n("releases.download.failed")
        }
    }
}

extension View {
    /// 下载结果 Toast：成功含目录路径 +「打开」；失败仅文案。高度对齐知识库 Toast。
    func releaseAssetDownloadToast(
        message: Binding<String?>,
        directoryURL: Binding<URL?>
    ) -> some View {
        modifier(ReleaseAssetDownloadParentToastModifier(message: message, directoryURL: directoryURL))
    }
}

private struct ReleaseAssetDownloadParentToastModifier: ViewModifier {
    @Binding var message: String?
    @Binding var directoryURL: URL?

    func body(content: Content) -> some View {
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
    }
}
