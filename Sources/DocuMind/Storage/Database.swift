import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "数据库打开失败：\(m)"
        case .execFailed(let m): return "SQL 执行失败：\(m)"
        case .prepareFailed(let m): return "SQL 编译失败：\(m)"
        case .stepFailed(let m): return "SQL 步进失败：\(m)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 基于系统 libsqlite3 的极简封装（串行队列保证线程安全，零第三方依赖）。
final class Database {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.documind.db")

    init(path: String) throws {
        if path != ":memory:" {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &handle) == SQLITE_OK else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.openFailed(msg)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: - 执行

    func exec(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let msg = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw DatabaseError.execFailed(msg + " | " + sql)
            }
        }
    }

    func run(_ sql: String, _ params: [Any?] = []) throws {
        try queue.sync {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, params)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DatabaseError.stepFailed(lastErrorMessage() + " | " + sql)
            }
        }
    }

    func fetch(_ sql: String, _ params: [Any?] = []) throws -> [[String: Any]] {
        try queue.sync {
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, params)
            var rows: [[String: Any]] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else {
                    throw DatabaseError.stepFailed(lastErrorMessage() + " | " + sql)
                }
                rows.append(rowDict(stmt))
            }
            return rows
        }
    }

    // MARK: - 内部

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepareFailed(lastErrorMessage() + " | " + sql)
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [Any?]) {
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            switch param {
            case nil, is NSNull:
                sqlite3_bind_null(stmt, i)
            case let value as String:
                sqlite3_bind_text(stmt, i, value, -1, SQLITE_TRANSIENT)
            case let value as Int:
                sqlite3_bind_int64(stmt, i, Int64(value))
            case let value as Int64:
                sqlite3_bind_int64(stmt, i, value)
            case let value as Double:
                sqlite3_bind_double(stmt, i, value)
            case let value as Bool:
                sqlite3_bind_int64(stmt, i, value ? 1 : 0)
            default:
                sqlite3_bind_text(stmt, i, String(describing: param!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    private func rowDict(_ stmt: OpaquePointer) -> [String: Any] {
        var row: [String: Any] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_TEXT:
                row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            case SQLITE_INTEGER:
                row[name] = sqlite3_column_int64(stmt, i)
            case SQLITE_FLOAT:
                row[name] = sqlite3_column_double(stmt, i)
            case SQLITE_NULL:
                row[name] = NSNull()
            default:
                row[name] = NSNull()
            }
        }
        return row
    }

    private func lastErrorMessage() -> String {
        handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }
}
