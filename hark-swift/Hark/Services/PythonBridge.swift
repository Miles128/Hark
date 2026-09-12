import Foundation

enum PythonBridgeError: LocalizedError {
    case pythonNotFound
    case pylibsNotFound
    case executionFailed(exitCode: Int32, stdout: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            "未找到系统 Python 3。请安装 homebrew python3.12：brew install python@3.12"
        case .pylibsNotFound:
            "未找到项目 pylibs 目录。请在 hark-asr/ 下运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs dashscope"
        case .executionFailed(let exitCode, let stdout, let stderr):
            "Python 执行失败（exit=\(exitCode)）:\n--- stdout ---\n\(stdout)\n--- stderr ---\n\(stderr)"
        }
    }
}

/// 与 Rust 版 pylibs.rs 对齐的 Python 子进程桥：
/// homebrew python3.12 优先，PYTHONPATH 注入 hark-asr/pylibs，禁用用户级 site-packages。
struct PythonBridge {
    let projectRoot: URL

    static let pythonCandidates = [
        "/opt/homebrew/bin/python3.12",
        "/usr/local/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/usr/local/bin/python3.11",
    ]

    /// 从 cwd 与可执行文件位置向上找包含 pylibs/ 的目录（即 hark-asr/）。
    static func locateProjectRoot() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HARK_ROOT"] {
            let url = URL(fileURLWithPath: override)
            if isProjectRoot(url) { return url }
        }
        var probe = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0...6 {
            if isProjectRoot(probe) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent()
        probe = bundleDir
        for _ in 0...4 {
            if isProjectRoot(probe) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    static func isProjectRoot(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("pylibs").path, isDirectory: &isDir) && isDir.boolValue
    }

    static func findPython() -> String? {
        for candidate in pythonCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let pathPython = which("python3") { return pathPython }
        return nil
    }

    static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    init(projectRoot: URL? = nil) throws {
        guard let root = projectRoot ?? Self.locateProjectRoot() else {
            throw PythonBridgeError.pylibsNotFound
        }
        self.projectRoot = root
    }

    var pylibsDir: URL { projectRoot.appendingPathComponent("pylibs") }

    func isPackageInstalled(_ packageDir: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: pylibsDir.appendingPathComponent(packageDir).path, isDirectory: &isDir) && isDir.boolValue
    }

    func run(_ script: String, extraEnv: [String: String] = [:]) throws -> String {
        guard let python = Self.findPython() else { throw PythonBridgeError.pythonNotFound }
        guard FileManager.default.fileExists(atPath: pylibsDir.path) else { throw PythonBridgeError.pylibsNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-s", "-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pylibsDir.path
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        for (k, v) in extraEnv { env[k] = v }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw PythonBridgeError.executionFailed(exitCode: process.terminationStatus, stdout: out, stderr: err)
        }
        return out
    }

    func runAsync(_ script: String, extraEnv: [String: String] = [:]) async throws -> String {
        let bridge = self
        return try await Task.detached(priority: .userInitiated) {
            try bridge.run(script, extraEnv: extraEnv)
        }.value
    }
}
