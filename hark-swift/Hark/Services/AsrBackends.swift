import Foundation

/// ASR 后端协议：M2 起各本地后端逐个原生实现，M1 仅 DashScope（Python 桥）。
protocol AsrBackendService {
    var kind: AsrBackend { get }
    func transcribe(fileURL: URL, apiKey: String, apiBase: String, model: String,
                    whisperCppPath: String, whisperModelPath: String) async throws -> String
}

/// DashScope qwen3-asr：M1 通过 pylibs 的 dashscope SDK 子进程调用，
/// 与 Rust 版 dashscope.rs 行为一致；后续里程碑换成原生 REST。
struct DashScopeBackend: AsrBackendService {
    let kind: AsrBackend = .dashscope
    let bridge: PythonBridge

    func transcribe(fileURL: URL, apiKey: String, apiBase: String, model: String,
                    whisperCppPath: String, whisperModelPath: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw BackendError.missingAPIKey("DashScope 需要 API Key")
        }
        guard bridge.isPackageInstalled("dashscope") else {
            throw BackendError.packageMissing("dashscope", hint: "pip install --target=pylibs dashscope")
        }
        let path = fileURL.path.replacingOccurrences(of: "\"", with: "\\\"")
        let modelName = model.isEmpty ? "qwen3-asr-flash" : model
        let script = """
        import json, dashscope
        dashscope.api_key = "\(apiKey)"
        messages = [{"role": "user", "content": [{"audio": "\(path)"}]}]
        response = dashscope.MultiModalConversation.call(model="\(modelName)", messages=messages)
        if response.status_code != 200:
            raise SystemExit("DashScope 错误: " + json.dumps(response.message, ensure_ascii=False))
        content = response.output.choices[0].message.content
        if isinstance(content, list) and content:
            text = content[0].get("text", "")
        else:
            text = str(content)
        print(text.strip())
        """
        return try await bridge.runAsync(script)
    }
}

/// whisper.cpp：子进程调用 whisper-cli，与 Rust 版 whisper_cpp.rs 行为一致。
/// 查找顺序：profile 指定路径 → PATH（whisper-cli / main）→ 项目内 whisper.cpp/build/bin。
/// 模型查找：profile 指定路径 → whisper.cpp/models/{small,base,medium} → ~/whisper.cpp/models。
struct WhisperCppBackend: AsrBackendService {
    let kind: AsrBackend = .whisperCpp
    static let modelCandidates = ["ggml-small.bin", "ggml-base.bin", "ggml-medium.bin"]

    func transcribe(fileURL: URL, apiKey: String, apiBase: String, model: String,
                    whisperCppPath: String, whisperModelPath: String) async throws -> String {
        let binary = try Self.resolveBinary(profilePath: whisperCppPath)
        let modelPath = try Self.resolveModel(profilePath: whisperModelPath)

        let outputTxt = fileURL.path + ".txt"
        try? FileManager.default.removeItem(atPath: outputTxt)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", modelPath,
            "-f", fileURL.path,
            "-l", "zh",
            "--no-timestamps",
            "-otxt",
        ]
        try process.run()
        try await Task.detached { try process.waitUntilExit() }.value
        if process.terminationStatus != 0 {
            throw BackendError.processFailed("whisper-cli 执行失败（退出码 \(process.terminationStatus)）")
        }

        guard let text = try? String(contentsOfFile: outputTxt, encoding: .utf8) else {
            throw BackendError.processFailed("读取转写结果失败")
        }
        try? FileManager.default.removeItem(atPath: outputTxt)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveBinary(profilePath: String) throws -> String {
        if !profilePath.isEmpty, FileManager.default.fileExists(atPath: profilePath) {
            return profilePath
        }
        for name in ["whisper-cli", "main"] {
            if let path = which(name) { return path }
        }
        for root in candidateRoots() {
            let candidate = root + "/whisper.cpp/build/bin/whisper-cli"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        throw BackendError.processFailed(
            "找不到 whisper-cli。请在设置中指定路径，或把 whisper-cli 加入 PATH"
        )
    }

    static func resolveModel(profilePath: String) throws -> String {
        if !profilePath.isEmpty, FileManager.default.fileExists(atPath: profilePath) {
            return profilePath
        }
        for root in candidateRoots() {
            for name in modelCandidates {
                let candidate = root + "/whisper.cpp/models/" + name
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
            }
        }
        throw BackendError.processFailed("找不到 Whisper 模型。请在设置中指定模型路径")
    }

    private static func candidateRoots() -> [String] {
        var roots: [String] = []
        if let cwd = FileManager.default.currentDirectoryPath as String?,
           !cwd.isEmpty, cwd != "/" {
            roots.append(cwd)
        }
        if let exe = Bundle.main.executableURL?.path {
            let dir = (exe as NSString).deletingLastPathComponent
            var url = URL(fileURLWithPath: dir)
            // DerivedData 内的 exe（…/Contents/MacOS）上溯多层到项目根找 whisper.cpp
            for _ in 0..<10 {
                url.deleteLastPathComponent()
                let p = url.path
                if p == "/" { break }
                if FileManager.default.fileExists(atPath: p + "/whisper.cpp") {
                    roots.append(p)
                    break
                }
            }
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            roots.append(home)
        }
        return roots
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}

enum BackendError: LocalizedError {
    case missingAPIKey(String)
    case packageMissing(String, hint: String)
    case unsupportedBackend(AsrBackend)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): msg
        case .packageMissing(let pkg, let hint): "pylibs 中缺少 \(pkg)。请运行：\(hint)"
        case .unsupportedBackend(let kind): "\(kind.displayName) 将在后续里程碑接入"
        case .processFailed(let msg): msg
        }
    }
}

enum AsrRouter {
    static func backend(for kind: AsrBackend, bridge: PythonBridge) throws -> AsrBackendService {
        switch kind {
        case .dashscope: DashScopeBackend(bridge: bridge)
        case .whisperCpp: WhisperCppBackend()
        case let other: throw BackendError.unsupportedBackend(other)
        }
    }
}
