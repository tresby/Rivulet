//
//  ImageCacheManager.swift
//  Rivulet
//
//  Persistent image cache with weeks-long TTL and SSL support for Plex servers
//

import UIKit
import Foundation
import ImageIO

/// Requested decode size for a cached image.
///
/// The disk cache always holds the original downloaded bytes; quality only governs how
/// large we decode them for display. The Apple TV renders its UI into a 1080p framebuffer
/// and the system upscales the whole frame to 4K, so 3840px (a 2x supersample of the
/// 1920pt full-screen width) is the practical ceiling for the largest surfaces — bigger
/// sources are decoded and then thrown away, costing CPU/heat for no visible gain. `thumb`
/// is a 2x supersample of the ~444pt poster card: ample for rows, cheap to decode.
enum ImageQuality: Sendable {
    /// Small UI: poster rows, continue-watching, cast, episode stills, logos, blurred backdrops.
    case thumb
    /// Large surfaces that fill much of the screen: home hero, carousel, detail backdrops.
    case full

    var maxPixelSize: CGFloat {
        switch self {
        case .thumb: return 900
        case .full:  return 3840
        }
    }

    fileprivate var keySuffix: String {
        switch self {
        case .thumb: return "t"
        case .full:  return "f"
        }
    }
}

/// Cache entry metadata for tracking access times and TTL
struct ImageCacheEntry: Codable {
    let url: String
    let cachedAt: Date
    var lastAccessedAt: Date
    let fileSize: Int64
}

