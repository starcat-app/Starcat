//
//  CacheDirectoryLocator.swift
//  Starcat
//
//  设置页「缓存用量」各行「在 Finder 中显示」的统一目录解析。
//
//  App Store 沙盒与 Direct 版都通过 `FileManager` 的 `.applicationSupportDirectory` /
//  `.cachesDirectory` 解析路径，禁止硬编码 `~/Library/...`。系统会按当前进程容器
//  自动落到正确位置（如 `~/Library/Containers/com.starcat.app.store/Data/...`）。
//

import AppKit
import Foundation
import Kingfisher

/// 缓存目录定位失败。
enum CacheDirectoryLocatorError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return String.l10n("settings.storage.reveal.failed")
        }
    }
}

/// 设置页可打开的缓存位置。
@MainActor
struct CacheDirectoryLocator {

    /// 与 `StorageSettingsTab` 的 `PendingAction` 一一对应（README / RAG 共用主库文件）。
    enum Item: Sendable {
        case readmeDatabase
        case imageCache
        case archives
        case translation
        case externalSearch
        case wiki
        case issueTimeline
        case issueCommentDraft
        case recommendation
        case repoAIChatHistory
        case ragDatabase
        case aiContext
        case codeFlow
        case codebaseMemory
    }

    private let fileManager: FileManager
    private let userID: Int64?
    private let chatHistoryStorageKind: ChatHistoryStorageKind
    private let aiContextStorage: RepoContextStorage
    private let codeFlowStorage: CodeFlowStorage
    private let codebaseMemoryStorage: CodebaseMemoryStorage
    private let fixedArchiveDirectory: URL?

    init(
        fileManager: FileManager = .default,
        userID: Int64?,
        chatHistoryStorageKind: ChatHistoryStorageKind,
        aiContextStorage: RepoContextStorage = .shared,
        codeFlowStorage: CodeFlowStorage = .shared,
        codebaseMemoryStorage: CodebaseMemoryStorage = .shared,
        fixedArchiveDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.userID = userID
        self.chatHistoryStorageKind = chatHistoryStorageKind
        self.aiContextStorage = aiContextStorage
        self.codeFlowStorage = codeFlowStorage
        self.codebaseMemoryStorage = codebaseMemoryStorage
        self.fixedArchiveDirectory = fixedArchiveDirectory
    }

    /// 在 Finder 中打开或选中目标路径。
    func reveal(_ item: Item) throws {
        switch item {
        case .aiContext:
            try aiContextStorage.revealOutputRoot()
        case .codeFlow:
            try codeFlowStorage.revealOutputRoot()
        case .codebaseMemory:
            try codebaseMemoryStorage.revealOutputRoot()
        default:
            let target = try resolveURL(for: item)
            try revealOnDisk(target)
        }
    }

    // MARK: - 路径解析

    private func applicationSupportRoot() throws -> URL {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CacheDirectoryLocatorError.applicationSupportUnavailable
        }
        return appSupport.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
    }

    private func resolveURL(for item: Item) throws -> URL {
        switch item {
        case .readmeDatabase, .ragDatabase:
            return try DatabaseManager.databaseFileURL(userId: userID)
        case .imageCache:
            return ImageCache.default.diskStorage.directoryURL
        case .archives:
            if let fixedArchiveDirectory { return fixedArchiveDirectory }
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Starcat/archives", isDirectory: true)
        case .translation:
            return try applicationSupportRoot()
                .appendingPathComponent("translations-cache", isDirectory: true)
        case .externalSearch:
            return try applicationSupportRoot()
                .appendingPathComponent("external-search-cache", isDirectory: true)
        case .wiki:
            return try applicationSupportRoot()
                .appendingPathComponent("wiki-cache", isDirectory: true)
        case .issueTimeline:
            return try applicationSupportRoot()
                .appendingPathComponent("issue-timeline-cache", isDirectory: true)
        case .issueCommentDraft:
            return try applicationSupportRoot()
                .appendingPathComponent("issue-comment-draft-cache", isDirectory: true)
        case .recommendation:
            return try applicationSupportRoot()
                .appendingPathComponent("recommendation-cache", isDirectory: true)
        case .repoAIChatHistory:
            let root = try applicationSupportRoot()
                .appendingPathComponent("chat-history", isDirectory: true)
            switch chatHistoryStorageKind {
            case .jsonFiles:
                return root
            case .sqlite:
                return root.appendingPathComponent("chat-history.sqlite")
            }
        case .aiContext, .codeFlow, .codebaseMemory:
            fatalError("Security-scoped output roots must use dedicated reveal methods.")
        }
    }

    /// 目录走 `open`；文件走 `activateFileViewerSelecting`。目标尚不存在时先创建父目录。
    private func revealOnDisk(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return
        }

        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        if url.pathExtension == "sqlite" {
            // SQLite 文件可能尚未创建；打开所在目录即可定位。
            NSWorkspace.shared.open(parent)
        } else if url.hasDirectoryPath {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(parent)
        }
    }
}
