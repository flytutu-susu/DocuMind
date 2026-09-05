import Foundation

/// 文档库：documents / document_versions / ocr_results / tasks 四张表的 CRUD。
/// 线程安全（内部 Database 串行队列），可被局域网后台线程与主线程同时访问。
final class DocumentStore {
    private let db: Database
    let rootDir: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocuMind/library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.rootDir = base
        do {
            self.db = try Database(path: base.appendingPathComponent("documind.db").path)
        } catch {
            // 磁盘故障兜底：内存库，应用仍可运行（数据不持久化）
            NSLog("[DocuMind] 数据库打开失败，降级为内存库: \(error.localizedDescription)")
            // swiftlint:disable:next force_try
            self.db = try! Database(path: ":memory:")
        }
        try? migrate()
    }

    /// String? → 绑定安全值（nil 映射为 NSNull，避免 Optional 包进 Any 的坑）
    private func nullable(_ s: String?) -> Any { s ?? NSNull() }

    // MARK: - 迁移

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS documents(
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS document_versions(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES documents(id),
            version_no INTEGER NOT NULL,
            file_path TEXT NOT NULL,
            file_size INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS ocr_results(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES documents(id),
            engine TEXT NOT NULL,
            mode TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL,
            blocks_json TEXT NOT NULL DEFAULT '',
            page_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        );
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS tasks(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            document_id TEXT REFERENCES documents(id),
            file_name TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',
            progress REAL NOT NULL DEFAULT 0,
            message TEXT NOT NULL DEFAULT '',
            error TEXT,
            engine TEXT NOT NULL DEFAULT '',
            output_path TEXT,
            output_name TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_versions_doc ON document_versions(document_id);")
        try db.exec("CREATE INDEX IF NOT EXISTS idx_results_doc ON ocr_results(document_id);")
    }

    // MARK: - 文档

    /// 入库：复制源文件到 library/docs/<id>/v1-文件名，创建 documents + document_versions 记录
    @discardableResult
    func createDocument(name: String, kind: DocumentKind, sourceFile: URL) throws -> DocumentRecord {
        let id = UUID()
        let record = DocumentRecord(id: id, name: name, kind: kind, createdAt: Date())
        try db.run("INSERT INTO documents(id, name, kind, created_at) VALUES(?,?,?,?)",
                   [id.uuidString, name, kind.rawValue, record.createdAt.timeIntervalSince1970])
        try addVersion(documentID: id, sourceFile: sourceFile)
        return record
    }

    @discardableResult
    func addVersion(documentID: UUID, sourceFile: URL) throws -> DocumentVersionRecord {
        let nextNo = ((try db.fetch(
            "SELECT MAX(version_no) AS max_no FROM document_versions WHERE document_id=?",
            [documentID.uuidString]).first?.int("max_no")) ?? 0) + 1

        let docDir = rootDir.appendingPathComponent("docs/\(documentID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        let destName = "v\(nextNo)-\(sourceFile.lastPathComponent)"
        let destURL = docDir.appendingPathComponent(destName)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceFile, to: destURL)

        let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let record = DocumentVersionRecord(id: UUID(), documentID: documentID, versionNo: nextNo,
                                           filePath: destURL.path, fileSize: size, createdAt: Date())
        try db.run("""
            INSERT INTO document_versions(id, document_id, version_no, file_path, file_size, created_at)
            VALUES(?,?,?,?,?,?)
            """, [record.id.uuidString, documentID.uuidString, nextNo, destURL.path, size,
                  record.createdAt.timeIntervalSince1970])
        return record
    }

    func listDocuments() throws -> [DocumentRecord] {
        try db.fetch("SELECT * FROM documents ORDER BY created_at DESC").compactMap(document(from:))
    }

    func document(id: UUID) throws -> DocumentRecord? {
        try db.fetch("SELECT * FROM documents WHERE id=?", [id.uuidString]).first.flatMap(document(from:))
    }

    func versions(of documentID: UUID) throws -> [DocumentVersionRecord] {
        try db.fetch("SELECT * FROM document_versions WHERE document_id=? ORDER BY version_no DESC",
                     [documentID.uuidString]).compactMap(version(from:))
    }

    func latestVersionURL(of documentID: UUID) throws -> URL? {
        try db.fetch("""
            SELECT file_path FROM document_versions
            WHERE document_id=? ORDER BY version_no DESC LIMIT 1
            """, [documentID.uuidString]).first?.string("file_path").map(URL.init(fileURLWithPath:))
    }

    // MARK: - 删除

    /// 级联删除文档：识别结果 → 任务（含转换产物文件）→ 版本 → 文档，最后清理磁盘目录
    func deleteDocument(id: UUID) throws {
        // 先收集磁盘产物路径（转换产物在任务行上）
        let taskRows = try db.fetch("SELECT output_path FROM tasks WHERE document_id=?", [id.uuidString])
        let outputPaths = taskRows.compactMap { $0.string("output_path") }

        try db.run("DELETE FROM ocr_results WHERE document_id=?", [id.uuidString])
        try db.run("DELETE FROM tasks WHERE document_id=?", [id.uuidString])
        try db.run("DELETE FROM document_versions WHERE document_id=?", [id.uuidString])
        try db.run("DELETE FROM documents WHERE id=?", [id.uuidString])

        // 磁盘清理：文档目录 + 转换产物
        try? FileManager.default.removeItem(
            at: rootDir.appendingPathComponent("docs/\(id.uuidString)", isDirectory: true))
        for path in outputPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - OCR 结果

    func saveOCRResult(documentID: UUID, engine: String, mode: String, text: String,
                       blocks: [OCRBlock], pageCount: Int) throws {
        let blocksJSON = (try? JSONEncoder().encode(blocks)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try db.run("""
            INSERT INTO ocr_results(id, document_id, engine, mode, text, blocks_json, page_count, created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [UUID().uuidString, documentID.uuidString, engine, mode, text, blocksJSON, pageCount,
                  Date().timeIntervalSince1970])
    }

    func latestOCRResult(of documentID: UUID) throws -> OCRResultRecord? {
        try db.fetch("""
            SELECT * FROM ocr_results WHERE document_id=? ORDER BY created_at DESC LIMIT 1
            """, [documentID.uuidString]).first.flatMap(result(from:))
    }

    // MARK: - 任务

    @discardableResult
    func createTask(kind: TaskKind, documentID: UUID?, fileName: String) throws -> TaskRecord {
        let now = Date()
        let task = TaskRecord(id: UUID(), kind: kind, documentID: documentID, fileName: fileName,
                              state: .pending, progress: 0, message: "排队中", error: nil,
                              engine: "", outputPath: nil, outputName: nil,
                              createdAt: now, updatedAt: now)
        try db.run("""
            INSERT INTO tasks(id, kind, document_id, file_name, state, progress, message,
                              error, engine, output_path, output_name, created_at, updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [task.id.uuidString, kind.rawValue, nullable(documentID?.uuidString), fileName,
                  TaskState.pending.rawValue, 0.0, "排队中", NSNull(), "",
                  NSNull(), NSNull(), now.timeIntervalSince1970, now.timeIntervalSince1970])
        return task
    }

    func updateTask(_ id: UUID,
                    state: TaskState? = nil,
                    progress: Double? = nil,
                    message: String? = nil,
                    error: String?? = nil,
                    engine: String? = nil,
                    outputPath: String?? = nil,
                    outputName: String?? = nil) throws {
        var sets: [String] = ["updated_at=?"]
        var params: [Any?] = [Date().timeIntervalSince1970]
        if let state { sets.append("state=?"); params.append(state.rawValue) }
        if let progress { sets.append("progress=?"); params.append(progress) }
        if let message { sets.append("message=?"); params.append(message) }
        if let error { sets.append("error=?"); params.append(nullable(error)) }
        if let engine { sets.append("engine=?"); params.append(engine) }
        if let outputPath { sets.append("output_path=?"); params.append(nullable(outputPath)) }
        if let outputName { sets.append("output_name=?"); params.append(nullable(outputName)) }
        params.append(id.uuidString)
        try db.run("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id=?", params)
    }

    func task(_ id: UUID) throws -> TaskRecord? {
        try db.fetch("SELECT * FROM tasks WHERE id=?", [id.uuidString]).first.flatMap(task(from:))
    }

    func listTasks(limit: Int = 200) throws -> [TaskRecord] {
        try db.fetch("SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?", [limit])
            .compactMap(task(from:))
    }

    // MARK: - 行映射

    private func document(from row: [String: Any]) -> DocumentRecord? {
        guard let id = row.uuid("id"), let name = row.string("name") else { return nil }
        return DocumentRecord(id: id, name: name,
                              kind: DocumentKind(rawValue: row.string("kind") ?? "") ?? .unknown,
                              createdAt: row.date("created_at"))
    }

    private func version(from row: [String: Any]) -> DocumentVersionRecord? {
        guard let id = row.uuid("id"), let docID = row.uuid("document_id"),
              let path = row.string("file_path") else { return nil }
        return DocumentVersionRecord(id: id, documentID: docID, versionNo: row.int("version_no"),
                                     filePath: path, fileSize: row.int64("file_size"),
                                     createdAt: row.date("created_at"))
    }

    private func result(from row: [String: Any]) -> OCRResultRecord? {
        guard let id = row.uuid("id"), let docID = row.uuid("document_id"),
              let text = row.string("text") else { return nil }
        return OCRResultRecord(id: id, documentID: docID,
                               engine: row.string("engine") ?? "",
                               mode: row.string("mode") ?? "",
                               text: text,
                               blocksJSON: row.string("blocks_json") ?? "",
                               pageCount: row.int("page_count"),
                               createdAt: row.date("created_at"))
    }

    private func task(from row: [String: Any]) -> TaskRecord? {
        guard let id = row.uuid("id"),
              let kind = TaskKind(rawValue: row.string("kind") ?? ""),
              let fileName = row.string("file_name") else { return nil }
        return TaskRecord(id: id, kind: kind, documentID: row.uuid("document_id"),
                          fileName: fileName,
                          state: TaskState(rawValue: row.string("state") ?? "") ?? .failed,
                          progress: row.double("progress"),
                          message: row.string("message") ?? "",
                          error: row.string("error"),
                          engine: row.string("engine") ?? "",
                          outputPath: row.string("output_path"),
                          outputName: row.string("output_name"),
                          createdAt: row.date("created_at"),
                          updatedAt: row.date("updated_at"))
    }
}
