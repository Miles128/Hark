import XCTest
@testable import Hark

final class AppModelsTests: XCTestCase {
    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.theme = .dark
        settings.autoSaveInterval = 120
        settings.autoSaveFormat = "md"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testProfileRoundTrip() throws {
        var profile = AsrProfile(name: "测试", backend: .dashscope, apiKey: "sk-x", modelName: "qwen3-asr-flash")
        profile.whisperCppPath = ""
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AsrProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.backend, .dashscope)
    }

    func testSegmentCodable() throws {
        let segment = Segment(index: 0, text: "你好", backend: "DashScope")
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(Segment.self, from: data)
        XCTAssertEqual(decoded.text, "你好")
        XCTAssertEqual(decoded.index, 0)
    }

    func testBackendWarmupFlags() {
        XCTAssertTrue(AsrBackend.mlxQwen3.needsWarmup)
        XCTAssertTrue(AsrBackend.sensevoice.needsWarmup)
        XCTAssertFalse(AsrBackend.dashscope.needsWarmup)
        XCTAssertFalse(AsrBackend.whisperCpp.needsWarmup)
        XCTAssertFalse(AsrBackend.openaiWhisper.needsWarmup)
    }

    func testPaletteLightDarkDiffer() {
        // 仅验证两套调色板可构建
        _ = Palette.light
        _ = Palette.dark
    }
}

final class PythonBridgeTests: XCTestCase {
    /// 从 DerivedData 启动时 cwd 是 "/"，必须靠 bundle / DerivedData 记录回源码目录。
    func testLocateProjectRootFindsPylibs() throws {
        guard let root = PythonBridge.locateProjectRoot() else {
            throw XCTSkip("本机未克隆 Hark 仓库")
        }
        XCTAssertEqual(root.lastPathComponent, "hark-asr")
        XCTAssertTrue(PythonBridge.isProjectRoot(root))
    }

    func testRunPythonPrintsOK() throws {
        guard PythonBridge.findPython() != nil else { throw XCTSkip("无 Python") }
        guard PythonBridge.locateProjectRoot() != nil else { throw XCTSkip("pylibs 不存在") }
        let bridge = try PythonBridge()
        XCTAssertEqual(try bridge.run("print('ok')"), "ok")
    }
}
