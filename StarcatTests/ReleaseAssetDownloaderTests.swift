//
//  ReleaseAssetDownloaderTests.swift
//  StarcatTests
//
//  HOM-47：Release 资产应用内下载单测。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ReleaseAssetDownloader", .serialized)
struct ReleaseAssetDownloaderTests {

    private func makeDownloader(token: String? = "test-token") -> ReleaseAssetDownloader {
        ReleaseAssetDownloader(
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: token)
        )
    }

    private func sampleAsset(
        browser: String = "https://github.com/octocat/Hello-World/releases/download/v1/app.zip",
        api: String? = "https://api.github.com/repos/octocat/Hello-World/releases/assets/42"
    ) -> ReleaseAsset {
        ReleaseAsset(
            id: 42,
            name: "app.zip",
            contentType: "application/zip",
            size: 4,
            browserDownloadUrl: browser,
            apiUrl: api,
            downloadCount: 0,
            createdAt: nil
        )
    }

    @Test("browser URL 200：写入目标文件")
    func downloadViaBrowserURL() async throws {
        URLProtocolStub.reset()
        let payload = Data([0x50, 0x4B, 0x03, 0x04])
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-download-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        let downloader = makeDownloader()
        try await downloader.download(asset: sampleAsset(), to: destination)

        let saved = try Data(contentsOf: destination)
        #expect(saved == payload)
        #expect(URLProtocolStub.receivedRequests.count == 1)
        #expect(URLProtocolStub.receivedRequests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("browser 403 时 fallback 到 API URL + octet-stream Accept")
    func fallbackToAPIURL() async throws {
        URLProtocolStub.reset()
        let payload = Data("ok".utf8)
        var callIndex = 0
        URLProtocolStub.requestHandler = { request in
            callIndex += 1
            let status = callIndex == 1 ? 403 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, callIndex == 1 ? Data() : payload)
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-download-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        let downloader = makeDownloader()
        try await downloader.download(asset: sampleAsset(), to: destination)

        #expect(callIndex == 2)
        #expect(URLProtocolStub.receivedRequests.count == 2)
        #expect(
            URLProtocolStub.receivedRequests[1].value(forHTTPHeaderField: "Accept") == "application/octet-stream"
        )
        let saved = try Data(contentsOf: destination)
        #expect(saved == payload)
    }

    @Test("全部数据源失败时抛错")
    func allSourcesFail() async {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-download-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        let downloader = makeDownloader()
        await #expect(throws: ReleaseAssetDownloadError.self) {
            try await downloader.download(asset: sampleAsset(), to: destination)
        }
    }
}
