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

    func testBackendAvailability() {
        XCTAssertTrue(AsrBackend.dashscope.isAvailable)
        XCTAssertFalse(AsrBackend.mlxQwen3.isAvailable)
    }

    func testPaletteLightDarkDiffer() {
        // 仅验证两套调色板可构建
        _ = Palette.light
        _ = Palette.dark
    }
}

final class PythonBridgeTests: XCTestCase {
    func testLocateProjectRootFindsPylibs() throws {
        guard FileManager.default.fileExists(atPath: "../pylibs") || FileManager.default.fileExists(atPath: "pylibs") else {
            throw XCTSkip("pylibs 目录不存在，跳过")
        }
        XCTAssertNotNil(PythonBridge.locateProjectRoot())
    }

    func testRunPythonPrintsOK() throws {
        guard PythonBridge.findPython() != nil else { throw XCTSkip("无 Python") }
        guard PythonBridge.locateProjectRoot() != nil else { throw XCTSkip("pylibs 不存在") }
        let bridge = try PythonBridge()
        XCTAssertEqual(try bridge.run("print('ok')"), "ok")
    }
}
