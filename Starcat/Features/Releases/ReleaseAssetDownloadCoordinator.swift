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

    /// 弹保存面板 → 下载。默认不自动弹 Finder；由 Toast「打开」在 Finder 中定位文件。
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

/// 下载成功 Toast：文案含目录路径，「打开」在 Finder 中定位到该文件（不打开文件本身）。
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

    static func successMessage(forFileURL fileURL: URL) -> (message: String, fileURL: URL) {
        // 文案仍展示所在目录；「打开」按钮才定位到文件本身。
        let displayPath = (fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let message = String(
            format: String.l10n("releases.download.savedToFormat"),
            displayPath
        )
        return (message, fileURL)
    }

    /// 在 Finder 中定位到文件本身；`NSWorkspace.open(directory)` 只会落到目录不选中文件。
    static func revealInFinder(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    /// 父级把行回调转成 Toast 文案 + 可定位的文件 URL。
    static func apply(
        _ finish: Finish,
        message: inout String?,
        fileURL: inout URL?
    ) {
        switch finish {
        case .saved(let savedFileURL):
            let payload = successMessage(forFileURL: savedFileURL)
            fileURL = payload.fileURL
            message = payload.message
        case .failed:
            fileURL = nil
            message = String.l10n("releases.download.failed")
        }
    }
}

extension View {
    /// 下载结果 Toast：成功含目录路径 +「打开」（定位到文件）；失败仅文案。高度对齐知识库 Toast。
    func releaseAssetDownloadToast(
        message: Binding<String?>,
        fileURL: Binding<URL?>
    ) -> some View {
        modifier(ReleaseAssetDownloadParentToastModifier(message: message, fileURL: fileURL))
    }
}

private struct ReleaseAssetDownloadParentToastModifier: ViewModifier {
    @Binding var message: String?
    @Binding var fileURL: URL?

    func body(content: Content) -> some View {
        content
            .toast(
                message: $message,
                icon: fileURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                duration: ReleaseAssetDownloadToastSupport.duration,
                iconColor: fileURL == nil ? Color.orange : Color.green,
                bottomPadding: ReleaseAssetDownloadToastSupport.bottomPadding,
                actionLabel: fileURL == nil ? nil : "releases.download.openFolder",
                onAction: {
                    if let url = fileURL {
                        ReleaseAssetDownloadToastSupport.revealInFinder(url)
                    }
                }
            )
            .onChange(of: message) { _, newValue in
                if newValue == nil {
                    fileURL = nil
                }
            }
    }
}
