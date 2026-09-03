import Foundation
import AppKit
import ImageIO

// MARK: - 百度 OCR 结果模型

struct OCRLine {
    let text: String
    /// 含位置版返回的 bounding box（左上宽高）
    let location: CGRect?
}

struct OCRPageResult {
    let text: String
    let lines: [OCRLine]
    /// 结构化块（本地 Unlimited-OCR grounding 模式产出；云端引擎为空）
    var blocks: [OCRBlock] = []
}

enum BaiduOCRError: LocalizedError {
    case missingCredentials
    case tokenRequestFailed(String)
    case apiError(code: Int, message: String)
    case badResponse(String)
    case imageTooLarge
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "尚未填写百度 OCR 的 API Key / Secret Key，请到「设置」中配置。"
        case .tokenRequestFailed(let msg):
            return "百度 access_token 获取失败：\(msg)（请检查 API Key / Secret Key 是否正确）"
        case .apiError(let code, let message):
            return "百度 OCR 错误 \(code)：\(message)"
        case .badResponse(let msg):
            return "百度 OCR 返回解析失败：\(msg)"
        case .imageTooLarge:
            return "图片过大（base64 后超过 4MB 限制），压缩后仍超限。"
        case .quotaExceeded:
            return "百度 OCR 调用额度不足或已达当日上限，请到百度智能云控制台充值/领取。"
        }
    }
}

// MARK: - 百度 OCR 服务

