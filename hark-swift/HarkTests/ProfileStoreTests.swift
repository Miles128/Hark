import XCTest
import GRDB
@testable import Hark

/// M5：asr_profiles 落 SQLite 后，入库/出库语义要和 Rust `profiles.rs` 对齐。
final class ProfileStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarkProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> ProfileStore {
        try ProfileStore(url: dir.appendingPathComponent("profiles.db"))
    }

    private func rawRow(_ id: String) throws -> Row {
        let db = try DatabaseQueue(path: dir.appendingPathComponent("profiles.db").path)
        return try db.read {
            try Row.fetchOne($0, sql: "SELECT * FROM asr_profiles WHERE id = ?", arguments: [id])!
        }
    }

    func testFreshDatabaseCreatesTable() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testAddMintsLowercaseUUIDWhenIDBlank() throws {
        let store = try makeStore()
        let added = try store.add(AsrProfile(name: "新档案", backend: .dashscope))
        XCTAssertEqual(added.id.count, 36)
        XCTAssertEqual(added.id, added.id.lowercased())
        XCTAssertTrue(added.id.contains { $0 == "-" })
    }

    func testBlankFieldsStoredAsNULL() throws {
        let store = try makeStore()
        let added = try store.add(AsrProfile(
            name: "云端",
            backend: .openaiWhisper,
            apiKey: "sk-x",
            apiBase: "   ",
            installHint: ""
        ))
        let row = try rawRow(added.id)
        let storedKey: String? = row["api_key"]
        XCTAssertEqual(storedKey, "sk-x")
        let blankApiBase: String? = row["api_base"]
        XCTAssertNil(blankApiBase)
        let blankHint: String? = row["install_hint"]
        XCTAssertNil(blankHint)
        // 出库时 NULL 再变回空串，界面绑定不需要处理可选值。
        XCTAssertEqual(try store.list().first?.apiBase, "")
    }

    func testNameIsTrimmedAndBackendStoredRaw() throws {
        let store = try makeStore()
        let added = try store.add(AsrProfile(name: "  两边有空格  ", backend: .sensevoice))
        let row = try rawRow(added.id)
        let name: String = row["name"]
        XCTAssertEqual(name, "两边有空格")
        XCTAssertEqual(try store.list().first?.name, "两边有空格")
        let backend: String = row["backend"]
        XCTAssertEqual(backend, "SenseVoice")
    }

    func testUpdateLeavesCreatedAtAndOrderAlone() throws {
        let store = try makeStore()
        let first = try store.add(AsrProfile(name: "第一个", backend: .dashscope))
        let second = try store.add(AsrProfile(name: "第二个", backend: .mlxQwen3))
        let createdAt: Int? = try rawRow(first.id)["created_at"]

        var edited = first
        edited.name = "改过名"
        edited.backend = .whisperCpp
        edited.apiKey = ""
        try store.update(edited)

        let updatedRow = try rawRow(first.id)
        let sameCreatedAt: Int? = updatedRow["created_at"]
        XCTAssertNotNil(sameCreatedAt)
        XCTAssertEqual(sameCreatedAt, createdAt)
        XCTAssertEqual(try store.list().map(\.id), [first.id, second.id])
        XCTAssertEqual(try store.list().first?.name, "改过名")
        XCTAssertEqual(try store.list().first?.backend, .whisperCpp)
    }

    /// Rust 的 rusqlite 连接是 journal_mode=delete；共用一个库时不能把它变成 WAL。
    func testJournalModeStaysDeleteWithoutSidecars() throws {
        let store = try makeStore()
        _ = try store.add(AsrProfile(name: "日志模式", backend: .dashscope))
        let dbURL = dir.appendingPathComponent("profiles.db")
        let db = try DatabaseQueue(path: dbURL.path)
        let mode: String? = try db.read { db in
            guard let row = try Row.fetchOne(db, sql: "PRAGMA journal_mode") else { return nil }
            return row["journal_mode"]
        }
        XCTAssertEqual(mode, "delete")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path + "-shm"))
    }

    func testUnknownBackendStringFallsBackToDashScope() throws {
        let store = try makeStore()
        let added = try store.add(AsrProfile(name: "占位", backend: .mlxQwen3))
        let db = try DatabaseQueue(path: dir.appendingPathComponent("profiles.db").path)
        try db.write {
            try $0.execute(sql: "UPDATE asr_profiles SET backend = 'FutureThing' WHERE id = ?", arguments: [added.id])
        }
        XCTAssertEqual(try store.list().first?.backend, .dashscope)
    }

    func testDeleteRemovesRow() throws {
        let store = try makeStore()
        let added = try store.add(AsrProfile(name: "待删", backend: .dashscope))
        try store.delete(id: added.id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testUnavailableMessageMatchesRust() {
        XCTAssertEqual(ProfileStoreError.unavailable.localizedDescription, "数据库未初始化")
    }

    func testLegacyJSONImportsOnlyIntoEmptyTable() throws {
        let store = try makeStore()
        let legacy = dir.appendingPathComponent("profiles.json")
        let profiles = [
            AsrProfile(name: "旧档案", backend: .dashscope, apiKey: "sk-old"),
            AsrProfile(name: "旧档案二", backend: .sensevoice),
        ]
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: legacy)

        store.importLegacyJSONIfNeeded(from: legacy)
        XCTAssertEqual(try store.list().map(\.name), ["旧档案", "旧档案二"])

        // 已有数据时不再导入，避免重复。
        store.importLegacyJSONIfNeeded(from: legacy)
        XCTAssertEqual(try store.list().count, 2)
    }

    func testDatabaseSharesPathWithTauriAppDataDir() {
        // Rust 的 app_data_dir 是 ~/Library/Application Support/<identifier>。
        let expected = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.sihai.harkasr/profiles.db")
        XCTAssertEqual(HarkPaths.profilesDB, expected)
    }
}
