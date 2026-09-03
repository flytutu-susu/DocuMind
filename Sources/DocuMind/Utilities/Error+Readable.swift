import Foundation

extension Error {
    /// 优先使用 LocalizedError 的中文描述，兜底系统描述。
    var readableMessage: String {
        if let localized = self as? LocalizedError, let desc = localized.errorDescription {
            return desc
        }
        return localizedDescription
    }
}
