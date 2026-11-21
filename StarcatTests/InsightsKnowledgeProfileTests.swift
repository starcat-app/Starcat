//
//  InsightsKnowledgeProfileTests.swift
//  StarcatTests
//
//  通过界面使用的查询核对主题、两期数字及完整明细，同时验证切号与迟到的刷新。
//

import Foundation
import GRDB
import SwiftUI
import Testing
@testable import Starcat

@Suite("我的洞察 · 个人知识画像")
struct InsightsKnowledgeProfileTests {
    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    /// 两期各有一个已取消收藏的同主题仓库。另留一条只有账本名称的历史，覆盖缓存清理后的导航。
    private func sampleDatabase() async throws -> InMemoryDatabaseManager {
        let database = try InMemoryDatabaseManager(userId: 42)
        for repoID: Int64 in 1...6 { try await database.insertRepoFixture(id: repoID) }
        try await database.writer.write { db in
            try db.execute(sql: """
                UPDATE repos SET topics='["Swift","swift","db"]' WHERE id=1;
                UPDATE repos SET topics='["swift"]', language=NULL WHERE id=2;
                UPDATE repos SET topics='["old"]', is_starred=0 WHERE id IN (5,6);
                INSERT INTO tags(id,name,created_at,updated_at) VALUES('t','swift','2025','2025');
                INSERT INTO repo_tags(repo_id,tag_id,created_at) VALUES(3,'t','2025');
                INSERT INTO repo_notes(repo_id,content,status,library_state,is_ai_generated) VALUES
                    (1,'manual','using','in_library',0), (2,'generated','read','outside_library',1),
                    (3,'　','using','outside_library',0), (5,'manual','read','in_library',0);
                INSERT INTO ai_summaries(repo_id,model,source_hash,summary_json,generated_at) VALUES
                    (2,'first','hash','{}','2025'), (2,'second','hash','{}','2025');
                UPDATE knowledge_activity_coverage SET started_at=unixepoch('2025-07-01');
                INSERT INTO knowledge_activity(repo_id,kind,source,occurred_at) VALUES
                    (1,'wroteNote','starcat',unixepoch('2025-07-21')),
                    (1,'editedNote','starcat',unixepoch('2025-07-22')),
                    (5,'editedNote','starcat',unixepoch('2025-07-23'));
                """)
            let actions: [(Int64, String, String)] = [
                (8, "star", "2025-05-31T23:59:59Z"), (5, "star", "2025-06-01T00:00:00Z"),
                (1, "star", "2025-06-12T00:00:00Z"), (1, "unstar", "2025-06-20T00:00:00Z"),
                (7, "star", "2025-06-30T23:59:59Z"), (1, "star", "2025-07-01T00:00:00Z"),
                (1, "unstar", "2025-07-02T00:00:00Z"), (1, "star", "2025-07-04T00:00:00Z"),
                (6, "star", "2025-07-06T00:00:00Z"), (7, "unstar", "2025-07-19T00:00:00Z"),
                (9, "star", "2025-07-30T10:00:00Z"), (10, "star", "2025-07-31T00:00:00Z")
            ]
            for (index, action) in actions.enumerated() {
                try db.execute(sql: """
                    INSERT INTO user_repo_activity(id,kind,source,repo_id,full_name,html_url,occurred_at,created_at,user_id)
                    VALUES(?,?,?,?,?,'',?,?,42)
                    """, arguments: [String(index), action.1, KnowledgeActionSource.githubSync.rawValue,
                                     action.0, "history/repo-\(action.0)", action.2, action.2])
            }
        }
        return database
    }

