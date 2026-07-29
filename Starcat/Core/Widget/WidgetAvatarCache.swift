//
//  WidgetAvatarCache.swift
//  Starcat
//
//  主应用负责的 Widget owner avatar 下载、校验、原子缓存与有界清理。
//
//  Widget Extension 不包含本文件，也不具备网络 entitlement；它只按快照中的相对文件名
//  读取 App Group 图片。这样网络、URL 白名单和缓存策略都留在可信主应用边界。
//

import AppKit
import CryptoKit
import Foundation

struct WidgetAvatarCache: Sendable {
    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    private static let maximumCachedFiles = 200
    private static let maximumCacheBytes = 20 * 1_024 * 1_024

    let containerURL: URL

    private var directoryURL: URL {
        WidgetSharedConfiguration.avatarsDirectoryURL(containerURL: containerURL)
    }

    /// 为快照中全部 owner 准备头像，并返回写入相对文件名的新快照。
    ///
    /// 每批最多并发 3 个请求，避免首次启用 Widget 时同时冲击 GitHub；已有文件直接命中，
    /// 后续刷新通常不会发起网络请求。
    func enrich(_ snapshot: WidgetSnapshot) async -> WidgetSnapshot {
        guard snapshot.accountState == .ready else { return snapshot }
        let owners = Set(
            snapshot.focusRepositories.map(\.owner)
                + [snapshot.rediscoveryRepository?.owner].compactMap { $0 }
                + snapshot.unreadReleases.map(\.owner)
        ).sorted()

        let session = Self.makeSession()
        var fileNamesByOwner: [String: String] = [:]
        var startIndex = 0
        while startIndex < owners.count {
            let endIndex = min(startIndex + 3, owners.count)
            let batch = Array(owners[startIndex..<endIndex])
            await withTaskGroup(of: (String, String?).self) { group in
                for owner in batch {
                    group.addTask {
                        (
                            owner,
                            await cacheAvatar(
                                owner: owner,
                                directoryURL: directoryURL,
                                session: session
                            )
                        )
                    }
                }
                for await (owner, fileName) in group {
                    fileNamesByOwner[owner] = fileName
                }
            }
            startIndex = endIndex
        }

        let focus = snapshot.focusRepositories.map {
            Self.repository($0, avatarFileName: fileNamesByOwner[$0.owner] ?? nil)
        }
        let rediscovery = snapshot.rediscoveryRepository.map {
            Self.repository($0, avatarFileName: fileNamesByOwner[$0.owner] ?? nil)
        }
        let releases = snapshot.unreadReleases.map {
            Self.release($0, avatarFileName: fileNamesByOwner[$0.owner] ?? nil)
        }
        let enriched = WidgetSnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAt: snapshot.generatedAt,
            accountState: snapshot.accountState,
            focusRepositories: focus,
            rediscoveryRepository: rediscovery,
            unreadReleaseCount: snapshot.unreadReleaseCount,
            unreadReleases: releases
        )
        prune(keeping: Set(fileNamesByOwner.values.compactMap { $0 }))
        return enriched
    }

    /// 登出时删除精确的 `avatars/` 子目录；不扫描或删除 App Group 根目录。
    func clear() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func fileName(owner: String) -> String {
        let normalized = owner.lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private func cacheAvatar(
        owner: String,
        directoryURL: URL,
        session: URLSession
    ) async -> String? {
        let fileName = Self.fileName(owner: owner)
        let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return fileName
        }

        guard let sourceURL = URL(string: RepoAvatarURL.from(owner: owner)),
              Self.isAllowedSourceURL(sourceURL, owner: owner) else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            var request = URLRequest(url: sourceURL)
            request.timeoutInterval = 10
            request.setValue("StarcatWidget/1", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  httpResponse.expectedContentLength <= Self.maximumResponseBytes
                    || httpResponse.expectedContentLength == NSURLSessionTransferSizeUnknown else {
                return nil
            }

            var data = Data()
            data.reserveCapacity(
                min(
                    max(0, Int(httpResponse.expectedContentLength)),
                    Self.maximumResponseBytes
                )
            )
            for try await byte in bytes {
                guard data.count < Self.maximumResponseBytes else { return nil }
                data.append(byte)
            }
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }

            try Self.atomicWrite(png, to: destinationURL)
            return fileName
        } catch {
            AppLog.general.debug(
                "Widget avatar cache failed owner=\(owner, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func isAllowedSourceURL(_ url: URL, owner: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil else {
            return false
        }
        return url.path == "/\(owner).png"
    }

    private static func atomicWrite(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [])
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// 保留当前快照引用，之后按最近修改优先保留，双上限避免头像目录持续增长。
    private func prune(keeping retainedFileNames: Set<String>) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let candidates = urls.compactMap { url -> (URL, Date, Int)? in
            guard url.pathExtension.lowercased() == "png",
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                  ) else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }

        var keptCount = 0
        var keptBytes = 0
        for (url, _, bytes) in candidates {
            let mustRetain = retainedFileNames.contains(url.lastPathComponent)
            let fitsBudget = keptCount < Self.maximumCachedFiles
                && keptBytes + bytes <= Self.maximumCacheBytes
            if mustRetain || fitsBudget {
                keptCount += 1
                keptBytes += bytes
            } else {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    private static func repository(
        _ repository: WidgetRepository,
        avatarFileName: String?
    ) -> WidgetRepository {
        WidgetRepository(
            id: repository.id,
            owner: repository.owner,
            name: repository.name,
            description: repository.description,
            language: repository.language,
            starsCount: repository.starsCount,
            tags: repository.tags,
            status: repository.status,
            focusSource: repository.focusSource,
            avatarFileName: avatarFileName,
            openURL: repository.openURL
        )
    }

    private static func release(
        _ release: WidgetRelease,
        avatarFileName: String?
    ) -> WidgetRelease {
        WidgetRelease(
            id: release.id,
            repositoryID: release.repositoryID,
            owner: release.owner,
            repositoryName: release.repositoryName,
            tagName: release.tagName,
            displayName: release.displayName,
            publishedAt: release.publishedAt,
            isPrerelease: release.isPrerelease,
            avatarFileName: avatarFileName,
            openURL: release.openURL
        )
    }
}
