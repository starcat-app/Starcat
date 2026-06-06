//
//  AvatarCacheLoaderTests.swift
//  StarcatTests
//
//  HOM-174 v3：覆盖 `AvatarCacheLoader` 的核心纯函数。
//
//  测试范围（按"无网络依赖优先"原则）：
//  1. MIME 嗅探 —— 各种 magic number → 正确 MIME（PNG / JPEG / GIF / WebP / BMP / SVG / 未知）
//  2. URL 校验 —— 非法 / 非 HTTP scheme → 返回 nil
//
//  不在这里测的：
//  - 真实 URLSession 下载（需要网络）
//  - Kingfisher 磁盘 cache 读写（涉及全局 ImageCache.default 状态，会与其它测试串扰）
//  这两块更适合放集成测试 / 手工 QA。
//

import XCTest
@testable import Starcat

final class AvatarCacheLoaderTests: XCTestCase {

    // MARK: - MIME sniffing

    func testSniffMimePNG() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 8))
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: png), "image/png")
    }

    func testSniffMimeJPEG() {
        let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 8))
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: jpg), "image/jpeg")
    }

    func testSniffMimeGIF() {
        let gif87 = Data([0x47, 0x49, 0x46, 0x38, 0x37, 0x61] + Array(repeating: 0, count: 4))
        let gif89 = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61] + Array(repeating: 0, count: 4))
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: gif87), "image/gif")
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: gif89), "image/gif")
    }

    func testSniffMimeWebP() {
        // RIFF....WEBP
        let webp = Data([
            0x52, 0x49, 0x46, 0x46,     // RIFF
            0x00, 0x00, 0x00, 0x00,     // size placeholder
            0x57, 0x45, 0x42, 0x50,     // WEBP
            0x00, 0x00, 0x00, 0x00
        ])
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: webp), "image/webp")
    }

    func testSniffMimeBMP() {
        let bmp = Data([0x42, 0x4D, 0x36, 0x00, 0x00, 0x00] + Array(repeating: 0, count: 10))
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: bmp), "image/bmp")
    }

    func testSniffMimeSVG() {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: svg), "image/svg+xml")
    }

    func testSniffMimeUnknownFallsBackToPNG() {
        // 任意随机字节（不匹配任何已知 magic number）
        let unknown = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: unknown), "image/png")
    }

    func testSniffMimeEmptyOrTooShortFallsBackToPNG() {
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: Data()), "image/png")
        XCTAssertEqual(AvatarCacheLoader.sniffMimeType(data: Data([0x89])), "image/png")
    }

    // MARK: - URL validation

    /// `loadAsDataURI` 对非法 URL / 非 HTTP scheme 立即返回 nil（不会发起任何 IO）。
    /// 这条快路径是离线场景的体验保障——不让 file:// / data:// 之类的奇怪 URL 触发 URLSession。
    func testLoadAsDataURINilForInvalidURL() async {
        let result1 = await AvatarCacheLoader.loadAsDataURI(urlString: nil)
        XCTAssertNil(result1)

        let result2 = await AvatarCacheLoader.loadAsDataURI(urlString: "")
        XCTAssertNil(result2)

        let result3 = await AvatarCacheLoader.loadAsDataURI(urlString: "file:///etc/passwd")
        XCTAssertNil(result3)

        let result4 = await AvatarCacheLoader.loadAsDataURI(urlString: "javascript:alert(1)")
        XCTAssertNil(result4)
    }

    /// 空 owners 集合应立即返回空字典（不开 TaskGroup、不进任何分支）。
    func testLoadOwnerAvatarsEmptyInputReturnsEmpty() async {
        let result = await AvatarCacheLoader.loadOwnerAvatars(owners: [])
        XCTAssertTrue(result.isEmpty)
    }
}
