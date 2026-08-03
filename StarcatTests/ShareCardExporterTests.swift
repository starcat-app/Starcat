//
//  ShareCardExporterTests.swift
//  StarcatTests
//
//  验证分享卡 PNG 编码后的像素尺寸和产品 metadata，防止后续导出链路重构时
//  退回到只写像素、不写来源信息的普通 PNG。
//

import AppKit
import ImageIO
import Testing
@testable import Starcat

@Suite("ShareCardExporter PNG metadata")
struct ShareCardExporterTests {

    /// 通过 ImageIO 重新读取编码结果，验证写入的是 PNG 文件自身的 metadata，
    /// 而不是只存在于内存模型、文件名或保存面板中的临时信息。
    @MainActor
    @Test("PNG 编码保留像素尺寸并写入 Starcat 产品信息")
    func pngMetadataRoundTrips() throws {
        let image = try makeImage(width: 3, height: 2)
        let metadata = ShareCardPNGMetadata(
            appVersion: "1.2.3",
            buildNumber: "456",
            localeIdentifier: "zh-Hans"
        )

        let data = try #require(ShareCardExporter.pngData(from: image, metadata: metadata))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let pngProperties = try #require(
            properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        )

        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 3)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 2)
        #expect(pngProperties[kCGImagePropertyPNGTitle] as? String == ShareCardPNGMetadata.title)
        #expect(
            pngProperties[kCGImagePropertyPNGDescription] as? String
                == ShareCardPNGMetadata.description
        )
        #expect(pngProperties[kCGImagePropertyPNGSoftware] as? String == "Starcat 1.2.3 (Build 456)")

        let xmpMetadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let xmpSource = CGImageMetadataCopyStringValueWithPath(
            xmpMetadata,
            nil,
            "dc:source" as CFString
        )
        let creatorTool = CGImageMetadataCopyStringValueWithPath(
            xmpMetadata,
            nil,
            "xmp:CreatorTool" as CFString
        )
        let comment = try #require(CGImageMetadataCopyStringValueWithPath(
            xmpMetadata,
            nil,
            "starcat:Manifest" as CFString
        ) as String?)
        #expect(xmpSource as String? == ShareCardPNGMetadata.source)
        #expect(creatorTool as String? == "Starcat 1.2.3 (Build 456)")

        let commentObject = try JSONSerialization.jsonObject(with: Data(comment.utf8))
        let payload = try #require(commentObject as? [String: String])
        #expect(payload["schema"] == "starcat.share-card.v1")
        #expect(payload["generator"] == "Starcat")
        #expect(payload["contentType"] == "github-stars-profile-share-card")
        #expect(payload["website"] == "https://starcat.ink")
        #expect(payload["locale"] == "zh-Hans")
    }

    /// 构造一个无需文件 fixture 的最小位图；像素内容不重要，尺寸必须可精确回读。
    @MainActor
    private func makeImage(width: Int, height: Int) throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }
}
