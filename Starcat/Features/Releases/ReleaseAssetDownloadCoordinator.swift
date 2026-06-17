//
//  ReleaseAssetDownloadCoordinator.swift
//  Starcat
//
//  Release 资产下载 UI 协调：NSSavePanel + Downloader + Finder Reveal。
//
//  设计参考 `StarredExporter`：面板与网络/落盘分离，View 只 await 结果枚举。
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Release 资产「保存到磁盘」流程协调器。
@MainActor
enum ReleaseAssetDownloadCoordinator {

    enum Outcome: Equatable {
        case saved(URL)
        case cancelled
        case failed(message: String)
    }

    /// 弹保存面板 → 下载 → 可选在 Finder 中显示。
    static func download(
        asset: ReleaseAsset,
        downloader: (any ReleaseAssetDownloading)? = nil,
        revealInFinder: Bool = true
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
            try await worker.download(asset: asset, to: destination)
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