/// Actor-based image cache with disk persistence, LRU eviction, and SSL support
actor ImageCacheManager: NSObject {
    static let shared = ImageCacheManager()

    // MARK: - Configuration

    private let cacheDirectoryName = "PlexImageCache"
    private let metadataFileName = "image_cache_metadata.json"
    private let maxMemoryCacheCount = 100
    private let maxKeyCacheCount = 2048
    private let maxDiskCacheSize: Int64 = 5 * 1024 * 1024 * 1024  // 5GB
    private let defaultTTL: TimeInterval = 14 * 24 * 60 * 60  // 2 weeks

    // MARK: - Caches

    private let memoryCache = NSCache<NSString, UIImage>()
    private let keyCache = NSCache<NSString, NSString>()
    private var cacheMetadata: [String: ImageCacheEntry] = [:]
    private var metadataLoaded = false

    // MARK: - URL Session (with SSL handling)

    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session {
            return existing
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = newSession
        return newSession
    }

    // MARK: - Active Downloads (prevent duplicate byte fetches)

    private var activeDownloads: [URL: Task<Data?, Never>] = [:]

    // MARK: - Cache Directory

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(cacheDirectoryName)
    }

    // MARK: - Initialization

    override private init() {
        super.init()
        memoryCache.countLimit = maxMemoryCacheCount
        keyCache.countLimit = maxKeyCacheCount
        Task {
            await createCacheDirectoryIfNeeded()
            await loadMetadata()
        }
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Check memory cache only (for instant display without loading state).
    func cachedImage(for url: URL, quality: ImageQuality = .thumb) -> UIImage? {
        memoryCache.object(forKey: memoryKey(diskKey: cacheKey(for: url), quality: quality))
    }

    /// Disk cache key (per URL). The on-disk file is the original downloaded bytes,
    /// independent of decode size, so the key does not include quality.
    private func cacheKey(for url: URL) -> String {
        let urlKey = url.absoluteString as NSString
        if let cachedKey = keyCache.object(forKey: urlKey) {
            return cachedKey as String
        }
        let hashed = url.absoluteString.sha256Hash()
        keyCache.setObject(hashed as NSString, forKey: urlKey)
        return hashed
    }

    /// Memory cache key (per URL *and* decode size). A poster shown as a small card and
    /// the same poster shown full-screen must not evict each other's decoded bitmap.
    private func memoryKey(diskKey: String, quality: ImageQuality) -> NSString {
        "\(diskKey)#\(quality.keySuffix)" as NSString
    }

    /// Get an image at the requested `quality`, decoded off the main thread.
    /// Stale-while-revalidate: returns cached immediately, refreshes in background if stale.
    func image(for url: URL, quality: ImageQuality = .thumb, forceRefresh: Bool = false) async -> UIImage? {
        let diskKey = cacheKey(for: url)
        let memKey = memoryKey(diskKey: diskKey, quality: quality)

        // 1. Memory cache (already decoded at this quality)
        if !forceRefresh, let cached = memoryCache.object(forKey: memKey) {
            updateAccessTime(for: diskKey)
            scheduleStaleRefresh(url: url, key: diskKey)
            return cached
        }

        // 2. Disk cache — decode the stored original bytes to the requested size
        if !forceRefresh, let cacheDir = cacheDirectory {
            let maxPx = quality.maxPixelSize
            let decoded = await Task.detached(priority: .userInitiated) { [cacheDir] in
                self.loadFromDiskSync(cacheDir: cacheDir, key: diskKey, maxPixelSize: maxPx)
            }.value

            if let decoded {
                memoryCache.setObject(decoded, forKey: memKey)
                updateAccessTime(for: diskKey)
                scheduleStaleRefresh(url: url, key: diskKey)
                return decoded
            }
        }

        // 3. Download original bytes (coalesced), then decode to the requested size
        guard let data = await fetchOriginalData(url: url, key: diskKey) else { return nil }
        let decoded = await decodeDownsampled(data: data, maxPixelSize: quality.maxPixelSize)
        if let decoded {
            memoryCache.setObject(decoded, forKey: memKey)
        }
        return decoded
    }

    /// Get an image at full resolution for hero/backdrop surfaces.
    /// Thin wrapper over `image(for:quality:)` — kept for call-site clarity.
    func imageFullSize(for url: URL, forceRefresh: Bool = false) async -> UIImage? {
        await image(for: url, quality: .full, forceRefresh: forceRefresh)
    }

    /// Prefetch images in background (limited concurrency).
    /// Defaults to `.thumb`: this warms the on-disk original bytes (the expensive part is
    /// the network), so a later `.full` read decodes straight from disk without re-downloading.
    func prefetch(urls: [URL], quality: ImageQuality = .thumb) {
        Task.detached(priority: .utility) { [weak self] in
            // Limit to 30 URLs, 8 concurrent for faster prefetch
            let urlsToFetch = Array(urls.prefix(30))
            await withTaskGroup(of: Void.self) { group in
                var count = 0
                for url in urlsToFetch {
                    if count >= 8 {
                        await group.next()
                        count -= 1
                    }
                    group.addTask {
                        _ = await self?.image(for: url, quality: quality)
                    }
                    count += 1
                }
            }
        }
    }

    /// Clear all cached images
    func clearAll() async {
        memoryCache.removeAllObjects()
        cacheMetadata.removeAll()

        guard let dir = cacheDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saveMetadata()
    }

    /// Get total disk cache size in bytes
    func getCacheSize() -> Int64 {
        guard let dir = cacheDirectory else { return 0 }
        var size: Int64 = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        return size
    }

    /// Get formatted cache size string
    func getFormattedCacheSize() -> String {
        let bytes = getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Get raw image data for a URL (for Vision processing)
    /// Returns cached data or downloads if needed
    func imageData(for url: URL) async -> Data? {
        let key = cacheKey(for: url)

        // Check disk cache first
        if let cacheDir = cacheDirectory {
            let fileURL = cacheDir.appendingPathComponent(key)
            if let data = try? Data(contentsOf: fileURL) {
                return data
            }
        }

        // Download (coalesced) and persist if needed
        return await fetchOriginalData(url: url, key: key)
    }

    // MARK: - Private Implementation

    private func scheduleStaleRefresh(url: URL, key: String) {
        Task.detached(priority: .low) { [weak self] in
            await self?.refreshIfStale(url: url, key: key)
        }
    }

    private func updateAccessTime(for key: String) {
        if var entry = cacheMetadata[key] {
            entry.lastAccessedAt = Date()
            cacheMetadata[key] = entry
            // Don't save immediately to avoid excessive I/O, will be saved on next write
        }
    }

    private func refreshIfStale(url: URL, key: String) async {
        await ensureMetadataLoaded()
        guard let entry = cacheMetadata[key] else { return }
        let age = Date().timeIntervalSince(entry.cachedAt)

        // Refresh if older than TTL
        if age > defaultTTL {
            if await fetchOriginalData(url: url, key: key) != nil {
                // Drop decoded tiers so the next read re-decodes the fresh bytes.
                memoryCache.removeObject(forKey: memoryKey(diskKey: key, quality: .thumb))
                memoryCache.removeObject(forKey: memoryKey(diskKey: key, quality: .full))
            }
        }
    }

    /// Download the original image bytes, validate, persist to disk, and return them.
    /// Coalesced per-URL so concurrent requests share a single network fetch.
    private func fetchOriginalData(url: URL, key: String) async -> Data? {
        if let existing = activeDownloads[url] {
            return await existing.value
        }

        let task = Task<Data?, Never> { [weak self] in
            guard let self = self else { return nil }

            defer {
                Task { await self.removeActiveDownload(for: url) }
            }

            // Bounded retry: Plex's image/transcode endpoints transiently 5xx, time
            // out, or return incomplete bytes under load. Retry those a couple of times
            // with backoff so a single blip doesn't strand a poster on the failure icon
            // forever. A 4xx (the art genuinely isn't there) is terminal — no retry.
            let maxAttempts = 3
            let backoff: [UInt64] = [500_000_000, 1_500_000_000] // ns before retries 2 and 3

            for attempt in 0..<maxAttempts {
                let isLastAttempt = attempt == maxAttempts - 1
                do {
                    let (data, response) = try await self.session.data(from: url)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        return nil
                    }

                    let status = httpResponse.statusCode
                    if status == 200 {
                        // Validate image data is complete before caching. Incomplete or
                        // corrupt bytes are treated as a transient failure (retryable).
                        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                              CGImageSourceGetStatus(imageSource) == .statusComplete,
                              CGImageSourceGetCount(imageSource) > 0 else {
                            print("💾 ImageCacheManager: incomplete/corrupt image data from \(url.lastPathComponent) (attempt \(attempt + 1)/\(maxAttempts))")
                            if isLastAttempt { return nil }
                            try? await Task.sleep(nanoseconds: backoff[attempt])
                            continue
                        }

                        await self.saveToDisk(data: data, key: key, url: url)
                        return data
                    }

                    // 5xx is transient (retry); 4xx and other statuses are terminal.
                    if (500...599).contains(status), !isLastAttempt {
                        print("💾 ImageCacheManager: HTTP \(status) for \(url.lastPathComponent), retrying (attempt \(attempt + 1)/\(maxAttempts))")
                        try? await Task.sleep(nanoseconds: backoff[attempt])
                        continue
                    }
                    return nil
                } catch {
                    // Network error / timeout — retryable.
                    print("💾 ImageCacheManager: Download failed for \(url.lastPathComponent) (attempt \(attempt + 1)/\(maxAttempts)): \(error.localizedDescription)")
                    if isLastAttempt { return nil }
                    try? await Task.sleep(nanoseconds: backoff[attempt])
                    continue
                }
            }
            return nil
        }

        activeDownloads[url] = task
        return await task.value
    }

    private func removeActiveDownload(for url: URL) {
        activeDownloads.removeValue(forKey: url)
    }

    // MARK: - Disk Operations

    private func saveToDisk(data: Data, key: String, url: URL) {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(key)

        do {
            try data.write(to: fileURL, options: .atomic)

            // Update metadata
            let entry = ImageCacheEntry(
                url: url.absoluteString,
                cachedAt: Date(),
                lastAccessedAt: Date(),
                fileSize: Int64(data.count)
            )
            cacheMetadata[key] = entry
            saveMetadata()

            // Check if we need to evict
            Task {
                await evictIfNeeded()
            }
        } catch {
            print("💾 ImageCacheManager: Failed to save image to disk: \(error.localizedDescription)")
        }
    }

    // MARK: - LRU Eviction

    private func evictIfNeeded() async {
        let currentSize = getCacheSize()
        guard currentSize > maxDiskCacheSize else { return }

        // Sort by last accessed time (oldest first)
        let sortedEntries = cacheMetadata.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        var freedSpace: Int64 = 0
        let targetFreeSpace = currentSize - (maxDiskCacheSize * 8 / 10)  // Free up to 80% of max

        guard let cacheDir = cacheDirectory else { return }

        for (key, entry) in sortedEntries {
            if freedSpace >= targetFreeSpace { break }

            let fileURL = cacheDir.appendingPathComponent(key)
            do {
                try FileManager.default.removeItem(at: fileURL)
                freedSpace += entry.fileSize
                cacheMetadata.removeValue(forKey: key)
                // Drop any decoded tiers for this key
                memoryCache.removeObject(forKey: memoryKey(diskKey: key, quality: .thumb))
                memoryCache.removeObject(forKey: memoryKey(diskKey: key, quality: .full))
            } catch {
                // File might already be gone
            }
        }

        saveMetadata()
    }

    // MARK: - Metadata Persistence

    private func ensureMetadataLoaded() async {
        if !metadataLoaded {
            loadMetadata()
        }
    }

    private func loadMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(metadataFileName)

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: ImageCacheEntry].self, from: data) else {
            metadataLoaded = true
            return
        }

        cacheMetadata = decoded
        metadataLoaded = true
    }

    private func saveMetadata() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(metadataFileName)

        guard let data = try? JSONEncoder().encode(cacheMetadata) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Image Decoding

    nonisolated private func decodedImage(_ image: UIImage) -> UIImage {
        if #available(tvOS 15.0, iOS 15.0, *) {
            return image.preparingForDisplay() ?? image
        }
        return image
    }

    /// Decode original bytes to a display-sized bitmap, off the actor (and off the main thread).
    private func decodeDownsampled(data: Data, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { [self] in
            self.downsampledImage(from: data, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Load the stored original bytes from disk and decode at `maxPixelSize`.
    /// Runs outside actor isolation for parallel decode.
    nonisolated private func loadFromDiskSync(cacheDir: URL, key: String, maxPixelSize: CGFloat) -> UIImage? {
        let fileURL = cacheDir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        // Validate image data is complete using CGImageSource
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(imageSource) == .statusComplete,
              CGImageSourceGetCount(imageSource) > 0 else {
            // Data is corrupt or incomplete - delete the cached file
            try? FileManager.default.removeItem(at: fileURL)
            print("💾 ImageCacheManager: Deleted corrupt cached image: \(key)")
            return nil
        }

        // Decode directly at the target size without allocating a full-resolution buffer.
        if let downsampled = downsampledImage(from: data, maxPixelSize: maxPixelSize) {
            return downsampled
        }

        // Fallback to standard decoding if downsampling fails
        guard let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return decodedImage(image)
    }

    // MARK: - GPU-Efficient Downsampling

    /// Downsample image data to `maxPixelSize` (longest edge, in pixels) using CGImageSource.
    /// Decodes directly at the target size without allocating a full-resolution buffer, and
    /// will not upscale beyond the source's native resolution.
    nonisolated private func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,  // Decode now (in background)
            kCGImageSourceCreateThumbnailWithTransform: true,  // Apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: downsampledImage)
    }
}

// MARK: - URLSessionDelegate (SSL Certificate Handling)

extension ImageCacheManager: URLSessionDelegate {
    /// Handle SSL certificate challenges for self-signed certificates (same as PlexNetworkManager)
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Trust self-signed certificates for:
        // - IP addresses (local Plex servers)
        // - plex.direct domains
        // - Port 32400 (default Plex port)
        let isIPAddress = host.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
        let isPlexDirect = host.hasSuffix(".plex.direct")
        let isPlexPort = port == 32400

        if isIPAddress || isPlexDirect || isPlexPort {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
