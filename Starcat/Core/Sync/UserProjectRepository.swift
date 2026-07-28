//
//  UserProjectRepository.swift
//  Starcat
//
//  “我的项目”关系与同步代际的 GRDB Repository。
//
//  为什么单独建 Repository：
//  - `GRDBRepoRepository` 的主语是 Star / 知识库，项目同步不能复用其中的
//    `markUnstarredExcept`，否则会篡改用户真实的 GitHub Star；
//  - 分页请求会逐页落库，只有整条 affiliation 链成功后才能删除旧 generation；
//  - Repo metadata、项目关系和当天 Star snapshot 必须在同一事务提交。
//

import Foundation
import GRDB

protocol UserProjectRepositoryProtocol: Sendable {
    func upsertPage(
        _ projects: [RemoteUserProject],
        userID: Int64,
        authorizationSource: ProjectAuthorizationSource,
        generation: String,
        seenAt: Date
    ) async throws

    func completeGeneration(
        userID: Int64,
        affiliation: ProjectAffiliation,
        authorizationSource: ProjectAuthorizationSource,
        generation: String,
        etag: String?,
        completedAt: Date
    ) async throws

    func failGeneration(
        userID: Int64,
        affiliation: ProjectAffiliation,
        authorizationSource: ProjectAuthorizationSource,
        generation: String,
        errorCode: String,
        failedAt: Date
    ) async throws

    func fetchPage(
        userID: Int64,
        filter: UserProjectFilter,
        limit: Int,
        offset: Int
    ) async throws -> [UserProjectListItem]

    func count(userID: Int64, filter: UserProjectFilter) async throws -> Int
    func fetchSyncState(
        userID: Int64,
        affiliation: ProjectAffiliation,
        authorizationSource: ProjectAuthorizationSource
    ) async throws -> ProjectSyncState?
    func deleteRelations(userID: Int64) async throws
}

struct GRDBUserProjectRepository: UserProjectRepositoryProtocol, Sendable {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func upsertPage(
        _ projects: [RemoteUserProject],
        userID: Int64,
        authorizationSource: ProjectAuthorizationSource,
        generation: String,
        seenAt: Date
    ) async throws {
        guard !projects.isEmpty else { return }
        let seenAtISO = ISO8601DateFormatter.shared.string(from: seenAt)

        try await database.writer.write { db in
            for remote in projects {
                let existingRepo = try Repo.fetchOne(db, key: remote.repo.id)
                var repo = GRDBRepoRepository.repoFromDTO(
                    remote.repo,
                    starredAt: nil,
                    cachedAt: seenAtISO,
                    isStarred: false
                )
                // 项目同步只刷新 GitHub 元数据；Star 是另一条用户关系，必须以本地真值为准。
                repo.isStarred = existingRepo?.isStarred == true
                repo.starredAt = existingRepo?.isStarred == true ? existingRepo?.starredAt : nil
                try repo.save(db)

                let existingProject = try UserProject.fetchOne(
                    db,
                    sql: "SELECT * FROM user_projects WHERE user_id = ? AND repo_id = ?",
                    arguments: [userID, remote.repo.id]
                )
                var project = UserProject(
                    userId: userID,
                    repoId: remote.repo.id,
                    affiliation: remote.affiliation,
                    ownerLogin: remote.repo.owner.login,
                    ownerType: remote.ownerType,
                    visibility: remote.visibility,
                    permission: remote.permission,
                    authorizationSource: authorizationSource,
                    installationId: remote.installationId,
                    generation: generation,
                    lastSeenAt: seenAtISO,
                    createdAt: existingProject?.createdAt ?? seenAtISO,
                    updatedAt: seenAtISO
                )
                try project.save(db)

                try GRDBRepoStarHistoryRepository.saveLocalSnapshot(
                    repoId: remote.repo.id,
                    starsCount: remote.repo.stargazersCount,
                    observedAt: seenAt,
                    fetchedAt: seenAt,
                    db: db
                )
            }
        }
    }

    func completeGeneration(
        userID: Int64,
        affiliation: ProjectAffiliation,
        authorizationSource: ProjectAuthorizationSource,
        generation: String,
        etag: String?,
        completedAt: Date
    ) async throws {
        let completedAtISO = ISO8601DateFormatter.shared.string(from: completedAt)
        try await database.writer.write { db in
            // 只有调用方确认所有分页成功后才进入这里；分页失败必须走 failGeneration，
            // 从而保留旧 generation 的关系，避免网络波动被误判成“项目已删除”。
            try db.execute(
                sql: """
                    DELETE FROM user_projects
                    WHERE user_id = ?
                      AND affiliation = ?
                      AND generation <> ?
                    """,
                arguments: [userID, affiliation.rawValue, generation]
            )

            var state = ProjectSyncState(
                userId: userID,
                credentialKind: authorizationSource,
                affiliation: affiliation,
                etag: etag,
                generation: generation,
                lastAttemptAt: completedAtISO,
                lastSuccessAt: completedAtISO,
                syncStatus: .succeeded,
                errorCode: nil,
                updatedAt: completedAtISO
            )
            try state.save(db)
        }
    }

