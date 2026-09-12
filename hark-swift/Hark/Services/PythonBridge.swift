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

    /// 定位 hark-asr/（内含 pylibs 与 whisper.cpp）。
    /// 从 DerivedData 启动时 cwd 是 `/`、bundle 也不在仓库内，因此还要读
    /// Xcode 写在 DerivedData/<Project>-<hash>/info.plist 里的 WorkspacePath，最后回落到 HOME 常见位置。
    static func locateProjectRoot() -> URL? {
        for base in searchBases() {
            if isProjectRoot(base) { return base }
            let sibling = base.appendingPathComponent("hark-asr")
            if isProjectRoot(sibling) { return sibling }
        }
        return nil
    }

    private static func searchBases() -> [URL] {
        var bases: [URL] = []

        if let override = ProcessInfo.processInfo.environment["HARK_ROOT"], !override.isEmpty {
            bases.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        bases.append(contentsOf: ancestors(of: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        bases.append(contentsOf: ancestors(of: Bundle.main.bundleURL))
        if let workspace = workspaceSourceDirectory() {
            bases.append(contentsOf: ancestors(of: workspace))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in ["Documents/My Projects/Hark", "Documents/Projects/Hark"] {
            bases.append(home.appendingPathComponent(relative))
        }
        return bases
    }

    private static func ancestors(of url: URL, depth: Int = 6) -> [URL] {
        var result: [URL] = []
        var probe = url.deletingLastPathComponent()
        for _ in 0..<depth {
            if probe.path == "/" { break }
            result.append(probe)
            probe = probe.deletingLastPathComponent()
        }
        return result
    }

    /// 若 bundle 位于 DerivedData 下，据此读回工程文件所在目录。
    private static func workspaceSourceDirectory() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        guard let range = bundleURL.path.range(of: "/DerivedData/") else { return nil }
        let derivedRoot = String(bundleURL.path[..<range.lowerBound]) + "/DerivedData"
        let relative = String(bundleURL.path[(range.upperBound)...]).split(separator: "/").first.map(String.init)
        guard let projectDirName = relative else { return nil }

        let infoPlist = URL(fileURLWithPath: derivedRoot)
            .appendingPathComponent(projectDirName)
            .appendingPathComponent("info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let workspace = plist["WorkspacePath"] as? String else { return nil }
        return URL(fileURLWithPath: workspace).deletingLastPathComponent()
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

    /// 生成 Python 字符串字面量。不能借用 JSON 编码：JSON 会把 `/` 转义成 `\/`，
    /// 而那是 Python 的非法转义序列，路径会被破坏。等价于 Rust 的 `format!("{:?}", s)`。
    static func pythonLiteral(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
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
        // stderr 落盘而非用管道：模型下载的进度条可远超管道缓冲，
        // 先 wait 后排空管道会父子互相阻塞。
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-python-\(UUID().uuidString).stderr")
        try Data().write(to: errURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = stdout
        process.standardError = errHandle

        defer {
            stdout.fileHandleForReading.closeFile()
            errHandle.closeFile()
            try? FileManager.default.removeItem(at: errURL)
        }

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: (try? Data(contentsOf: errURL)) ?? Data(), encoding: .utf8)?
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
