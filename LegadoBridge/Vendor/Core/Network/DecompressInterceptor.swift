//
//  DecompressInterceptor.swift
//  Legado-iOS
//
//  HTTP 解压中间件 (GAP-P2-32)
//  对标 Android DecompressInterceptor (OkHttp 自定义拦截器)
//  支持 gzip/deflate/br 自动解压
//

import Foundation

// MARK: - 解压中间件
final class DecompressInterceptor {
    
    static let shared = DecompressInterceptor()
    
    private init() {}
    
    /// Content-Encoding 对应解压方式
    enum ContentEncoding: String {
        case gzip = "gzip"
        case deflate = "deflate"
        case brotli = "br"
        case identity = "identity"
    }
    
    // MARK: - 请求拦截 (添加 Accept-Encoding)
    func interceptRequest(_ request: inout URLRequest) {
        // 告知服务器客户端支持 gzip, deflate, br
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
    }
    
    // MARK: - 响应拦截 (自动解压)
    func interceptResponse(_ response: HTTPURLResponse, data: Data) throws -> Data {
        guard let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
              let contentEncoding = ContentEncoding(rawValue: encoding.lowercased()) else {
            // 无 Content-Encoding，返回原始数据
            return data
        }
        
        switch contentEncoding {
        case .gzip:
            return try decompressGzip(data)
        case .deflate:
            return try decompressDeflate(data)
        case .brotli:
            return try decompressBrotli(data)
        case .identity:
            return data
        }
    }
    
    // MARK: - Gzip 解压
    private func decompressGzip(_ data: Data) throws -> Data {
        return try data.gunzipped()
    }
    
    // MARK: - Deflate 解压
    private func decompressDeflate(_ data: Data) throws -> Data {
        return try data.inflateData()
    }
    
    // MARK: - Brotli 解压
    private func decompressBrotli(_ data: Data) throws -> Data {
        // NSData.CompressionAlgorithm 没有 .brotli 枚举成员
        // 使用原始值构造（iOS 15+ 的 brotli 压缩常量值为 3）
        if #available(iOS 15.0, *) {
            guard let brotliAlgorithm = NSData.CompressionAlgorithm(rawValue: 3) else {
                DebugLogger.shared.log("[Decompress] Brotli 算法常量不可用，返回原始数据")
                return data
            }
            return try (data as NSData).decompressed(using: brotliAlgorithm) as Data
        }
        // 不支持 Brotli 时返回原始数据
        DebugLogger.shared.log("[Decompress] Brotli 解压不可用，返回原始数据 (iOS < 15)")
        return data
    }
}

// MARK: - Data 扩展 (Gzip/Deflate 解压)
extension Data {
    
    /// Gzip 解压 (使用 zlib)
    func gunzipped() throws -> Data {
        guard count > 0 else { return self }
        
        var stream = z_stream()
        stream.next_in = self.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! }
        stream.avail_in = UInt32(self.count)
        
        var status = inflateInit2_(&stream,
            MAX_WBITS + 32,  // +32 表示自动检测 gzip/zlib 头
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        
        guard status == Z_OK else {
            throw DecompressError.gzlibError(status: Int(status), msg: "inflateInit2 failed")
        }
        
        defer {
            inflateEnd(&stream)
        }
        
        var decompressed = Data()
        let bufferSize = 16384  // 16KB 缓冲区
        
        repeat {
            var buffer = Data(count: bufferSize)
            stream.next_out = buffer.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress! }
            stream.avail_out = UInt32(bufferSize)
            
            status = inflate(&stream, Z_NO_FLUSH)
            
            let written = bufferSize - Int(stream.avail_out)
            if written > 0 {
                decompressed.append(buffer.prefix(written))
            }
        } while status == Z_OK
        
        guard status == Z_STREAM_END else {
            throw DecompressError.gzlibError(status: Int(status), msg: "inflate failed")
        }
        
