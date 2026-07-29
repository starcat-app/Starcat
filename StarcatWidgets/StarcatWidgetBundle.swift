//
//  StarcatWidgetBundle.swift
//  StarcatWidgets
//
//  Starcat Widget Extension 的最小工程入口。
//  Store 与 Direct target 共用本文件；业务组件会在阶段 1 之后逐步替换占位内容。
//

import SwiftUI
import WidgetKit

/// 同时作为两个分发渠道 Extension 的唯一 `@main` 入口。
///
/// 此阶段只注册最小静态组件，用于尽早验证 target 嵌入、Info.plist 和 App Group
/// 签名。先通过工程门禁再接业务代码，可以把签名问题与数据问题分开定位。
@main
struct StarcatWidgetBundle: WidgetBundle {
    var body: some Widget {
        StarcatWidgetBootstrapPlaceholder()
    }
}

/// 阶段 0 的占位组件；后续会由三个正式 Widget 替换。
private struct StarcatWidgetBootstrapPlaceholder: Widget {
    let kind = "com.starcat.widget.bootstrap"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            StarcatWidgetBootstrapView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Starcat")
        .description("Starcat")
        .supportedFamilies([.systemSmall])
    }

    /// 占位 timeline 不访问网络或宿主进程，只提供稳定的工程验证内容。
    private struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: .now)
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: .now))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now)], policy: .never))
        }
    }

    fileprivate struct Entry: TimelineEntry {
        let date: Date
    }
}

/// 使用系统语义色和 SF Symbol，避免阶段 0 引入额外资源依赖。
private struct StarcatWidgetBootstrapView: View {
    let entry: StarcatWidgetBootstrapPlaceholder.Entry

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.title2)
                .foregroundStyle(.primary)
            Text(verbatim: "Starcat")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Starcat"))
    }
}
