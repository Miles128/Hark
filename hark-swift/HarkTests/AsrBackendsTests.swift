import XCTest
@testable import Hark

/// 对齐 Rust 版 asr/{sense_voice,openai_whisper,mlx_qwen3,mod}.rs 的单元测试。
final class AsrBackendsTests: XCTestCase {

    // MARK: - SenseVoice 语言映射

    func testSenseVoiceMapLanguageKnownCodes() {
        XCTAssertEqual(SenseVoiceBackend.mapLanguage("zh"), "zh")
        XCTAssertEqual(SenseVoiceBackend.mapLanguage("EN"), "en")
        XCTAssertEqual(SenseVoiceBackend.mapLanguage("japanese"), "ja")
        XCTAssertEqual(SenseVoiceBackend.mapLanguage("粤语"), "yue")
        XCTAssertEqual(SenseVoiceBackend.mapLanguage(""), "auto")
    }

    func testSenseVoiceMapLanguageUnknownPassthrough() {
        XCTAssertEqual(SenseVoiceBackend.mapLanguage("fr"), "fr")
    }

    func testSenseVoiceResolveModelPathPrefersCustom() {
        XCTAssertEqual(SenseVoiceBackend.resolveModelPath(model: "/custom/path"), "/custom/path")
    }

    func testSenseVoiceResolveModelPathFallsBackToLocalOrRepo() {
        let path = SenseVoiceBackend.resolveModelPath(model: "  ")
        XCTAssertTrue([SenseVoiceBackend.defaultModelPath, SenseVoiceBackend.hfRepoId].contains(path))
    }

    func testSenseVoiceScriptsUseMlxAudioAndMirror() {
        let script = SenseVoiceBackend.warmupScript(model: "")
        XCTAssertTrue(script.contains("from mlx_audio.stt import load"))
        XCTAssertTrue(script.contains("hf-mirror.com"))
    }

    // MARK: - MLX qwen3-asr

    func testMlxQwen3WarmupScriptLoadsModel() {
        let script = MlxQwen3Backend.warmupScript()
        XCTAssertTrue(script.contains("import mlx_qwen3_asr"))
        XCTAssertTrue(script.contains("load_model()"))
    }

    // MARK: - 生成脚本的缩进

    /// Swift 多行字符串插值会保留被插值内容自身的缩进，Python 侧就是 IndentationError。
    func testGeneratedScriptsKeepTopLevelStatementsFlushLeft() {
        let scripts = [
            MlxQwen3Backend.transcribeScript(audioPath: "/tmp/a.wav"),
            MlxQwen3Backend.warmupScript(),
            SenseVoiceBackend.transcribeScript(audioPath: "/tmp/a.wav", model: "", language: "zh"),
            SenseVoiceBackend.warmupScript(model: ""),
        ]
        for script in scripts {
            XCTAssertTrue(script.hasPrefix("import os"), script)
            XCTAssertFalse(script.contains("\n    import"), script)
            XCTAssertFalse(script.contains("\t"), script)
        }
        XCTAssertTrue(scripts[2].contains("\nfrom mlx_audio.stt import load"))
    }

    // MARK: - OpenAI Whisper

    func testTranscriptionsURLStripsTrailingSlashes() {
        XCTAssertEqual(
            OpenAiWhisperBackend.transcriptionsURL(base: "https://api.openai.com/v1///").absoluteString,
            "https://api.openai.com/v1/audio/transcriptions"
        )
    }

