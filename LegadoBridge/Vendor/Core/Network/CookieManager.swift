//
//  CookieManager.swift
//  Legado-iOS
//
//  Cookie 管理器 - 对标 Android Cookie 持久化
//  功能：存储、读取、自动注入 Cookie
//

import Foundation
import CoreData

/// Cookie 管理器
/// 负责书源 Cookie 的持久化和自动注入
final class CookieManager {
    static let shared = CookieManager()
    
    private let sessionCookieStorage = HTTPCookieStorage.shared
    private var coreDataStack: CoreDataStack { .shared }
    
    private init() {}
    
    // MARK: - 存储 Cookie
    
    /// 保存 Cookie 到数据库
    /// - Parameters:
    ///   - url: 关联的 URL（通常是书源地址）
    ///   - cookieString: Cookie 字符串（如 "key1=value1; key2=value2"）
    func saveCookie(url: String, cookieString: String) {
        let context = coreDataStack.viewContext
        
        // 检查是否已存在
        let fetchRequest: NSFetchRequest<Cookie> = Cookie.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "url == %@", url)
        
        do {
            let existing = try context.fetch(fetchRequest).first
            
            if let existing = existing {
                existing.cookie = cookieString
            } else {
                Cookie.create(in: context, url: url, cookie: cookieString)
            }
            
            try context.save()
            
            // 同时更新 HTTPCookieStorage
            updateSessionCookies(url: url, cookieString: cookieString)
            
        } catch {
            DebugLogger.shared.log("保存 Cookie 失败: \(error)")
        }
    }
    
    /// 从 HTTPURLResponse 提取并保存 Cookie
    func saveCookies(from response: HTTPURLResponse, for url: URL) {
        guard let headerFields = response.allHeaderFields as? [String: String],
              let cookieHeader = headerFields["Set-Cookie"] else {
            return
        }
        
        // 解析 Cookie
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookieHeader], for: url)
        
        // 构建Cookie字符串
        let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        
        // 保存到数据库（以域名作为 key）
        let hostKey = url.host ?? url.absoluteString
        saveCookie(url: hostKey, cookieString: cookieString)
    }
    
    // MARK: - 读取 Cookie
    
    /// 获取指定 URL 的 Cookie
    func getCookie(for url: String) -> String? {
        let context = coreDataStack.viewContext
        
        let fetchRequest: NSFetchRequest<Cookie> = Cookie.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "url == %@", url)
        fetchRequest.fetchLimit = 1
        
        do {
            return try context.fetch(fetchRequest).first?.cookie
        } catch {
            DebugLogger.shared.log("读取 Cookie 失败: \(error)")
            return nil
        }
    }
    
    /// 获取所有 Cookie
    func getAllCookies() -> [(url: String, cookie: String)] {
        let context = coreDataStack.viewContext
        
        let fetchRequest: NSFetchRequest<Cookie> = Cookie.fetchRequest()
        
        do {
            let cookies = try context.fetch(fetchRequest)
            return cookies.map { ($0.url, $0.cookie) }
        } catch {
            DebugLogger.shared.log("读取所有 Cookie 失败: \(error)")
            return []
        }
    }
    
    // MARK: - 注入 Cookie
    
    /// 为请求添加 Cookie Header
    func addCookieHeader(to request: inout URLRequest, for url: URL) {
        // 优先使用 session 中的 Cookie
        if let cookies = sessionCookieStorage.cookies(for: url),
           !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            return
        }
        
        // 从数据库读取
        let hostKey = url.host ?? url.absoluteString
        if let cookieString = getCookie(for: hostKey) {
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }
    }
    
    // MARK: - 删除 Cookie
    
    /// 删除指定 URL 的 Cookie
    func deleteCookie(for url: String) {
        let context = coreDataStack.viewContext
        
        let fetchRequest: NSFetchRequest<Cookie> = Cookie.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "url == %@", url)
        
        do {
            let cookies = try context.fetch(fetchRequest)
            cookies.forEach { context.delete($0) }
            try context.save()
        } catch {
            DebugLogger.shared.log("删除 Cookie 失败: \(error)")
        }
    }
    
    /// 清空所有 Cookie
    func clearAllCookies() {
        let context = coreDataStack.viewContext
        
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = Cookie.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        
        do {
            try context.execute(deleteRequest)
            try context.save()
            
            // 清空 session storage
            if let cookies = sessionCookieStorage.cookies {
                cookies.forEach { sessionCookieStorage.deleteCookie($0) }
            }
        } catch {
            DebugLogger.shared.log("清空 Cookie 失败: \(error)")
        }
    }
    
    // MARK: - Private
    
    private func updateSessionCookies(url: String, cookieString: String) {
        guard let baseURL = URL(string: "https://\(url)") else { return }
        
        // 解析 Cookie 字符串
        let cookiePairs = cookieString.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        
        for pair in cookiePairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            
            let name = String(parts[0])
            let value = String(parts[1])
            
            let cookie = HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: url,
                .path: "/",
                .secure: "FALSE"
            ])
            
            if let cookie = cookie {
                sessionCookieStorage.setCookie(cookie)
            }
        }
    }
}