//
//  SkillLibraryScaleTests.swift
//  StarcatTests
//
//  大集合正确性与可重复耗时采样。文件夹具只写临时目录，
//  投影夹具只占内存；不访问真实 Agent，不创建窗口，也不把耗时等同于 GUI 帧率。
//

import Foundation
import Testing
@testable import Starcat

/// 只断言身份、计数和选择语义；机器负载会影响耗时，不使用脆弱的速度门槛。
@Suite("Skill 大集合回归", .serialized)
struct SkillLibraryScaleTests {
    @Test("一千个真实目录重复扫描与 SQLite 对账保留身份")
    func reconcilesThousandDirectories() async throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("SkillScale-\(UUID())")
        defer { try? manager.removeItem(at: temporary) }
        let rootURL = temporary.appendingPathComponent("skills")
        for index in 0..<1_000 {
            let directory = rootURL.appendingPathComponent("skill-\(index)")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("---\nname: skill-\(index)\ndescription: Scale fixture.\n---\n\nBody.\n".utf8)
                .write(to: directory.appendingPathComponent("SKILL.md"))
        }
        let store = try SkillLibraryStore(
            distributionGate: DistributionGate(channel: .direct),
            paths: SkillLibraryPaths(root: temporary.appendingPathComponent("library"))
        )
        let scanner = try LocalSkillScanner(distributionGate: DistributionGate(channel: .direct))
        let root = SkillLibraryRoot(configuredPath: rootURL.path, agentIDs: ["fixture"], scope: .global)
        let clock = ContinuousClock()
        var scanSamples: [Double] = []
        var applySamples: [Double] = []
        var readSamples: [Double] = []
        var originalIDs: Set<UUID> = []

        // 第一轮含首次建库，后两轮是系统文件缓存未主动清空的重扫，不冒充冷启动。
        for round in 0..<3 {
            let generation = await store.beginScan()
            let scanStart = clock.now
            let report = await scanner.scan(SkillScanRequest(generationID: generation, roots: [root]))
            scanSamples.append(Self.milliseconds(scanStart.duration(to: clock.now)))
            #expect(report.results.first?.coverage == .complete)
            #expect(report.results.first?.candidates.count == 1_000)
            let applyStart = clock.now
            let applied = try await store.apply(report)
            applySamples.append(Self.milliseconds(applyStart.duration(to: clock.now)))
            #expect(applied)
            let readStart = clock.now
            let snapshot = try await store.snapshot()
            readSamples.append(Self.milliseconds(readStart.duration(to: clock.now)))
            #expect(snapshot.entries.count == 1_000)
            #expect(snapshot.locations.count == 1_000)
            #expect(snapshot.locations.allSatisfy { $0.scanState == .present })
            let ids = Set(snapshot.entries.map(\.id))
            if round == 0 { originalIDs = ids } else { #expect(ids == originalIDs) }
        }
        try await store.close()
        let reopened = try await store.snapshot()
        #expect(Set(reopened.entries.map(\.id)) == originalIDs)
        try await store.close()
        Self.record("scan-1000", samples: scanSamples)
        Self.record("reconcile-1000", samples: applySamples)
        Self.record("sqlite-read-1000", samples: readSamples)
    }