/// 百度智能云「通用文字识别」REST API 封装。
/// 文档：https://ai.baidu.com/ai-doc/OCR/zk3h7xz52
/// 无限制商务套餐与标准/高精度版接口一致，仅计费/QPS 不同。
actor BaiduOCRService {
    private let apiKey: String
    private let secretKey: String
    private let endpoint: BaiduOCREndpoint
    private let mergeParagraph: Bool

    private var cachedToken: String?
    private var tokenExpireAt: Date = .distantPast

    private let session: URLSession

    init(apiKey: String, secretKey: String, endpoint: BaiduOCREndpoint, mergeParagraph: Bool = true) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = endpoint
        self.mergeParagraph = mergeParagraph

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - access_token 管理

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = cachedToken, Date() < tokenExpireAt {
            return token
        }
        guard !apiKey.isEmpty, !secretKey.isEmpty else { throw BaiduOCRError.missingCredentials }

        var components = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")!
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: secretKey)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BaiduOCRError.tokenRequestFailed("响应不是 JSON")
        }
        if let token = json["access_token"] as? String {
            let expiresIn = (json["expires_in"] as? Double) ?? 2_592_000
            self.cachedToken = token
            // 提前一天过期，留足余量
            self.tokenExpireAt = Date().addingTimeInterval(max(expiresIn - 86_400, 3600))
            return token
        }
        let desc = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "未知错误"
        throw BaiduOCRError.tokenRequestFailed(desc)
    }

    // MARK: - 图片识别

    /// 识别一张图片（JPEG/PNG Data），自动压缩到接口限制内，token 失效自动重试一次。
    /// 含位置版接口（general/accurate）会额外合成 OCRBlock（行级 bbox 归一化）。
    func recognize(imageData: Data) async throws -> OCRPageResult {
        let prepared = try ImageCompressor.prepareForBaidu(imageData)
        let imageSize = ImageCompressor.dimensions(of: prepared)
        return try await recognizePrepared(imageData: prepared, imageSize: imageSize, allowRetry: true)
    }

    private func recognizePrepared(imageData: Data, imageSize: CGSize?, allowRetry: Bool) async throws -> OCRPageResult {
        let token = try await accessToken()
        let url = URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/\(endpoint.rawValue)?access_token=\(token)")!

        var params: [(String, String)] = [
            ("image", imageData.base64EncodedString()),
            ("detect_direction", "true"),
            ("probability", "false")
        ]
        if mergeParagraph {
            params.append(("paragraph", "true"))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncoded(params).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BaiduOCRError.badResponse("HTTP \(statusCode)，非 JSON 响应")
        }

        if let errorCode = json["error_code"] as? Int {
            let message = (json["error_msg"] as? String) ?? "未知错误"
            // token 失效，强制刷新后重试一次
            if (errorCode == 110 || errorCode == 111), allowRetry {
                _ = try await accessToken(forceRefresh: true)
                return try await recognizePrepared(imageData: imageData, imageSize: imageSize, allowRetry: false)
            }
            if errorCode == 4 || errorCode == 6 || errorCode == 17 {
                throw BaiduOCRError.quotaExceeded
            }
            throw BaiduOCRError.apiError(code: errorCode, message: message)
        }

        return try parseWordsResult(json, imageSize: imageSize)
    }

    // MARK: - 结果解析

    private func parseWordsResult(_ json: [String: Any], imageSize: CGSize?) throws -> OCRPageResult {
        guard let wordsResult = json["words_result"] as? [[String: Any]] else {
            throw BaiduOCRError.badResponse("缺少 words_result 字段")
        }

        var lines: [OCRLine] = wordsResult.map { item in
            let words = (item["words"] as? String) ?? ""
            var rect: CGRect? = nil
            if let loc = item["location"] as? [String: Any],
               let left = loc["left"] as? Double, let top = loc["top"] as? Double,
               let width = loc["width"] as? Double, let height = loc["height"] as? Double {
                rect = CGRect(x: left, y: top, width: width, height: height)
            }
            return OCRLine(text: words, location: rect)
        }

        // paragraph=true 时按 paragraphs_result 合并段落
        var text: String
        if mergeParagraph, let paragraphs = json["paragraphs_result"] as? [[String: Any]] {
            var merged: [String] = []
            for p in paragraphs {
                guard let idxs = p["words_result_idx"] as? [Int] else { continue }
                let paragraphText = idxs.compactMap { $0 >= 0 && $0 < lines.count ? lines[$0].text : nil }.joined()
                if !paragraphText.isEmpty { merged.append(paragraphText) }
            }
            text = merged.isEmpty ? "" : merged.joined(separator: "\n\n")
        } else {
            text = lines.map { $0.text }.joined(separator: "\n")
        }
        if text.isEmpty {
            text = lines.map { $0.text }.joined(separator: "\n")
        }
        lines = lines.filter { !$0.text.isEmpty }

        // 含位置版：行级 location → 归一化 OCRBlock（供 Swift Layout Engine 使用）
        var blocks: [OCRBlock] = []
        if let size = imageSize, size.width > 0, size.height > 0 {
            blocks = lines.compactMap { line in
                guard let loc = line.location else { return nil }
                let nb = [
                    Double(loc.minX) / Double(size.width),
                    Double(loc.minY) / Double(size.height),
                    Double(loc.maxX) / Double(size.width),
                    Double(loc.maxY) / Double(size.height)
                ].map { min(max($0, 0), 1) }
                return OCRBlock(category: "text", bbox: nb, content: line.text, page: 0)
            }
        }
        return OCRPageResult(text: text, lines: lines, blocks: blocks)
    }

    // MARK: - 工具

    /// application/x-www-form-urlencoded 编码（base64 中的 +/= 必须转义）
    private func formURLEncoded(_ params: [(String, String)]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+/=&?")
        return params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

// MARK: - 图片压缩（满足百度限制：base64 ≤ 4MB，边长 15~4096px）

enum ImageCompressor {
    /// 将任意图片数据转换为符合百度接口限制的 JPEG。
    static func prepareForBaidu(_ data: Data, maxBase64Bytes: Int = 4 * 1024 * 1024) throws -> Data {
        let maxRawBytes = maxBase64Bytes * 3 / 4  // base64 膨胀约 4/3

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw BaiduOCRError.badResponse("无法解析图片数据")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let maxSide = max(width, height)

        // 长边超过 4096 时按比例缩到 4096 以内；太大时再逐步降尺寸
        var targetSide = min(maxSide, 4096)
        var quality: CGFloat = 0.85

        for _ in 0..<6 {
            if let jpeg = renderJPEG(source: source, maxPixelSide: targetSide, quality: quality) {
                if jpeg.count <= maxRawBytes { return jpeg }
            }
            quality *= 0.8
            if quality < 0.4 {
                quality = 0.7
                targetSide = max(Int(Double(targetSide) * 0.75), 640)
            }
        }
        throw BaiduOCRError.imageTooLarge
    }

    private static func renderJPEG(source: CGImageSource, maxPixelSide: Int, quality: CGFloat) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSide, 15)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// 读取图片像素尺寸（用于把行级 location 归一化为 0-1 bbox）
    static func dimensions(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
}
