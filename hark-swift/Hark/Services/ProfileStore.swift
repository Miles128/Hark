import Foundation
import GRDB

/// 打开 profiles.db 失败时的兜底，文案与 Rust 的 `ok_or("数据库未初始化")` 一致。
enum ProfileStoreError: LocalizedError {
    case unavailable
    var errorDescription: String? { "数据库未初始化" }
}

/// 与 Rust `profiles.rs` 一一对应的 SQLite 记录。
///
/// 列名是 snake_case，靠 `CodingKeys` 映射；`created_at` 只写不读（Rust 的 SELECT
/// 故意不取它），因此不出现在 `AsrProfile` 里。
struct AsrProfileRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "asr_profiles"

    var id: String
    var name: String
    var backend: String
    var apiKey: String?
    var apiBase: String?
    var modelName: String?
    var whisperCppPath: String?
    var whisperModelPath: String?
    var installHint: String?
    var createdAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, backend
        case apiKey = "api_key"
        case apiBase = "api_base"
        case modelName = "model_name"
        case whisperCppPath = "whisper_cpp_path"
        case whisperModelPath = "whisper_model_path"
        case installHint = "install_hint"
        case createdAt = "created_at"
    }

    init(_ profile: AsrProfile, createdAt: Int? = nil) {
        self.id = profile.id
        // name 走 NOT NULL 列，只 trim 不做空值转换；backend Rust 侧原样存，不 trim。
        self.name = profile.name.trimmedForStore
        self.backend = profile.backend.rawValue
        self.apiKey = profile.apiKey.nullIfBlankForStore
        self.apiBase = profile.apiBase.nullIfBlankForStore
        self.modelName = profile.modelName.nullIfBlankForStore
        self.whisperCppPath = profile.whisperCppPath.nullIfBlankForStore
        self.whisperModelPath = profile.whisperModelPath.nullIfBlankForStore
        self.installHint = profile.installHint.nullIfBlankForStore
        self.createdAt = createdAt
    }

    var profile: AsrProfile {
        var result = AsrProfile()
        result.id = id
        result.name = name
        result.backend = AsrBackend(rawValue: backend) ?? .dashscope
        result.apiKey = apiKey ?? ""
        result.apiBase = apiBase ?? ""
        result.modelName = modelName ?? ""
        result.whisperCppPath = whisperCppPath ?? ""
        result.whisperModelPath = whisperModelPath ?? ""
        result.installHint = installHint ?? ""
        return result
    }
}

extension String {
    /// 等价于 Rust 的 `s.trim()`：入库前统一去首尾空白。
    var trimmedForStore: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 等价于 Rust 的 `sanitized()` + `none_if_empty()`：空白串存成 NULL。
    var nullIfBlankForStore: String? {
        let trimmed = trimmedForStore
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// asr_profiles 的唯一入口。SQL 逐条照抄 `profiles.rs`，避免两侧行为漂移。
final class ProfileStore: @unchecked Sendable {
    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS asr_profiles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            backend TEXT NOT NULL,
            api_key TEXT,
            api_base TEXT,
            model_name TEXT,
            whisper_cpp_path TEXT,
            whisper_model_path TEXT,
            install_hint TEXT,
            created_at INTEGER
        )
        """

    /// SELECT 不取 created_at：它只用于排序，不跨 IPC。UPDATE 同理不写它，
    /// 所以编辑档案不会改变列表顺序。
    static let selectSQL = """
        SELECT id, name, backend, api_key, api_base, model_name, whisper_cpp_path, whisper_model_path, install_hint
        FROM asr_profiles
        ORDER BY created_at ASC
        """

    static let deleteSQL = "DELETE FROM asr_profiles WHERE id = ?"

    private let db: DatabaseQueue

    init(url: URL) throws {
        HarkPaths.ensure(url.deletingLastPathComponent())
        db = try DatabaseQueue(path: url.path)
        try db.write { try $0.execute(sql: Self.schemaSQL) }
    }

    static func open() -> ProfileStore? {
        try? ProfileStore(url: HarkPaths.profilesDB)
    }

    func list() throws -> [AsrProfile] {
        try db.read { try AsrProfileRow.fetchAll($0, sql: Self.selectSQL).map(\.profile) }
    }

    /// 返回入库后的档案（含补出来的 id），与 Rust `add_profile` 的返回值一致。
    @discardableResult
    func add(_ profile: AsrProfile) throws -> AsrProfile {
        var row = AsrProfileRow(profile)
        if row.id.isEmpty {
            // Rust 用 uuid v4 小写；Swift 的 uuidString 是大写，需显式统一。
            row.id = UUID().uuidString.lowercased()
        }
        row.createdAt = Int(Date().timeIntervalSince1970)
        try db.write { try row.insert($0) }
        return row.profile
    }

    func update(_ profile: AsrProfile) throws {
        let row = AsrProfileRow(profile)
        // 只更新 8 列：created_at 不在其中，编辑档案不会改变列表顺序。
        try db.write { db in
            _ = try AsrProfileRow.filter(Column("id") == row.id).updateAll(db, [
                Column("name").set(to: row.name),
                Column("backend").set(to: row.backend),
                Column("api_key").set(to: row.apiKey),
                Column("api_base").set(to: row.apiBase),
                Column("model_name").set(to: row.modelName),
                Column("whisper_cpp_path").set(to: row.whisperCppPath),
                Column("whisper_model_path").set(to: row.whisperModelPath),
                Column("install_hint").set(to: row.installHint),
            ])
        }
    }

    func delete(id: String) throws {
        try db.write { try $0.execute(sql: Self.deleteSQL, arguments: [id]) }
    }

    /// 一次性把 M1–M4 时期写下的 profiles.json 迁进数据库（表为空且旧文件存在时）。
    /// 旧文件保留不动，由用户自行处置。
    func importLegacyJSONIfNeeded(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let legacy = try? JSONDecoder().decode([AsrProfile].self, from: data),
              !legacy.isEmpty,
              let count = try? list().count, count == 0 else { return }
        for profile in legacy {
            _ = try? add(profile)
        }
    }
}
