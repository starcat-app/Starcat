//
//  DailyRadarServiceFixtureTests.swift
//  StarcatTests
//
//  使用 Go 服务测试产出的原始 envelope 验证 Swift 解码，避免两端分别自编码、
//  自解码通过却不能互通。夹具副本随主仓运行，CI 不依赖 supports checkout。
//

import Foundation
import Testing
@testable import Starcat

/// 覆盖目录、日期、列表和完整正文，包括可空封面及既有仓库核心 DTO。
@Suite("每日热点跨服务契约")
struct DailyRadarServiceFixtureTests {
    @Test("Go 目录、日期及列表使用同一版本和业务日期")
    func catalogAndList() throws {
        let catalog = try decode(DailyRadarCatalog.self, fixture: "catalog")
        let dates = try decode(DailyRadarDates.self, fixture: "dates")
        let page = try decode(DailyRadarPage.self, fixture: "reports")
        let report = try #require(page.items.first)

        #expect(catalog.catalogRevision == "1")
        #expect(dates.catalogRevision == catalog.catalogRevision)
        #expect(page.catalogRevision == catalog.catalogRevision)
        #expect(catalog.latestAvailableDate == "2026-10-28")
        // 侧边栏计数徽标契约：按请求语言去重后的分类计数与父级总数。
        #expect(catalog.categoryCounts?["ai-cli"] == 1)
        #expect(catalog.totalCount == 1)
        #expect(dates.dates.first?.date == report.editionDate)
        #expect(dates.dates.first?.count == 1)
        #expect(page.total == 1)
        #expect(page.featuredID == report.id)
        #expect(page.nextCursor == nil)
        #expect(report.cover.cardURL == nil)
        #expect(report.cover.assetName == "DailyRadarOrbitCover")
        #expect(report.markdown == nil)
    }

    @Test("Go 正文解码保留所选修订、原文及公开仓库身份")
    func pinnedDetail() throws {
        let page = try decode(DailyRadarPage.self, fixture: "reports")
        let summary = try #require(page.items.first)
        let detail = try decode(DailyRadarReport.self, fixture: "detail")
        let project = try #require(detail.relatedProjects?.first)

        #expect(detail.contentIdentity == summary.contentIdentity)
        #expect(detail.markdown?.hasPrefix("# AI CLI") == true)
        #expect(detail.relatedProjectsStatus == "complete")
        #expect(detail.relatedProjectCount == detail.relatedProjects?.count)
        #expect(detail.source?.commit.count == 40)
        #expect(project.repo.ghRepoId == 123)
        #expect(project.repo.fullName == "owner/repo")
        #expect(project.repo.isPrivate == false)
        #expect(project.evidenceURL.absoluteString == "https://github.com/owner/repo")
        #expect(project.sectionAnchor == nil)
    }

    /// 直接读取服务产物，禁止在测试中先使用 Swift DTO 重新编码来掩盖字段漂移。
    private func decode<Value: Decodable & Sendable>(_ type: Value.Type, fixture: String) throws -> Value {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DailyRadar/\(fixture).json")
        let envelope = try JSONDecoder().decode(StarcatEnvelope<Value>.self, from: Data(contentsOf: url))
        #expect(envelope.schemaVersion == 1)
        return envelope.data
    }
}
