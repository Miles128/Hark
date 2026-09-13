import XCTest
@testable import Hark

/// M5 验收：与 Rust 侧（`lib.rs` / `profiles.rs` / `url_audio.rs`）和 Vue 侧文案的一致性。
final class RustParityTests: XCTestCase {

    // MARK: - settings.json

    /// Rust 用 `serde_json::to_string_pretty`：两空格缩进、`"key": value`、按声明顺序写键。
    /// `JSONEncoder` 不保证键序（缩进也在冒号前多一个空格），而这些都不影响 JSON 语义，
    /// 因此这里校验的是键集与取值，不是字节序。
    func testEncodedSettingsMatchRustShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        func object(_ settings: AppSettings) throws -> [String: Any] {
            let data = try encoder.encode(settings)
            let json = try JSONSerialization.jsonObject(with: data)
            return try XCTUnwrap(json as? [String: Any])
        }

        let defaults = try object(AppSettings())
        XCTAssertEqual(Set(defaults.keys), ["theme", "autoSaveInterval", "autoSaveFormat", "activeProfileId"])
        XCTAssertEqual(defaults["theme"] as? String, "system")
        XCTAssertEqual(defaults["autoSaveInterval"] as? UInt64, 60)
        XCTAssertEqual(defaults["autoSaveFormat"] as? String, "txt")
        XCTAssertTrue(defaults["activeProfileId"] is NSNull, "空档案要写成 null，和 Option<String> 一致")

