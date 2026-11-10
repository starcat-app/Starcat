//
//  ScreensaverRefreshCoordinatorTests.swift
//  StarcatTests
//
//  屏保发布必须单飞：设置里点安装 / 同步完成不能叠两轮 GitHub 下载。
//

import AppKit
import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("ScreensaverRefreshCoordinator")
struct ScreensaverRefreshCoordinatorTests {
    @Test("并发 publishReady 只跑一轮 enrich")
    func overlappingPublishReadyRunsOnce() async throws {
        try await withTemporaryDirectory { directory in
            let store = ScreensaverSnapshotStore(containerURL: directory)
            let cache = ScreensaverAvatarCache(containerURL: directory)
            let downloader = CountingDownloader()
            let gate = PublishGate()
            let png = Self.makePNGData(dimension: 256)
            let coordinator = ScreensaverRefreshCoordinator(
                loadCards: {
                    [
                        AmbientCardModel(
                            id: "owner:apple",
                            visualKey: "owner:apple",
                            title: "apple",
                            artworkURLString: "https://github.com/apple.png",
                            subtitle: nil,
                            metadata: [:]
                        )
                    ]
                },
                userIDProvider: { 99 },
                isEnabled: true,
                makePublisher: {
                    ScreensaverSnapshotPublisher(
                        loadCards: {
                            [
                                AmbientCardModel(
                                    id: "owner:apple",
                                    visualKey: "owner:apple",
                                    title: "apple",
                                    artworkURLString: "https://github.com/apple.png",
                                    subtitle: nil,
                                    metadata: [:]
                                )
                            ]
                        },
                        store: store,
                        cache: cache,
                        downloader: { url in
                            await downloader.record(url)
                            await gate.waitUntilReleased()
                            return png
                        }
                    )
                },
                bypassTestHostGate: true
            )

            let first = Task { await coordinator.publishReady() }
            try await Task.sleep(for: .milliseconds(50))
            let second = Task { await coordinator.publishReady() }
            await gate.release()
            await first.value
            await second.value

            #expect(await downloader.count == 1)
            #expect(try store.load().cards.first?.imageFileName != nil)
            // 等待排队的进度回调后仍须空闲，状态面板不能在完成后留下任务。
            for _ in 0..<10 { await Task.yield() }
            #expect(coordinator.avatarProgress == nil)
        }
    }

    private actor CountingDownloader {
        private(set) var count = 0

        func record(_ url: URL) {
            count += 1
            _ = url
        }
    }

    private actor PublishGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func waitUntilReleased() async {
            if released { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private nonisolated static func makePNGData(dimension: Int) -> Data {
        let size = NSSize(width: dimension, height: dimension)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiff)!
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-screensaver-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
