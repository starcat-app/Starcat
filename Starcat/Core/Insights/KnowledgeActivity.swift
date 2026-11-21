//
//  KnowledgeActivity.swift
//  Starcat
//
//  本机显式整理动作。账号由数据库隔离，仓库缓存清理后仍保留动作日期。
//

import Foundation
import GRDB

/// 期间查询也使用相同的动作类型；Star 和 Unstar 始终由原收藏账本提供。
enum KnowledgeAction: String, Codable, Sendable {
    case star, unstar, enteredLibrary, leftLibrary, startedUsing, stoppedUsing, wroteNote, editedNote
}

enum KnowledgeActionSource: String, Codable, Sendable {
    case starcat, githubSync = "github_sync", currentStar, autoLibrary, aiNote, unstarCleanup
}

/// 写入者传入现有业务事务。整行导入、CloudKit 合并和被动阅读走状态快照路径。
enum KnowledgeActivity {
    static func append(_ action: KnowledgeAction, repoID: Int64, at date: Date,
                       source: KnowledgeActionSource = .starcat, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO knowledge_activity(repo_id, kind, occurred_at, source) VALUES (?, ?, ?, ?)
            """, arguments: [repoID, action.rawValue, date.timeIntervalSince1970, source.rawValue])
    }

    /// 与编辑器共用 Foundation 的空白规则；仅首尾空白变化不代表新增写作。
    static func body(_ content: String?) -> String {
        (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SQLite 默认 trim 只处理空格。传入 Foundation 定义的 BMP 空白符，与正文写入保持一致。
    static let nonemptyNoteSQL: String = {
        let scalars = (0...0xffff).compactMap { code -> String? in
            guard let scalar = Unicode.Scalar(code), CharacterSet.whitespacesAndNewlines.contains(scalar)
            else { return nil }
            return String(code)
        }.joined(separator: ",")
        return "NULLIF(TRIM(n.content, char(\(scalars))), '') IS NOT NULL"
    }()
}