    @Test("同一批证据生成主题、次数、去重数和代表仓库，预览之外的仓库仍可访问")
    func completeDrilldowns() async throws {
        let database = try await sampleDatabase()
        let cutoff = try date("2025-07-30T09:00:00Z")
        let request = InsightsProfileRequest(accountID: 42, scope: .starred, day: cutoff, timeZone: .gmt)
        let profile = try await request.load(database: database, cutoff: cutoff)
        let evidence = profile.evidence(for: profile.all)
        #expect(evidence.count(.projects) == 4 && evidence.count(.inLibrary) == 1)
        #expect(evidence.rows[.using]?.map(\.repoID) == [1, 3] && evidence.rows[.manualNotes]?.map(\.repoID) == [1])
        #expect(evidence.rows[.aiNotes]?.map(\.repoID) == [2] && evidence.rows[.summaries]?.map(\.repoID) == [2])
        #expect(evidence.rows[.starActions(.recent)]?.map(\.repoID) == [6, 1, 1])
        #expect(evidence.rows[.starredProjects(.recent)]?.map(\.repoID) == [6, 1])
        #expect(evidence.rows[.starredProjects(.previous)]?.map(\.repoID) == [7, 1, 5])
        #expect(evidence.rows[.writtenProjects(.recent)]?.map(\.repoID) == [1] && evidence.count(.writtenProjects(.previous)) == nil)
        let representatives = try #require(evidence.rows[.representatives])
        #expect(representatives.map(\.repoID) == [5, 1, 7, 6, 2, 3, 4])
        #expect(evidence.representativePreview.map(\.repoID) == [1, 3, 5])
        #expect(evidence.representativePreview.map(\.representativeReason) == [.manualNote, .using, .recentlyRecorded])
        #expect(representatives.first { $0.repoID == 7 }?.repositoryLink == RepositoryDeepLink(fullName: "history/repo-7", repositoryID: 7))
        #expect(representatives.first?.repositoryLink == RepositoryDeepLink(fullName: "octo/demo-5", repositoryID: 5))
        #expect(InsightsKnowledgeProfile.Match(repoID: 11, fullName: nil, date: nil).repositoryLink == nil)

        let topic = try #require(profile.themes[.topic]?.first { $0.id == .named("swift") })
        let sameTag = try #require(profile.themes[.userTag]?.first { $0.id == .named("swift") })
        #expect(topic.current == [1, 2] && sameTag.current == [3])
        #expect(profile.themes[.language]?.first { $0.id == .unclassified }?.current == [2])
        for period in InsightsKnowledgeProfile.Period.allCases {
            #expect(profile.observedStars(for: topic, period: period) == profile.evidence(for: topic).count(.starredProjects(period)))
        }
        let historical = try #require(profile.themes[.topic]?.first { $0.id == .named("old") })
        #expect(historical.current.isEmpty)
        #expect(profile.evidence(for: historical).rows[.representatives]?.map(\.repoID) == [5, 6])
        #expect(profile.evidence(for: historical).representativePreview.map(\.representativeReason)
                == [.recentlyRecorded, .recentlyRecorded])
        #expect(profile.comparisons(by: .topic).map(\.id) == [.named("db"), .named("old"), .named("swift"), .unclassified])
    }

    @Test("知识库以当前在库成员比较两期，保存了已取消收藏的入库项目")
    func knowledgeScope() async throws {
        let database = try await sampleDatabase()
        let cutoff = try date("2025-07-30T09:00:00Z")
        let request = InsightsProfileRequest(accountID: 42, scope: .knowledge, day: cutoff, timeZone: .gmt)
        let profile = try await request.load(database: database, cutoff: cutoff)
        let evidence = profile.evidence(for: profile.all)
        #expect(profile.all.current == [1, 5] && evidence.count(.projects) == 2)
        #expect(evidence.rows[.starActions(.recent)]?.map(\.repoID) == [1, 1])
        #expect(evidence.rows[.starredProjects(.previous)]?.map(\.repoID) == [1, 5])
        #expect(evidence.rows[.writtenProjects(.recent)]?.map(\.repoID) == [5, 1])
        #expect(evidence.rows[.representatives]?.map(\.repoID) == [5, 1])
        #expect(evidence.representativePreview.map(\.repoID) == [5, 1])
        #expect(evidence.representativePreview.map(\.representativeReason) == [.manualNote, .manualNote])
        #expect(profile.themes[.topic]?.contains { $0.id == .unclassified } == false)
    }

    @Test("空库区分没有成员、覆盖期内零次和覆盖不足，夏令时按自然日划窗")
    func coverageAndCalendar() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let cutoff = try date("2025-03-20T18:00:00Z")
        let request = InsightsProfileRequest(accountID: 42, scope: .knowledge, day: cutoff, timeZone: zone)
        #expect(request.recentStart == (try date("2025-02-19T05:00:00Z")))
        #expect(request.window.end == (try date("2025-03-21T04:00:00Z")))
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE knowledge_activity_coverage SET started_at=?", arguments: [request.recentStart.timeIntervalSince1970])
        }
        let profile = try await request.load(database: database, cutoff: cutoff)
        let evidence = profile.evidence(for: profile.all)
        #expect(profile.themes[.topic]?.isEmpty == true && evidence.count(.projects) == 0)
        #expect(evidence.count(.representatives) == 0)
        #expect(evidence.count(.starActions(.recent)) == nil && profile.observedStars(for: profile.all, period: .previous) == nil)
        #expect(evidence.count(.writtenProjects(.recent)) == 0 && evidence.count(.writtenProjects(.previous)) == nil)
    }

    /// 用真实组件离屏测量，与系统外观和字体渲染细节解耦。
    @Test("窄栏或大字长译文时，画像纵排并维持可用宽度")
    @MainActor
    func adaptiveLayout() async throws {
        let database = try await sampleDatabase()
        let cutoff = try date("2025-07-30T09:00:00Z")
        let profile = try await InsightsProfileRequest(accountID: 42, scope: .starred, day: cutoff, timeZone: .gmt)
            .load(database: database, cutoff: cutoff)

        func measure(width: CGFloat, scale: InterfaceScale, language: AppLocale, colorScheme: ColorScheme) throws -> CGSize {
            let renderer = ImageRenderer(content: InsightsKnowledgeProfileView(profile: profile) { _ in }
                .environment(\.starcatInterfaceScale, scale)
                .environment(\.locale, language.effectiveLocale)
                .environment(\.colorScheme, colorScheme))
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            return try #require(renderer.nsImage).size
        }

        let wide = try measure(width: 810, scale: .standard, language: .simplifiedChinese, colorScheme: .light)
        let narrow = try measure(width: 370, scale: .standard, language: .simplifiedChinese, colorScheme: .light)
        let enlarged = try measure(width: 810, scale: .large, language: .german, colorScheme: .dark)
        #expect(wide.width == 810 && narrow.width == 370 && enlarged.width == 810)
        #expect(narrow.height > wide.height && enlarged.height > wide.height)
    }

    @Test("同范围刷新失败可继续查看，迟到请求不得覆盖新范围，切号立即隐藏旧内容")
    @MainActor
    func refreshIdentity() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        let day = try date("2025-07-30T09:00:00Z")
        let starred = InsightsProfileRequest(accountID: 42, scope: .starred, day: day, timeZone: .gmt)
        let library = InsightsProfileRequest(accountID: 42, scope: .knowledge, day: day, timeZone: .gmt)
        let starredProfile = try await starred.load(database: database, cutoff: day)
        let libraryProfile = try await library.load(database: database, cutoff: day)
        let loader = InsightsProfileLoader()
        await loader.load(starred) { _ in starredProfile }
        await loader.load(starred) { _ in throw URLError(.cannotLoadFromNetwork) }
        #expect(loader.failed == starred && loader.displayed(for: starred) != nil)
        #expect(loader.displayed(for: library) == nil)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let slow = Task {
            await loader.load(starred) { _ in
                entered.continuation.finish()
                for await _ in release.stream {}
                return starredProfile
            }
        }
        for await _ in entered.stream {}
        #expect(loader.loading == starred && loader.displayed(for: starred) != nil)
        await loader.load(library) { _ in libraryProfile }
        release.continuation.finish()
        await slow.value
        #expect(loader.displayed(for: starred) == nil && loader.displayed(for: library) != nil)
        #expect(loader.loading == nil && loader.failed == nil)
        #expect(loader.displayed(for: InsightsProfileRequest(accountID: 9, scope: .knowledge, day: day, timeZone: .gmt)) == nil)
        #expect(loader.displayed(for: InsightsProfileRequest(accountID: 42, scope: .knowledge, day: day, timeZone: .gmt, databaseRevision: 1)) == nil)
    }
}