    @Test("一万条关系快照投影筛选不串身份与更新状态")
    @MainActor
    func projectsTenThousandEntries() throws {
        let snapshot = Self.largeSnapshot()
        let clock = ContinuousClock()
        var projectionSamples: [Double] = []
        var publishSamples: [Double] = []
        var searchSamples: [Double] = []
        var filterSamples: [Double] = []
        for _ in 0..<5 {
            let projectionStart = clock.now
            let items = snapshot.workspaceItems
            projectionSamples.append(Self.milliseconds(projectionStart.duration(to: clock.now)))
            #expect(items.count == 10_000)
            #expect(Set(items.map(\.id)).count == 10_000)
            #expect(items.allSatisfy { $0.locations.count == 4 })
            let model = SkillWorkspaceViewModel()
            let publishStart = clock.now
            model.applySnapshot(items)
            publishSamples.append(Self.milliseconds(publishStart.duration(to: clock.now)))
            #expect(model.filterCounts[.managed] == 5_000)
            #expect(model.filterCounts[.updates] == 1_000)
            #expect(model.filterCounts[.attention] == 500)
            let first = try #require(items.first)
            let last = try #require(items.last)
            model.selectedIDs = [first.id, last.id]
            let searchStart = clock.now
            model.searchText = "SCALE-9999"
            searchSamples.append(Self.milliseconds(searchStart.duration(to: clock.now)))
            #expect(model.visibleItems.map(\.id) == [last.id])
            #expect(model.selectedIDs == [last.id])
            model.searchText = ""
            let filterStart = clock.now
            model.navigation = .library(.updates)
            filterSamples.append(Self.milliseconds(filterStart.duration(to: clock.now)))
            #expect(model.visibleItems.count == 1_000)
            #expect(model.visibleItems.allSatisfy { $0.hasUpdate })
            #expect(model.selectedIDs.isEmpty)
            model.navigation = .source("owner/repository-0")
            #expect(model.visibleItems.count == 100)
        }
        Self.record("projection-10000", samples: projectionSamples)
        Self.record("publish-10000", samples: publishSamples)
        Self.record("search-10000", samples: searchSamples)
        Self.record("filter-10000", samples: filterSamples)
    }

    /// 每条目四个物理位置、100 个来源以及独立 revision，覆盖真实投影中的关系索引。
    private static func largeSnapshot() -> SkillLibrarySnapshot {
        let sources = (0..<100).map {
            SkillLibrarySource(kind: .github, canonicalLocator: "owner/repository-\($0)", subdirectory: "")
        }
        let roots = (0..<4).map {
            SkillLibraryRoot(configuredPath: "/fixture/root-\($0)", agentIDs: ["codex"], scope: .global)
        }
        var entries: [SkillLibraryEntry] = []
        var revisions: [SkillLibraryRevision] = []
        var locations: [SkillLibraryLocation] = []
        var checks: [SkillUpdateCheck] = []
        for index in 0..<10_000 {
            var entry = SkillLibraryEntry(
                sourceID: sources[index % sources.count].id, manifestName: "scale-\(index)",
                summary: "Résumé fixture \(index).", managementKind: index.isMultiple(of: 2) ? .managed : .external,
                diagnostic: index.isMultiple(of: 20) ? "Fixture diagnostic" : nil
            )
            let revision = SkillLibraryRevision(
                entryID: entry.id, contentDigest: "content-\(index)", manifestDigest: "manifest-\(index)",
                upstreamCommit: String(repeating: "a", count: 40)
            )
            entry.currentRevisionID = revision.id
            entries.append(entry)
            revisions.append(revision)
            for root in roots {
                locations.append(SkillLibraryLocation(
                    entryID: entry.id, rootID: root.id, lexicalPath: "\(root.configuredPath)/scale-\(index)",
                    resolvedPath: "/fixture/content-\(index)", kind: .symbolicLink
                ))
            }
            if index.isMultiple(of: 10) {
                checks.append(SkillUpdateCheck(
                    entryID: entry.id, revisionID: revision.id, state: .available, hasUpdate: true,
                    availableCommit: String(repeating: "b", count: 40)
                ))
            }
        }
        return SkillLibrarySnapshot(
            sources: sources, entries: entries, revisions: revisions, roots: roots,
            locations: locations, updateChecks: checks
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// 输出原始样本以便后续比较；测试日志只包含阶段和合成数据耗时，不含用户路径。
    private static func record(_ phase: String, samples: [Double]) {
        let values = samples.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }
        print("[SkillScale] \(phase) ms=[\(values.joined(separator: ", "))]")
    }
}
