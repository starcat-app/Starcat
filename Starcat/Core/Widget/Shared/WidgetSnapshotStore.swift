//
//  WidgetSnapshotStore.swift
//  Starcat
//
//  App Group 中版本化 Widget 快照的原子读写实现。
//

import Foundation

/// 快照读取失败的稳定分类，供 Widget 映射为 preparing / upgrade / unavailable 空态。
enum WidgetSnapshotStoreError: Error, Equatable, LocalizedError {
    case snapshotMissing
    case unsupportedSchemaVersion(Int)
    case corruptedSnapshot
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .snapshotMissing:
            return "Widget snapshot is missing"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported Widget snapshot schema version: \(version)"
        case .corruptedSnapshot:
            return "Widget snapshot is corrupted"
        case .writeFailed:
            return "Widget snapshot could not be written"
        }
    }
}

/// 对单一 App Group 容器执行快照读写。
///
/// 主应用是唯一写入者，Extension 只调用 `load()`。写入先落同目录临时文件，再通过
/// replace / move 提交；同目录操作避免跨卷复制，从而保证 Widget 不会读到半份 JSON。
struct WidgetSnapshotStore: Sendable {
    let containerURL: URL

    private var snapshotURL: URL {
        WidgetSharedConfiguration.snapshotURL(containerURL: containerURL)
    }

    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    /// 从磁盘读取并验证当前版本快照。
    func load() throws -> WidgetSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw WidgetSnapshotStoreError.snapshotMissing
        } catch {
            throw WidgetSnapshotStoreError.corruptedSnapshot
        }

        let snapshot: WidgetSnapshot
        do {
            snapshot = try Self.makeDecoder().decode(WidgetSnapshot.self, from: data)
        } catch {
            throw WidgetSnapshotStoreError.corruptedSnapshot
        }

        // v2 增加可选趋势字段，v3 在趋势内增加可选单日点；旧文件仍可安全读取。
        // 未来版本继续明确拒绝，避免旧 Extension 猜测尚未理解的新隐私或业务语义。
        guard (1...WidgetSnapshot.currentSchemaVersion).contains(snapshot.schemaVersion) else {
            throw WidgetSnapshotStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    /// 原子发布一份完整快照。
    func save(_ snapshot: WidgetSnapshot) throws {
        let fileManager = FileManager.default
        let temporaryURL = containerURL.appendingPathComponent(
            ".\(WidgetSharedConfiguration.snapshotFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(
                at: containerURL,
                withIntermediateDirectories: true
            )
            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: temporaryURL, options: [])

            if fileManager.fileExists(atPath: snapshotURL.path) {
                _ = try fileManager.replaceItemAt(
                    snapshotURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: snapshotURL)
            }
        } catch {
            // 只清理由本次写入创建、名字精确可知的临时文件；绝不扫描或删除共享容器。
            try? fileManager.removeItem(at: temporaryURL)
            throw WidgetSnapshotStoreError.writeFailed
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
