//
//  GitHubUserAttachmentTests.swift
//  StarcatTests
//
//  评论框粘贴图片：未文档化的 uploads.github.com 通道 + Markdown 插入。
//  预览走同一套 `prepareMarkdown`，必须保住 `![alt](user-attachments url)`。
//

import AppKit
import Foundation
import Testing
@testable import Starcat

@Suite("GitHubUserAttachment")
struct GitHubUserAttachmentTests {

    @Test("上传 URL 带 name / content_type / repository_id，并编码文件名")
    func makeUploadURLEncodesQuery() throws {
        let url = try #require(
            GitHubUserAttachment.makeUploadURL(
                fileName: "my shot.png",
                contentType: "image/png",
                repositoryID: 1_308_829_233
            )
        )
        #expect(url.host == "uploads.github.com")
        #expect(url.path == "/user-attachments/assets")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        #expect(query["name"] == "my shot.png")
        #expect(query["content_type"] == "image/png")
        #expect(query["repository_id"] == "1308829233")
    }

    @Test("201 JSON 取出 user-attachments URL；缺字段失败")
    func parseAssetURL() throws {
        let json = #"{"url":"https://github.com/user-attachments/assets/9dbbde49-2912-4e03-bd94-db81e1333d0e"}"#
        let url = try GitHubUserAttachment.parseAssetURL(from: Data(json.utf8))
        #expect(url.absoluteString == "https://github.com/user-attachments/assets/9dbbde49-2912-4e03-bd94-db81e1333d0e")

        #expect(throws: GitHubUserAttachmentError.missingAssetURL) {
            _ = try GitHubUserAttachment.parseAssetURL(from: Data(#"{"id":"x"}"#.utf8))
        }
        #expect(throws: GitHubUserAttachmentError.missingAssetURL) {
            _ = try GitHubUserAttachment.parseAssetURL(from: Data("not-json".utf8))
        }
    }

    @Test("Markdown 图片语法给预览用，alt 里的 ] 要转义")
    func markdownImageEscapesAlt() {
        let url = URL(string: "https://github.com/user-attachments/assets/abc")!
        #expect(
            GitHubUserAttachment.markdownImage(alt: "shot", url: url)
                == "![shot](https://github.com/user-attachments/assets/abc)"
        )
        #expect(
            GitHubUserAttachment.markdownImage(alt: "a]b", url: url)
                == "![a\\]b](https://github.com/user-attachments/assets/abc)"
        )
    }

    @Test("占位符可替换；删掉占位后不再塞图")
    func placeholderReplace() {
        let placeholder = GitHubUserAttachment.uploadingPlaceholder(
            fileName: "shot.png",
            token: "tok-1"
        )
        let draft = "hello\(placeholder)world"
        let replaced = GitHubUserAttachment.replacePlaceholder(
            placeholder,
            with: "![shot.png](https://github.com/user-attachments/assets/abc)",
            in: draft
        )
        #expect(replaced == "hello![shot.png](https://github.com/user-attachments/assets/abc)world")
        #expect(
            GitHubUserAttachment.replacePlaceholder(
                placeholder,
                with: "![x](https://example.com/x.png)",
                in: "no placeholder"
            ) == "no placeholder"
        )
    }

    @Test("插入块级图片时补空行，光标落到图后")
    func insertBlockPadsNewlines() {
        let snippet = "![shot](https://github.com/user-attachments/assets/abc)"
        let empty = GitHubUserAttachment.insertBlock(snippet, into: "", selectedUTF16: NSRange(location: 0, length: 0))
        #expect(empty.text == snippet + "\n")
        #expect(empty.selectedUTF16.location == (empty.text as NSString).length)

        let mid = GitHubUserAttachment.insertBlock(
            snippet,
            into: "hello|there",
            selectedUTF16: NSRange(location: 5, length: 1)
        )
        #expect(mid.text.contains("\n\n\(snippet)\n\n"))
        #expect(mid.text.hasPrefix("hello"))
        #expect(mid.text.hasSuffix("there"))
    }

    @Test("已有 Markdown 图片经 prepareMarkdown 后仍在，预览才能画")
    func prepareMarkdownKeepsPastedImage() {
        let markdown = """
        看这张图

        ![shot](https://github.com/user-attachments/assets/9dbbde49-2912-4e03-bd94-db81e1333d0e)
        """
        let prepared = GitHubNotificationMapper.prepareMarkdown(markdown)
        #expect(
            prepared.contains("![shot](https://github.com/user-attachments/assets/9dbbde49-2912-4e03-bd94-db81e1333d0e)")
        )
    }

    @Test("剪贴板有 PNG 才提取；纯文字不抢粘贴")
    func clipboardPrefersPNGAndIgnoresPlainText() throws {
        let png = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let imageBoard = NSPasteboard.withUniqueName()
        imageBoard.clearContents()
        imageBoard.setData(png, forType: .png)
        let image = try #require(GitHubClipboardImage.payload(from: imageBoard))
        #expect(image.contentType == "image/png")
        #expect(image.data == png)
        #expect(image.fileName.hasSuffix(".png"))

        let textBoard = NSPasteboard.withUniqueName()
        textBoard.clearContents()
        textBoard.setString("hello", forType: .string)
        #expect(GitHubClipboardImage.payload(from: textBoard) == nil)
    }
}

@Suite("GitHubAPIClient user-attachments 上传", .serialized)
struct GitHubUserAttachmentAPITests {

    private let apiBase = URL(string: "https://api.test.invalid")!

    private func makeClient() -> GitHubAPIClient {
        URLProtocolStub.reset()
        return GitHubAPIClient(
            baseURL: apiBase,
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
    }

    @Test("POST uploads.github.com，201 返回附件 URL")
    func uploadPostsBinaryAndParsesURL() async throws {
        let client = makeClient()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        URLProtocolStub.requestHandler = { request in
            let body = #"{"url":"https://github.com/user-attachments/assets/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        let url = try await client.uploadUserAttachment(
            fileName: "shot.png",
            contentType: "image/png",
            repositoryID: 42,
            data: png
        )
        #expect(url.absoluteString == "https://github.com/user-attachments/assets/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host == "uploads.github.com")
        #expect(request.url?.path == "/user-attachments/assets")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(request.httpBody == png || URLProtocolStub.requestBody(request) == png)
    }
}

private extension URLProtocolStub {
    /// URLSession 有时把 body 放进 httpBodyStream，测试两边都认。
    static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
