//
//  ImageCacheManager.swift
//  Legado-iOS
//
//  图片缓存管理器
//

import UIKit
import SwiftUI
import CoreData
import JavaScriptCore


/// 图片缓存管理器
class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()
    
    // 内存缓存
    private let memoryCache = NSCache<NSString, UIImage>()
    
    // 磁盘缓存
    private let fileManager = FileManager.default
    let cacheDirectory: URL
    private let inFlightQueue = DispatchQueue(label: "legado.imagecache.inflight")
    private var inFlightRequests: [String: [(UIImage?) -> Void]] = [:]
    
    // 配置
    var maxMemoryCost = 100 * 1024 * 1024  // 100MB
    var maxDiskSize = 500 * 1024 * 1024    // 500MB
    
    init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = maxMemoryCost
        
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("images", isDirectory: true)
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - 加载图片
    
    func loadImage(from url: String, completion: @escaping (UIImage?) -> Void) {
        let cacheKey = cacheKey(for: url) as NSString
        
        // 1. 检查内存缓存
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }
        
        // 2. 检查磁盘缓存
        if let diskImage = loadFromDisk(cacheKey: cacheKey as String) {
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: imageCost(diskImage))
            completion(diskImage)
            return
        }

        if enqueueInFlight(for: cacheKey as String, completion: completion) {
            return
        }

        // 3. 网络加载
        downloadImage(from: url) { [weak self] image in
            guard let self = self, let image = image else {
                self?.completeInFlight(for: cacheKey as String, image: nil)
                return
            }
            
            self.memoryCache.setObject(image, forKey: cacheKey, cost: self.imageCost(image))
            self.saveToDisk(image: image, cacheKey: cacheKey as String)
            self.completeInFlight(for: cacheKey as String, image: image)
        }
    }
    
    // 异步加载（SwiftUI 友好）
    @MainActor
    func loadImage(from url: String, sourceId: UUID? = nil) async -> UIImage? {
        if url.hasPrefix("/") || url.hasPrefix("file://") {
            let path = url.hasPrefix("file://") ? String(url.dropFirst(7)) : url
            return UIImage(contentsOfFile: path)
        }

        let source = resolveSource(sourceId: sourceId)
        let resolvedURL = resolveCoverURLIfNeeded(url, source: source) ?? url
        let headers = buildImageHeaders(source: source, imageURL: resolvedURL)
        
        return await withCheckedContinuation { continuation in
            loadImage(from: resolvedURL, headers: headers) { image in
                continuation.resume(returning: image)
            }
        }
    }

    func loadImage(from url: String, headers: [String: String], completion: @escaping (UIImage?) -> Void) {
        let cacheKey = cacheKey(for: url, headers: headers) as NSString

        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }

        if let diskImage = loadFromDisk(cacheKey: cacheKey as String) {
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: imageCost(diskImage))
            completion(diskImage)
            return
        }

        if enqueueInFlight(for: cacheKey as String, completion: completion) {
            return
        }

        downloadImage(from: url, headers: headers) { [weak self] image in
            guard let self = self, let image = image else {
                self?.completeInFlight(for: cacheKey as String, image: nil)
                return
            }

            self.memoryCache.setObject(image, forKey: cacheKey, cost: self.imageCost(image))
            self.saveToDisk(image: image, cacheKey: cacheKey as String)
            self.completeInFlight(for: cacheKey as String, image: image)
        }
    }

    @MainActor
    private func resolveSource(sourceId: UUID?) -> BookSource? {
        guard let sourceId else { return nil }
        let context = CoreDataStack.shared.viewContext
        let request: NSFetchRequest<BookSource> = BookSource.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "sourceId == %@", sourceId as CVarArg)

        return try? context.fetch(request).first
    }

    @MainActor
    private func resolveCoverURLIfNeeded(_ url: String, source: BookSource?) -> String? {
        
        guard let source,
              let decodeJS = source.coverDecodeJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !decodeJS.isEmpty else {
            return nil
        }

        let executionContext = ExecutionContext()
        executionContext.source = source
        executionContext.baseURL = URL(string: source.bookSourceUrl)
        executionContext.jsContext.setValue(url, forKey: "src")
        executionContext.jsContext.setValue(url, forKey: "result")

        let directValue = executionContext.jsContext.evaluateScript(decodeJS)?.toString()
        let resultValue = executionContext.jsContext.objectForKeyedSubscript("result")?.toString()
        let value = [directValue, resultValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "undefined" && $0 != "null" }

        guard let value else {
            return nil
        }

        if let resolved = URL(string: value, relativeTo: URL(string: source.bookSourceUrl))?.absoluteURL.absoluteString {
            return resolved
        }

        return value
    }
    
    // MARK: - 下载图片
    
    private let downloadTimeout: TimeInterval = 30
    
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 10
        return URLSession(configuration: config)
    }()
    
    private func downloadImage(from url: String, headers: [String: String] = [:], completion: @escaping (UIImage?) -> Void) {
        guard let imageURL = URL(string: url) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: imageURL)
        request.timeoutInterval = downloadTimeout
        request.httpShouldHandleCookies = true
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                DebugLogger.shared.log("图片下载失败: \(url) - \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let image = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            DispatchQueue.main.async {
                completion(image)
            }
        }.resume()
    }

    @MainActor
    private func buildImageHeaders(source: BookSource?, imageURL: String) -> [String: String] {
        var headers: [String: String] = [:]

        if let headerString = source?.header,
           let data = headerString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in json {
                headers[key] = "\(value)"
            }
        }

        if headers["Referer"] == nil {
            headers["Referer"] = source?.bookSourceUrl
        }

        if headers["User-Agent"] == nil {
            headers["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
        }

        if let imageURL = URL(string: imageURL),
           let cookies = HTTPCookieStorage.shared.cookies(for: imageURL),
           !cookies.isEmpty,
           headers["Cookie"] == nil {
            headers["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }

        return headers
    }

    private func enqueueInFlight(for key: String, completion: @escaping (UIImage?) -> Void) -> Bool {
        inFlightQueue.sync {
            if inFlightRequests[key] != nil {
                inFlightRequests[key]?.append(completion)
                return true
            }
            inFlightRequests[key] = [completion]
            return false
        }
    }

    private func completeInFlight(for key: String, image: UIImage?) {
        let callbacks = inFlightQueue.sync { () -> [(UIImage?) -> Void] in
            let callbacks = inFlightRequests[key] ?? []
            inFlightRequests[key] = nil
            return callbacks
        }

        DispatchQueue.main.async {
            callbacks.forEach { $0(image) }
        }
    }
    
    // MARK: - 磁盘缓存
    
    private func loadFromDisk(cacheKey: String) -> UIImage? {
        let filePath = cachePath(for: cacheKey)
        return UIImage(contentsOfFile: filePath)
    }
    
    private func saveToDisk(image: UIImage, cacheKey: String) {
        let filePath = cachePath(for: cacheKey)
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: URL(fileURLWithPath: filePath))
        checkDiskSize()
    }
    
    private func cachePath(for cacheKey: String) -> String {
        return cacheDirectory.appendingPathComponent(cacheKey).path
    }

    private func cacheKey(for url: String, headers: [String: String] = [:]) -> String {
        guard !headers.isEmpty else { return url.md5() }

        let fingerprint = headers
            .map { key, value in
                (key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        if fingerprint.isEmpty {
            return url.md5()
        }

        return "\(url)|\(fingerprint)".md5()
    }
    
    // MARK: - 缓存清理
    
    func clearCache() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    private func checkDiskSize() {
        let size = getDiskSize()
        if size > maxDiskSize {
            clearOldCache()
        }
    }
    
    private func getDiskSize() -> Int64 {
        var totalSize: Int64 = 0
        if let enumerator = fileManager.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        return totalSize
    }
    
    private func clearOldCache() {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        
        let sorted = files.sorted { url1, url2 in
            let date1 = try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let date2 = try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return date1 ?? .distantPast < date2 ?? .distantPast
        }
        
        let deleteCount = max(1, files.count / 5)
        for file in sorted.prefix(deleteCount) {
            try? fileManager.removeItem(at: file)
        }
    }
    
    private func imageCost(_ image: UIImage) -> Int {
        Int(image.size.height * image.size.width * image.scale * 4)
    }
}

// MARK: - String 扩展（MD5）
import CryptoKit

extension String {
    func md5() -> String {
        let data = Data(utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
