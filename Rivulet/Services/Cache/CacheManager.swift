//
//  CacheManager.swift
//  Rivulet
//
//  Adapted from plex_watchOS CacheManager
//  JSON file caching for offline access to Plex metadata
//

import Foundation

actor CacheManager {
    static let shared = CacheManager()

    // MARK: - Cache File Names

    private let librariesCacheFile = "libraries_cache.json"
    private let moviesCachePrefix = "movies_"
    private let showsCachePrefix = "shows_"
    private let seasonsCachePrefix = "seasons_"
    private let episodesCachePrefix = "episodes_"
    private let onDeckCacheFile = "ondeck_cache.json"
    private let recentlyAddedPrefix = "recently_added_"
    private let hubsCacheFile = "hubs_cache.json"
    private let cacheInfoFile = "cache_info.json"

    // MARK: - Cache Configuration

    // MARK: - In-Memory Cache

    private var cachedTimestamps: [String: Date] = [:]
    private var timestampsLoaded = false
    private let memoryCache = NSCache<NSString, NSData>()

    // MARK: - Cache Directory

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("PlexCache")
    }

    // MARK: - Initialization

    private init() {
        memoryCache.countLimit = 64 // Larger limit for tvOS
        Task {
            await createCacheDirectoryIfNeeded()
        }
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDir = cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Timestamp Management

    private func loadTimestampsFromDisk() -> [String: Date] {
        guard let cacheDir = cacheDirectory else { return [:] }
        let fileURL = cacheDir.appendingPathComponent(cacheInfoFile)
        guard let data = try? Data(contentsOf: fileURL),
              let timestamps = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return timestamps
    }

    private func writeTimestampsToDisk(_ timestamps: [String: Date]) {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(cacheInfoFile)
        if timestamps.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        if let data = try? JSONEncoder().encode(timestamps) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func ensureTimestampsLoaded() {
        guard !timestampsLoaded else { return }
        cachedTimestamps = loadTimestampsFromDisk()
        timestampsLoaded = true
    }

    private func setCacheTimestamp(for key: String) {
        ensureTimestampsLoaded()
        cachedTimestamps[key] = Date()
        writeTimestampsToDisk(cachedTimestamps)
    }

    private func removeTimestamp(for key: String) {
        ensureTimestampsLoaded()
        cachedTimestamps.removeValue(forKey: key)
        writeTimestampsToDisk(cachedTimestamps)
    }

    private func resetTimestamps() {
        cachedTimestamps = [:]
        timestampsLoaded = true
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(cacheInfoFile)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Generic Cache Operations

    private func cacheData<T: Encodable>(_ value: T, fileName: String) {
        guard let cacheDir = cacheDirectory,
              let data = try? JSONEncoder().encode(value) else { return }
        let fileURL = cacheDir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            memoryCache.setObject(data as NSData, forKey: fileName as NSString)
            setCacheTimestamp(for: fileName)
        } catch {
            print("CacheManager: Failed to write cache file \(fileName): \(error.localizedDescription)")
        }
    }

    private func decodedCache<T: Decodable>(for fileName: String, as type: T.Type) -> T? {
        // Check memory cache first
        if let rawData = memoryCache.object(forKey: fileName as NSString) {
            let data = rawData as Data
            if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
            memoryCache.removeObject(forKey: fileName as NSString)
        }

        // Check disk cache
        guard let cacheDir = cacheDirectory else { return nil }
        let fileURL = cacheDir.appendingPathComponent(fileName)
        let readStart = ProcessInfo.processInfo.systemUptime
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let readMs = Int((ProcessInfo.processInfo.systemUptime - readStart) * 1000)
        memoryCache.setObject(data as NSData, forKey: fileName as NSString)
        let decodeStart = ProcessInfo.processInfo.systemUptime
        let decoded = try? JSONDecoder().decode(T.self, from: data)
        let decodeMs = Int((ProcessInfo.processInfo.systemUptime - decodeStart) * 1000)
        if readMs > 200 || decodeMs > 200 {
            StartupTimer.mark("  decodedCache(\(fileName)) read=\(readMs)ms decode=\(decodeMs)ms bytes=\(data.count)")
        }
        return decoded
    }

    // MARK: - Library Cache

    func cacheLibraries(_ libraries: [PlexLibrary]) {
        cacheData(libraries, fileName: librariesCacheFile)
    }

    func getCachedLibraries() -> [PlexLibrary]? {
        return decodedCache(for: librariesCacheFile, as: [PlexLibrary].self)
    }

    // MARK: - Movies Cache

    func cacheMovies(_ movies: [PlexMetadata], forLibrary libraryKey: String) {
        let fileName = "\(moviesCachePrefix)\(libraryKey).json"
        cacheData(movies, fileName: fileName)
    }

    func getCachedMovies(forLibrary libraryKey: String) -> [PlexMetadata]? {
        let fileName = "\(moviesCachePrefix)\(libraryKey).json"
        let result = decodedCache(for: fileName, as: [PlexMetadata].self)
        return result
    }

    // MARK: - TV Shows Cache

    func cacheShows(_ shows: [PlexMetadata], forLibrary libraryKey: String) {
        let fileName = "\(showsCachePrefix)\(libraryKey).json"
        cacheData(shows, fileName: fileName)
    }

    func getCachedShows(forLibrary libraryKey: String) -> [PlexMetadata]? {
        let fileName = "\(showsCachePrefix)\(libraryKey).json"
        let result = decodedCache(for: fileName, as: [PlexMetadata].self)
        return result
    }

    // MARK: - Seasons Cache

    func cacheSeasons(_ seasons: [PlexMetadata], forShow showKey: String) {
        let fileName = "\(seasonsCachePrefix)\(showKey).json"
        cacheData(seasons, fileName: fileName)
    }

    func getCachedSeasons(forShow showKey: String) -> [PlexMetadata]? {
        let fileName = "\(seasonsCachePrefix)\(showKey).json"
        return decodedCache(for: fileName, as: [PlexMetadata].self)
    }

    // MARK: - Episodes Cache

    func cacheEpisodes(_ episodes: [PlexMetadata], forSeason seasonKey: String) {
        let fileName = "\(episodesCachePrefix)\(seasonKey).json"
        cacheData(episodes, fileName: fileName)
    }

    func getCachedEpisodes(forSeason seasonKey: String) -> [PlexMetadata]? {
        let fileName = "\(episodesCachePrefix)\(seasonKey).json"
        return decodedCache(for: fileName, as: [PlexMetadata].self)
    }

    // MARK: - On Deck Cache

    func cacheOnDeck(_ items: [PlexMetadata]) {
        cacheData(items, fileName: onDeckCacheFile)
    }

    func getCachedOnDeck() -> [PlexMetadata]? {
        return decodedCache(for: onDeckCacheFile, as: [PlexMetadata].self)
    }

    // MARK: - Recently Added Cache

    func cacheRecentlyAdded(_ items: [PlexMetadata], forLibrary libraryKey: String) {
        let fileName = "\(recentlyAddedPrefix)\(libraryKey).json"
        cacheData(items, fileName: fileName)
    }

    func getCachedRecentlyAdded(forLibrary libraryKey: String) -> [PlexMetadata]? {
        let fileName = "\(recentlyAddedPrefix)\(libraryKey).json"
        return decodedCache(for: fileName, as: [PlexMetadata].self)
    }

    // MARK: - Hubs Cache (for home screen)

    func cacheHubs(_ hubs: [PlexHub]) {
        cacheData(hubs, fileName: hubsCacheFile)
    }

    func getCachedHubs() -> [PlexHub]? {
        return decodedCache(for: hubsCacheFile, as: [PlexHub].self)
    }

    // MARK: - Library Hubs Cache (for individual library screens)

    private let libraryHubsCachePrefix = "library_hubs_"

    func cacheLibraryHubs(_ hubs: [PlexHub], forLibrary libraryKey: String) {
        let fileName = "\(libraryHubsCachePrefix)\(libraryKey).json"
        cacheData(hubs, fileName: fileName)
    }

    func getCachedLibraryHubs(forLibrary libraryKey: String) -> [PlexHub]? {
        let fileName = "\(libraryHubsCachePrefix)\(libraryKey).json"
        return decodedCache(for: fileName, as: [PlexHub].self)
    }

    // MARK: - Clear Cache

    func clearAllCache() {
        guard let cacheDir = cacheDirectory else { return }

        let ourPrefixes = [
            moviesCachePrefix,
            showsCachePrefix,
            seasonsCachePrefix,
            episodesCachePrefix,
            recentlyAddedPrefix
        ]

        let ourFiles = [
            librariesCacheFile,
            onDeckCacheFile,
            hubsCacheFile,
            cacheInfoFile
        ]

        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                let fileName = file.lastPathComponent

                // Skip system database files
                if fileName.hasPrefix("Cache.db") {
                    continue
                }

                // Delete files matching our cache patterns
                let shouldDelete = ourFiles.contains(fileName) ||
                                 ourPrefixes.contains { fileName.hasPrefix($0) }

                if shouldDelete {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        memoryCache.removeAllObjects()
        resetTimestamps()
    }

    func clearLibraryCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(librariesCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: librariesCacheFile as NSString)
        removeTimestamp(for: librariesCacheFile)
    }

    func clearOnDeckCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(onDeckCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: onDeckCacheFile as NSString)
        removeTimestamp(for: onDeckCacheFile)
    }

    func clearHubsCache() {
        guard let cacheDir = cacheDirectory else { return }
        let fileURL = cacheDir.appendingPathComponent(hubsCacheFile)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: hubsCacheFile as NSString)
        removeTimestamp(for: hubsCacheFile)
    }

    func clearLibraryHubsCache() {
        guard let cacheDir = cacheDirectory else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                let fileName = file.lastPathComponent
                if fileName.hasPrefix(libraryHubsCachePrefix) {
                    try? FileManager.default.removeItem(at: file)
                    memoryCache.removeObject(forKey: fileName as NSString)
                    removeTimestamp(for: fileName)
                }
            }
        }
    }

    func clearMoviesCache(forLibrary libraryKey: String) {
        guard let cacheDir = cacheDirectory else { return }
        let fileName = "\(moviesCachePrefix)\(libraryKey).json"
        let fileURL = cacheDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: fileName as NSString)
        removeTimestamp(for: fileName)
    }

    func clearShowsCache(forLibrary libraryKey: String) {
        guard let cacheDir = cacheDirectory else { return }
        let fileName = "\(showsCachePrefix)\(libraryKey).json"
        let fileURL = cacheDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
        memoryCache.removeObject(forKey: fileName as NSString)
        removeTimestamp(for: fileName)
    }

    // MARK: - Cache Size

    func getCacheSize() -> Int64 {
        guard let cacheDir = cacheDirectory else { return 0 }
        var totalSize: Int64 = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for file in files {
                if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    func getFormattedCacheSize() -> String {
        let bytes = getCacheSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