    func testTranscriptionsURLAppendsPathToCustomBase() {
        XCTAssertEqual(
            OpenAiWhisperBackend.transcriptionsURL(base: "https://api.groq.com/openai/v1").absoluteString,
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
    }

    func testMultipartBodyCarriesModelAndAudio() {
        let body = OpenAiWhisperBackend.body(
            boundary: "BND",
            model: "whisper-1",
            filename: "audio.wav",
            audio: Data([0x00, 0xF8])
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\ntext"))
        XCTAssertTrue(text.contains("filename=\"audio.wav\""))
        XCTAssertTrue(text.hasSuffix("\r\n--BND--\r\n"))
    }

    // MARK: - 后端探测 / 路由
    func testAsrStatusReportsAllFiveBackends() {
        let status = AsrStatus.all(bridge: nil, profiles: [], activeProfile: nil)
        XCTAssertEqual(status.count, 5)
        XCTAssertEqual(Set(status.map(\.backend)), Set(AsrBackend.allCases))
        let pythonBackends: [AsrBackend] = [.mlxQwen3, .sensevoice, .dashscope]
        for backend in pythonBackends {
            XCTAssertFalse(
                status.first { $0.backend == backend }?.installed ?? false,
                "\(backend) 缺少 PythonBridge 时不应报告可用"
            )
        }
    }

    func testAsrStatusMarksOpenAiInstalledWhenProfileHasApiKey() {
        let profile = AsrProfile(name: "openai", backend: .openaiWhisper, apiKey: "sk-test")
        let status = AsrStatus.all(bridge: nil, profiles: [profile], activeProfile: profile)
        XCTAssertTrue(status.first { $0.backend == .openaiWhisper }?.installed ?? false)
    }

    func testRouterRejectsPythonBackendsWithoutBridge() {
        XCTAssertThrowsError(try AsrRouter.backend(for: .mlxQwen3, bridge: nil))
        XCTAssertThrowsError(try AsrRouter.backend(for: .sensevoice, bridge: nil))
        XCTAssertThrowsError(try AsrRouter.backend(for: .dashscope, bridge: nil))
    }

    func testRouterServesLocalAndCloudBackendsWithoutBridge() {
        XCTAssertNotNil(try? AsrRouter.backend(for: .whisperCpp, bridge: nil))
        XCTAssertNotNil(try? AsrRouter.backend(for: .openaiWhisper, bridge: nil))
    }

    /// 真实跑一次 Swift → PythonBridge → mlx-audio 链路（缺依赖或本地模型时跳过，避免触发下载）。
    @MainActor
    func testSenseVoiceTranscribesSpeechThroughPythonBridge() async throws {
        guard PythonBridge.findPython() != nil, PythonBridge.locateProjectRoot() != nil else {
            throw XCTSkip("无 Python / pylibs")
        }
        let bridge = try PythonBridge()
        guard bridge.isPackageInstalled("mlx_audio") else { throw XCTSkip("mlx_audio 未安装") }
        let modelDir = (SenseVoiceBackend.defaultModelPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: modelDir) else { throw XCTSkip("SenseVoice 模型未下载") }

        let speech = try makeSpeechWav()
        defer { try? FileManager.default.removeItem(at: speech) }

        let text = try await SenseVoiceBackend(bridge: bridge).transcribe(
            fileURL: speech, apiKey: "", apiBase: "",
            model: "", whisperCppPath: "", whisperModelPath: ""
        )
        XCTAssertFalse(text.isEmpty, "有语音输入时应得到非空转写结果")
    }

    /// whisper.cpp 走的是纯子进程链路，不依赖 Python。
    func testWhisperCppTranscribesSpeech() async throws {
        guard WhisperCppBackend.isInstalled(binaryPath: "", modelPath: "") else {
            throw XCTSkip("本机缺少 whisper-cli 或 ggml 模型")
        }
        let speech = try makeSpeechWav()
        defer { try? FileManager.default.removeItem(at: speech) }

        let text = try await WhisperCppBackend().transcribe(
            fileURL: speech, apiKey: "", apiBase: "",
            model: "", whisperCppPath: "", whisperModelPath: ""
        )
        XCTAssertFalse(text.isEmpty, "有语音输入时应得到非空转写结果")
    }

    /// 用系统 TTS 合成一段中文语音。say 的默认容器是 AIFF，
    /// mlx-audio 的 miniaudio 读不了，因此显式指定 16-bit PCM WAV。
    private func makeSpeechWav() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hark-asr-tests")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("speech-\(UUID().uuidString).wav")

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@22050", "今天天气不错"]
        say.standardError = FileHandle.nullDevice
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say 合成语音失败")
        return url
    }

    func testPythonLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(PythonBridge.pythonLiteral("/tmp/a b.wav"), "\"/tmp/a b.wav\"")
        XCTAssertEqual(PythonBridge.pythonLiteral("a\"b"), "\"a\\\"b\"")
    }
}
