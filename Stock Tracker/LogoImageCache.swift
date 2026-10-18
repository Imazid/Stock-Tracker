//
//  LogoImageCache.swift
//  Stock Tracker
//
//  Company / coin logos for `TickerLogo`. FMP's image CDN sends no cache headers (only
//  an ETag), so `AsyncImage` re-requested every logo each time a row appeared and showed
//  the monogram until it arrived — rows flickered while scrolling. Logos are now kept in
//  memory (decoded, ready to draw) and on disk across launches, identical requests share
//  one download, and a ticker with no logo isn't asked for again this session.
//

import UIKit

@MainActor
final class LogoImageCache {
    static let shared = LogoImageCache()

    /// Decoded logos, by bytes: ~40 logos at 192px (a full watchlist plus Home).
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 6 * 1024 * 1024
        return cache
    }()
    private var missing = Set<String>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Logos rarely change: serve the disk copy without revalidating. Lazy, so the first
    /// frame (whose rows ask `cached(_:)`) doesn't pay for opening the disk cache.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Disk only: decoded images are already held above, so an in-memory copy of
        // the PNG bytes would be paid for twice.
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 40 * 1024 * 1024,
                                   directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                                       .appendingPathComponent("Logos", isDirectory: true))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }()

    /// A logo already in memory, for drawing without a placeholder flash.
    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url.absoluteString as NSString) }

    func load(_ url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let image = memory.object(forKey: key as NSString) { return image }
        if missing.contains(key) { return nil }
        if let running = inFlight[key] { return await running.value }

        let session = self.session
        // Detached: the disk-cache read and the decode stay off the main thread
        // (inheriting this class's main-actor isolation put them on it during launch).
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let request = URLRequest(url: url)
            let data: Data
            if let stored = session.configuration.urlCache?.cachedResponse(for: request),
               (stored.response as? HTTPURLResponse)?.statusCode == 200 {
                data = stored.data   // on disk from an earlier launch: no network
            } else {
                NetRequestLog.record(endpoint: "logo", url: url)
                guard let (fetched, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                data = fetched
            }
            guard let image = UIImage(data: data) else { return nil }
            // Decode now rather than on first draw during a scroll; logos are drawn at
            // most ~60pt, so anything bigger than 192px is shrunk as it's decoded.
            let longest = max(image.size.width, image.size.height) * image.scale
            if longest > 192 {
                let factor = 192 / longest
                let target = CGSize(width: image.size.width * image.scale * factor,
                                    height: image.size.height * image.scale * factor)
                return await image.byPreparingThumbnail(ofSize: target) ?? image
            }
            return await image.byPreparingForDisplay() ?? image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let pixels = image.size.width * image.scale * image.size.height * image.scale
            memory.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
        } else {
            missing.insert(key)
        }
        return image
    }
}