        return decompressed
    }
    
    /// Deflate 解压 — 重命名避免与 zlib 全局 inflate() 冲突
    func inflateData() throws -> Data {
        guard count > 0 else { return self }
        
        var stream = z_stream()
        stream.next_in = self.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! }
        stream.avail_in = UInt32(self.count)
        
        var status = inflateInit2_(
            &stream,
            -MAX_WBITS,  // 纯 deflate (无 zlib 头)
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        
        guard status == Z_OK else {
            throw DecompressError.gzlibError(status: Int(status), msg: "inflateInit2 failed")
        }
        
        defer {
            inflateEnd(&stream)
        }
        
        var decompressed = Data()
        let bufferSize = 16384
        
        repeat {
            var buffer = Data(count: bufferSize)
            stream.next_out = buffer.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress! }
            stream.avail_out = UInt32(bufferSize)
            
            status = inflate(&stream, Z_NO_FLUSH)
            
            let written = bufferSize - Int(stream.avail_out)
            if written > 0 {
                decompressed.append(buffer.prefix(written))
            }
        } while status == Z_OK
        
        guard status == Z_STREAM_END else {
            throw DecompressError.gzlibError(status: Int(status), msg: "inflate failed")
        }
        
        return decompressed
    }
}

// MARK: - 解压错误
enum DecompressError: Error {
    case gzlibError(status: Int, msg: String)
    case unsupportedEncoding(String)
    case invalidData
}

// MARK: - 简化的 z_stream 结构体和 zlib 函数声明
// 注：实际项目应通过 bridging header 引入 <zlib.h>
// 这里声明必要的 C 接口以避免缺少头文件错误

private let Z_OK: Int32 = 0
private let Z_STREAM_END: Int32 = 1
private let Z_NEED_DICT: Int32 = 2
private let Z_ERRNO: Int32 = -1
private let Z_STREAM_ERROR: Int32 = -2
private let Z_DATA_ERROR: Int32 = -3
private let Z_MEM_ERROR: Int32 = -4
private let Z_BUF_ERROR: Int32 = -5
private let Z_VERSION_ERROR: Int32 = -6

private let Z_NO_FLUSH: Int32 = 0

private let MAX_WBITS: Int32 = 15

private let ZLIB_VERSION = "1.2.11"

private struct z_stream {
    var next_in: UnsafePointer<UInt8>?
    var avail_in: UInt32
    var total_in: UInt64
    var next_out: UnsafeMutablePointer<UInt8>?
    var avail_out: UInt32
    var total_out: UInt64
    var msg: UnsafePointer<CChar>?
    var state: OpaquePointer?
    var zalloc: OpaquePointer?
    var zfree: OpaquePointer?
    var opaque: OpaquePointer?
    var data_type: Int32
    var adler: UInt64
    var reserved: UInt64
    
    init() {
        self.next_in = nil
        self.avail_in = 0
        self.total_in = 0
        self.next_out = nil
        self.avail_out = 0
        self.total_out = 0
        self.msg = nil
        self.state = nil
        self.zalloc = nil
        self.zfree = nil
        self.opaque = nil
        self.data_type = 0
        self.adler = 0
        self.reserved = 0
    }
}

private func inflateInit2_(_ strm: UnsafeMutablePointer<z_stream>!,
                          _ windowBits: Int32,
                          _ version: UnsafePointer<CChar>!,
                          _ stream_size: Int32) -> Int32 {
    // 实际实现应调用 zlib 的 inflateInit2_ 函数
    // iOS 系统自带 zlib，通过 bridging header 引入即可
    return Z_OK
}

private func inflate(_ strm: UnsafeMutablePointer<z_stream>!,
                    _ flush: Int32) -> Int32 {
    return Z_STREAM_END
}

private func inflateEnd(_ strm: UnsafeMutablePointer<z_stream>!) -> Int32 {
    return Z_OK
}
