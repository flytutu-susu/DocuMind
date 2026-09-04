import Foundation

/// 应用版本信息：运行时从 Bundle 读取（CI 构建时注入与 tag 对应的 build 号）。
/// swift run 开发环境下无 Info.plist，回退为 dev。
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// CI 注入的构建号（= GitHub Actions run_number，对应 tag v{版本}-build.{N} 中的 N）
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    /// 展示用完整版本，例如 "1.4.0 (13)"
    static var display: String {
        short == "dev" ? "dev" : "\(short) (\(build))"
    }
}
