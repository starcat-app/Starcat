//
//  AmbientImagePrefetcher.swift
//  Starcat
//
//  只预热当前槽位各自的 nextCard，数量天然受 slotCount 限制。切换场景、布局
//  或关闭窗口时立即 stop，避免把整个 Stars 池交给网络与解码队列。
//

import Foundation
import Kingfisher

/// ViewModel 可替换的 MainActor 预取边界。
@MainActor
protocol AmbientImagePrefetching: AnyObject {
    func update(snapshots: [AmbientSlotSnapshot], tilePointSize: Double, displayScale: Double)
    func cancel()
}

/// 持有 Kingfisher ImagePrefetcher 的完整请求生命周期。
@MainActor
final class AmbientImagePrefetcher: AmbientImagePrefetching {
    private var prefetcher: ImagePrefetcher?

    func update(snapshots: [AmbientSlotSnapshot], tilePointSize: Double, displayScale: Double) {
        cancel()
        guard !TestEnvironment.isRunning else { return }

        let urls = Self.nextArtworkURLs(
            snapshots: snapshots,
            tilePointSize: tilePointSize,
            displayScale: displayScale
        )
        guard !urls.isEmpty else { return }

        let prefetcher = ImagePrefetcher(urls: urls)
        self.prefetcher = prefetcher
        prefetcher.start()
    }

    func cancel() {
        prefetcher?.stop()
        prefetcher = nil
    }

    static func nextArtworkURLs(
        snapshots: [AmbientSlotSnapshot],
        tilePointSize: Double,
        displayScale: Double
    ) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        urls.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            guard let card = snapshot.nextCard,
                  let url = AmbientArtworkStyle.imageURL(
                      from: card.artworkURLString,
                      tilePointSize: tilePointSize,
                      displayScale: displayScale
                  ),
                  seen.insert(url).inserted else { continue }
            urls.append(url)
        }
        return urls
    }
}