        var filled = AppSettings()
        filled.theme = .dark
        filled.autoSaveInterval = 0
        filled.autoSaveFormat = "md"
        filled.activeProfileId = "c0ffee-0"
        let written = try object(filled)
        XCTAssertEqual(written["theme"] as? String, "dark")
        XCTAssertEqual(written["autoSaveInterval"] as? UInt64, 0)
        XCTAssertEqual(written["autoSaveFormat"] as? String, "md")
        XCTAssertEqual(written["activeProfileId"] as? String, "c0ffee-0")
    }

    func testDecodesSettingsWrittenByRust() throws {
        let rust = """
        {
          "theme": "dark",
          "autoSaveInterval": 300,
          "autoSaveFormat": "md",
          "activeProfileId": "1f0b-uuid"
        }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(rust.utf8))
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(settings.autoSaveInterval, 300)
        XCTAssertEqual(settings.autoSaveFormat, "md")
        XCTAssertEqual(settings.activeProfileId, "1f0b-uuid")
    }

    /// `#[serde(default)]`：缺键回落默认值，activeProfileId 显式 null 回落空串。
    func testMissingKeysFallBackToDefaults() throws {
        let partial = #"{"theme":"light","activeProfileId":null}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: partial)
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.autoSaveInterval, 60)
        XCTAssertEqual(settings.autoSaveFormat, "txt")
        XCTAssertEqual(settings.activeProfileId, "")
    }

    // MARK: - 自动保存文本

    func testAutoSaveMarkdownKeepsRawText() {
        let segments = [
            Segment(index: 0, text: "你好", backend: "MlxQwen3"),
            Segment(index: 1, text: "  带空白的段落  ", backend: "MlxQwen3"),
        ]
        XCTAssertEqual(
            AutoSaveText.render(segments, format: "md"),
            "# Hark 自动保存\n\n## 段落 1\n\n你好\n\n## 段落 2\n\n  带空白的段落  \n\n"
        )
    }

    func testAutoSaveTxtTrimsAndSeparates() {
        let segments = [
            Segment(index: 0, text: " 第一段 \n", backend: "DashScope"),
            Segment(index: 1, text: "第二段", backend: "DashScope"),
        ]
        XCTAssertEqual(AutoSaveText.render(segments, format: "txt"), "第一段\n\n第二段")
    }

    @MainActor
    func testAutoSaveLoopWritesNothingForEmptyTranscript() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarkAutoSaveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let loop = AutoSaveLoop(dir: dir)
        XCTAssertNil(loop.save(segments: [], format: "txt"))

        let written = try XCTUnwrap(loop.save(segments: [Segment(index: 0, text: "内容", backend: "MlxQwen3")], format: "txt"))
        XCTAssertEqual(written.lastPathComponent, "hark-auto-save.txt")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "内容")

        // 内容未变化时不再重复写（Rust 用哈希去重）。
        XCTAssertNil(loop.save(segments: [Segment(index: 0, text: "内容", backend: "MlxQwen3")], format: "txt"))
    }

    // MARK: - yt-dlp 调用参数

    func testPylibsInvocationMatchesRustArguments() throws {
        let pylibs = URL(fileURLWithPath: "/tmp/pylibs")
        let cmd = try UrlAudioDownloader.invocation(
            runner: .pylibsModule(python: "/opt/homebrew/bin/python3.12", pylibs: pylibs),
            outputTemplate: "/Music/hark-asr/downloads/download_%(id)s.%(ext)s",
            url: "https://example.com/v"
        )
        XCTAssertEqual(cmd.executable, "/opt/homebrew/bin/python3.12")
        XCTAssertEqual(cmd.arguments.first, "-s")
        XCTAssertEqual(Array(cmd.arguments[0..<3]), ["-s", "-m", "yt_dlp"])
        XCTAssertEqual(cmd.environment?["PYTHONPATH"], pylibs.path)
        XCTAssertEqual(cmd.environment?["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(Array(cmd.arguments.suffix(2)), [
            "/Music/hark-asr/downloads/download_%(id)s.%(ext)s",
            "https://example.com/v",
        ])
    }

    func testSystemBinaryInvocationKeepsAudioFlagsInOrder() throws {
        let cmd = try UrlAudioDownloader.invocation(
            runner: .systemBinary(path: "/opt/homebrew/bin/yt-dlp"),
            outputTemplate: "/tmp/out.%(ext)s",
            url: "https://b23.tv/x"
        )
        XCTAssertNil(cmd.environment)
        XCTAssertEqual(cmd.arguments, [
            "-x",
            "--audio-format", "wav",
            "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
            "--print", "after_move:filepath",
            "-o", "/tmp/out.%(ext)s",
            "https://b23.tv/x",
        ])
    }

    // MARK: - 目录

    func testAudioDirectoriesMatchTauriAudioDir() {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hark-asr", isDirectory: true)
        XCTAssertEqual(HarkPaths.recordings, music)
        XCTAssertEqual(HarkPaths.tts, music.appendingPathComponent("tts", isDirectory: true))
        XCTAssertEqual(HarkPaths.downloads, music.appendingPathComponent("downloads", isDirectory: true))
        XCTAssertEqual(HarkPaths.autoSave, music.appendingPathComponent("auto-save", isDirectory: true))
    }

    // MARK: - 后端文案（BackendSelector.vue / SettingsModal.vue）

    func testSidebarLabelsMatchBackendMeta() {
        XCTAssertEqual(AsrBackend.mlxQwen3.sidebarLabel, "mlx-qwen3-asr")
        XCTAssertEqual(AsrBackend.sensevoice.sidebarLabel, "SenseVoice (MLX)")
        XCTAssertEqual(AsrBackend.whisperCpp.sidebarLabel, "whisper.cpp")
        XCTAssertEqual(AsrBackend.dashscope.sidebarLabel, "DashScope")
        XCTAssertEqual(AsrBackend.openaiWhisper.sidebarLabel, "OpenAI Whisper")
    }

    func testSettingsLabelsAndOrderMatchBackendTypes() {
        XCTAssertEqual(AsrBackend.settingsOrder.map(\.settingsLabel), [
            "mlx-qwen3-asr（本地）",
            "SenseVoice（本地）",
            "whisper.cpp（本地）",
            "DashScope（联网）",
            "OpenAI Whisper（联网）",
        ])
        XCTAssertEqual(AsrBackend.settingsOrder.map(\.rawValue), [
            "MlxQwen3", "SenseVoice", "WhisperCpp", "DashScope", "OpenAiWhisper",
        ])
        XCTAssertEqual(AsrBackend.settingsOrder.filter(\.isOnline).map(\.rawValue), [
            "DashScope", "OpenAiWhisper",
        ])
    }

    // MARK: - 虚拟声卡名匹配（audio.rs 的 BLACKHOLE_NAMES）

    func testLoopbackDeviceNamesMatchRustBlackholeNames() {
        XCTAssertEqual(CoreAudioDevices.loopbackNames, ["blackhole", "soundflower", "loopback"])
        for name in ["BlackHole 2ch", "Soundflower (2ch)", "Loopback Audio"] {
            XCTAssertTrue(CoreAudioDevices.isLoopbackDevice(name), name)
        }
        XCTAssertFalse(CoreAudioDevices.isLoopbackDevice("MacBook Pro麦克风"))
    }
}
