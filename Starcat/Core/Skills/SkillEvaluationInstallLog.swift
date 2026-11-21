//
//  SkillEvaluationInstallLog.swift
//  Starcat
//
//  最近一次受管安装的会话内记录，由两个评估入口共用。
//

import Foundation
import Observation

/// 按接收顺序记录本机安装事实。只有日志正文观察高频输出，评估面板不必重算报告。
@MainActor @Observable
final class SkillEvaluationInstallLog {
    enum Stream: String, Sendable { case stdout, stderr }

    enum Event: Sendable {
        case detail(String)
        case output(Stream, String)
    }

    typealias Sink = @MainActor @Sendable (Event) -> Void

    let id = UUID()
    private(set) var chunks: [String] = []
    @ObservationIgnored private var lastStream: Stream?

    /// 全文只在复制时拼接。正文增量消费这些片段，正在选中的旧文本不必随输出重建。
    var text: String { chunks.joined() }

    /// 同一来源的连续输出直接拼接，保留进程写出的空白和未换行内容。
    func append(_ event: Event) {
        switch event {
        case .detail(let detail):
            appendHeader(detail + "\n")
            lastStream = nil
        case .output(let stream, let chunk):
            guard !chunk.isEmpty else { return }
            if lastStream != stream {
                appendHeader("[\(stream.rawValue)]\n" + chunk)
                lastStream = stream
            } else {
                chunks.append(chunk)
            }
        }
    }

    private func appendHeader(_ line: String) {
        let separator = chunks.last.map { $0.utf8.last == 0x0A ? "" : "\n" } ?? ""
        chunks.append("\(separator)[\(Date().ISO8601Format())] \(line)")
    }
}