    func failGeneration(
        userID: Int64,
        affiliation: ProjectAffiliation,
        authorizationSource: ProjectAuthorizationSource,
        generation: String,
        errorCode: String,
        failedAt: Date
    ) async throws {
        let failedAtISO = ISO8601DateFormatter.shared.string(from: failedAt)
        try await database.writer.write { db in
            let previous = try ProjectSyncState.fetchOne(
                db,
                sql: """
                    SELECT * FROM project_sync_state
                    WHERE user_id = ? AND credential_kind = ? AND affiliation = ?
                    """,
                arguments: [userID, authorizationSource.rawValue, affiliation.rawValue]
            )
            var state = ProjectSyncState(
                userId: userID,
                credentialKind: authorizationSource,
                affiliation: affiliation,
                etag: previous?.etag,
                generation: generation,
                lastAttemptAt: failedAtISO,
                lastSuccessAt: previous?.lastSuccessAt,
                syncStatus: .failed,
                // 只保存稳定错误分类；网络层不得传响应 body 或 Private repo 名称。
                errorCode: errorCode,
                updatedAt: failedAtISO
            )
            try state.save(db)
        }
    }

    func fetchPage(
        userID: Int64,
        filter: UserProjectFilter,
        limit: Int,
        offset: Int
    ) async throws -> [UserProjectListItem] {
        let query = Self.makeQuery(userID: userID, filter: filter)
        return try await database.writer.read { db in
            try UserProjectListItem.fetchAll(
                db,
                sql: """
                    SELECT r.*,
                           p.user_id AS project_user_id,
                           p.repo_id AS project_repo_id,
                           p.affiliation AS project_affiliation,
                           p.owner_login AS project_owner_login,
                           p.owner_type AS project_owner_type,
                           p.visibility AS project_visibility,
                           p.permission AS project_permission,
                           p.authorization_source AS project_authorization_source,
                           p.installation_id AS project_installation_id,
                           p.generation AS project_generation,
                           p.last_seen_at AS project_last_seen_at,
                           p.created_at AS project_created_at,
                           p.updated_at AS project_updated_at
                    FROM repos r
                    JOIN user_projects p ON p.repo_id = r.id
                    \(query.whereSQL)
                    ORDER BY p.updated_at DESC, r.id DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: query.arguments + [max(1, limit), max(0, offset)]
            )
        }
    }

    func count(userID: Int64, filter: UserProjectFilter) async throws -> Int {
        let query = Self.makeQuery(userID: userID, filter: filter)
        return try await database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM repos r
                    JOIN user_projects p ON p.repo_id = r.id
                    \(query.whereSQL)
                    """,
                arguments: query.arguments
            ) ?? 0
        }
    }

    func fetchSyncState(
        userID: Int64,
        affiliation: ProjectAffiliation,
        authorizationSource: ProjectAuthorizationSource
    ) async throws -> ProjectSyncState? {
        try await database.writer.read { db in
            try ProjectSyncState.fetchOne(
                db,
                sql: """
                    SELECT * FROM project_sync_state
                    WHERE user_id = ? AND credential_kind = ? AND affiliation = ?
                    """,
                arguments: [userID, authorizationSource.rawValue, affiliation.rawValue]
            )
        }
    }

    func deleteRelations(userID: Int64) async throws {
        try await database.writer.write { db in
            // 授权撤销只移除项目关系和该功能同步状态；Repo、Star、Notes、Tags、Pin 等保留。
            try db.execute(sql: "DELETE FROM user_projects WHERE user_id = ?", arguments: [userID])
            try db.execute(sql: "DELETE FROM project_sync_state WHERE user_id = ?", arguments: [userID])
        }
    }

    private static func makeQuery(
        userID: Int64,
        filter: UserProjectFilter
    ) -> (whereSQL: String, arguments: StatementArguments) {
        var clauses = ["p.user_id = ?"]
        var arguments: StatementArguments = [userID]

        appendInClause(
            column: "p.affiliation",
            values: filter.affiliations.map(\.rawValue).sorted(),
            clauses: &clauses,
            arguments: &arguments
        )
        appendInClause(
            column: "p.owner_login",
            values: filter.organizationLogins.sorted(),
            clauses: &clauses,
            arguments: &arguments
        )
        appendInClause(
            column: "p.visibility",
            values: filter.visibilities.map(\.rawValue).sorted(),
            clauses: &clauses,
            arguments: &arguments
        )
        appendInClause(
            column: "p.permission",
            values: filter.permissions.map(\.rawValue).sorted(),
            clauses: &clauses,
            arguments: &arguments
        )
        appendInClause(
            column: "p.authorization_source",
            values: filter.authorizationSources.map(\.rawValue).sorted(),
            clauses: &clauses,
            arguments: &arguments
        )

        let searchText = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !searchText.isEmpty {
            clauses.append(
                "(LOWER(r.full_name) LIKE LOWER(?) ESCAPE '\\' OR LOWER(COALESCE(r.description, '')) LIKE LOWER(?) ESCAPE '\\')"
            )
            let escaped = searchText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            arguments += ["%\(escaped)%", "%\(escaped)%"]
        }

        return ("WHERE " + clauses.joined(separator: " AND "), arguments)
    }

    private static func appendInClause(
        column: String,
        values: [String],
        clauses: inout [String],
        arguments: inout StatementArguments
    ) {
        guard !values.isEmpty else { return }
        clauses.append("\(column) IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))")
        arguments += StatementArguments(values)
    }
}
