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

        let exitCode = try await Task.detached {
            try Self.run(binary: binary, model: modelPath, audio: fileURL)
        }.value
        if exitCode != 0 {
            throw BackendError.processFailed("whisper-cli 执行失败（退出码 \(exitCode)）")
        }

        guard let text = try? String(contentsOfFile: outputTxt, encoding: .utf8) else {
            throw BackendError.processFailed("读取转写结果失败")
        }
        try? FileManager.default.removeItem(atPath: outputTxt)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(binary: String, model: String, audio: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", model,
            "-f", audio.path,
            "-l", "zh",
            "--no-timestamps",
            "-otxt",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func isInstalled(binaryPath: String, modelPath: String) -> Bool {
        (try? resolveBinary(profilePath: binaryPath)) != nil
            && (try? resolveModel(profilePath: modelPath)) != nil
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
        func add(_ path: String?) {
            guard let path, !path.isEmpty, path != "/", !roots.contains(path) else { return }
            roots.append(path)
        }
        add(PythonBridge.locateProjectRoot()?.path)
        add(FileManager.default.currentDirectoryPath)
        add(ProcessInfo.processInfo.environment["HOME"])
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

/// mlx-qwen3-asr（本地 MLX）：与 Rust 版 mlx_qwen3.rs 一致，模型权重由 HF 镜像自动下载。
struct MlxQwen3Backend: AsrBackendService {
    let kind: AsrBackend = .mlxQwen3
    let bridge: PythonBridge

    static let hfEnv = [
        "HF_ENDPOINT": "https://hf-mirror.com",
        "HF_HUB_DOWNLOAD_TIMEOUT": "300",
    ]

    static let preamble = """
    import os
    os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
    os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
    home = os.path.expanduser("~")
    os.environ.setdefault("HF_HOME", os.path.join(home, ".cache", "huggingface"))
    """

    func transcribe(fileURL: URL, apiKey: String, apiBase: String, model: String,
                    whisperCppPath: String, whisperModelPath: String) async throws -> String {
        guard bridge.isPackageInstalled("mlx_qwen3_asr") else {
            throw BackendError.packageMissing(
                "mlx_qwen3_asr",
                hint: "pip install --target=pylibs mlx-qwen3-asr"
            )
        }
        let script = Self.transcribeScript(audioPath: fileURL.path)
        return try await bridge.runAsync(script, extraEnv: Self.hfEnv)
    }

    static func transcribeScript(audioPath: String) -> String {
        """
        \(preamble)

        import mlx_qwen3_asr
        result = mlx_qwen3_asr.transcribe(\(PythonBridge.pythonLiteral(audioPath)))
        if isinstance(result, dict):
            print(result.get("text", "").strip())
        elif hasattr(result, "text"):
            print(result.text.strip())
        else:
            print(str(result).strip())
        """
    }

    static func warmupScript() -> String {
        """
        \(preamble)

        import mlx_qwen3_asr
        mlx_qwen3_asr.load_model()
        print("ok")
        """
    }
}

/// SenseVoice Small（MLX 版，经 mlx-audio）：行为对齐 Rust 版 sense_voice.rs。
struct SenseVoiceBackend: AsrBackendService {
    let kind: AsrBackend = .sensevoice
    let bridge: PythonBridge

    static let defaultModelPath = "~/models/mlx-community/SenseVoiceSmall"
    static let hfRepoId = "mlx-community/SenseVoiceSmall"
    /// 与 Rust 版一致：AppState 中 AsrConfig.language 固定为 "zh"。
    static let defaultLanguage = "zh"

    func transcribe(fileURL: URL, apiKey: String, apiBase: String, model: String,
                    whisperCppPath: String, whisperModelPath: String) async throws -> String {
        guard bridge.isPackageInstalled("mlx_audio") else {
            throw BackendError.packageMissing(
                "mlx_audio",
                hint: "pip install --target=pylibs \"mlx-audio[stt]\""
            )
        }
        let script = Self.transcribeScript(
            audioPath: fileURL.path,
            model: model,
            language: Self.mapLanguage(Self.defaultLanguage)
        )
        return try await bridge.runAsync(script, extraEnv: MlxQwen3Backend.hfEnv)
    }

    static func transcribeScript(audioPath: String, model: String, language: String) -> String {
        """
        \(MlxQwen3Backend.preamble)

        from mlx_audio.stt import load

        model_path = os.path.expanduser(\(PythonBridge.pythonLiteral(resolveModelPath(model: model))))
        model = load(model_path)
        result = model.generate(\(PythonBridge.pythonLiteral(audioPath)), language=\(PythonBridge.pythonLiteral(language)), use_itn=True)

        text = ""
        if hasattr(result, "text"):
            text = result.text or ""
        elif isinstance(result, dict):
            text = result.get("text", "")
        else:
            text = str(result)

        print(text.strip())
        """
    }

    /// 模型解析：profile 指定（路径或 repo id）→ 本地已下载路径 → HF repo id。
    static func resolveModelPath(model: String) -> String {
        if !model.trimmingCharacters(in: .whitespaces).isEmpty {
            return model
        }
        let expanded = NSHomeDirectory() + defaultModelPath.dropFirst(1)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return defaultModelPath
        }
        return hfRepoId
    }

    /// SenseVoice 只认 auto/zh/en/ja/ko/yue/nospeech，其余原样传递。
    static func mapLanguage(_ lang: String) -> String {
        switch lang.lowercased() {
        case "auto", "": "auto"
        case "zh", "chinese", "cmn": "zh"
        case "en", "english": "en"
        case "ja", "japanese": "ja"
        case "ko", "korean": "ko"
        case "yue", "cantonese", "粤语": "yue"
        case "nospeech", "none": "nospeech"
        default: lang
        }
    }

    static func warmupScript(model: String = "") -> String {
        """
        \(MlxQwen3Backend.preamble)

        from mlx_audio.stt import load

        model_path = os.path.expanduser(\(PythonBridge.pythonLiteral(resolveModelPath(model: model))))
        if not os.path.exists(model_path):
            raise FileNotFoundError(f"模型未找到: {model_path}，请先下载 mlx-community/SenseVoiceSmall")

        load(model_path)
        print("ok")
        """
    }
}

/// OpenAI Whisper API（兼容 Groq / 自建 baseURL）：原生 URLSession，不再走子进程。
struct OpenAiWhisperBackend: AsrBackendService {
    let kind: AsrBackend = .openaiWhisper
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "whisper-1"

    func transcribe(fileURL: URL, apiKey: String, apiBase: String, model: String,
                    whisperCppPath: String, whisperModelPath: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw BackendError.missingAPIKey("缺少 OpenAI API Key")
        }
        let base = apiBase.isEmpty ? Self.defaultBaseURL : apiBase
        let url = Self.transcriptionsURL(base: base)
        let data = try Data(contentsOf: fileURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            apiKey.hasPrefix("Bearer ") ? apiKey : "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        let boundary = "----HarkBoundary\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.body(
            boundary: boundary,
            model: model.isEmpty ? Self.defaultModel : model,
            filename: fileURL.lastPathComponent,
            audio: data
        )

        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.processFailed("无 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: bytes, encoding: .utf8) ?? "无法读取错误响应"
            throw BackendError.processFailed("API 错误 (\(http.statusCode)): \(text)")
        }
        return String(data: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func transcriptionsURL(base: String) -> URL {
        var trimmed = base
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/audio/transcriptions")!
    }

    static func body(boundary: String, model: String, filename: String, audio: Data) -> Data {
        var out = Data()
        func append(_ s: String) { out.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        out.append(audio)
        append("\r\n--\(boundary)--\r\n")
        return out
    }
}

enum BackendError: LocalizedError {
    case missingAPIKey(String)
    case packageMissing(String, hint: String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): msg
        case .packageMissing(let pkg, let hint): "pylibs 中缺少 \(pkg)。请运行：\(hint)"
        case .processFailed(let msg): msg
        }
    }
}

struct AsrBackendStatus: Identifiable, Equatable {
    let backend: AsrBackend
    let installed: Bool
    let hint: String
    var id: AsrBackend { backend }
}

enum AsrStatus {
    /// 对齐 Rust 版 backend_status()：逐个后端探测可用性。
    static func all(bridge: PythonBridge?, profiles: [AsrProfile], activeProfile: AsrProfile?) -> [AsrBackendStatus] {
        let whisperProfile = activeProfile?.backend == .whisperCpp ? activeProfile : nil
        let openAIProfile = profiles.first { $0.backend == .openaiWhisper && !$0.apiKey.isEmpty }
        return [
            AsrBackendStatus(
                backend: .mlxQwen3,
                installed: bridge?.isPackageInstalled("mlx_qwen3_asr") ?? false,
                hint: "在项目根目录运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs mlx-qwen3-asr"
            ),
            AsrBackendStatus(
                backend: .sensevoice,
                installed: bridge?.isPackageInstalled("mlx_audio") ?? false,
                hint: "在项目根目录运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs \"mlx-audio[stt]\""
            ),
            AsrBackendStatus(
                backend: .whisperCpp,
                installed: WhisperCppBackend.isInstalled(
                    binaryPath: whisperProfile?.whisperCppPath ?? "",
                    modelPath: whisperProfile?.whisperModelPath ?? ""
                ),
                hint: """
                git clone https://github.com/ggerganov/whisper.cpp.git
                cd whisper.cpp && make
                curl -L -o models/ggml-small.bin https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
                """
            ),
            AsrBackendStatus(
                backend: .dashscope,
                installed: bridge?.isPackageInstalled("dashscope") ?? false,
                hint: "pip install dashscope"
            ),
            AsrBackendStatus(
                backend: .openaiWhisper,
                installed: openAIProfile != nil,
                hint: "需要 OpenAI API Key（也兼容 Groq / 自定义 baseURL）"
            ),
        ]
    }
}

enum AsrRouter {
    /// 本地 whisper.cpp 与云端 OpenAI 不依赖 Python 桥，pylibs 缺失时仍可用。
    static func backend(for kind: AsrBackend, bridge: PythonBridge?) throws -> AsrBackendService {
        switch kind {
        case .whisperCpp: WhisperCppBackend()
        case .openaiWhisper: OpenAiWhisperBackend()
        case .dashscope: DashScopeBackend(bridge: try requireBridge(bridge))
        case .mlxQwen3: MlxQwen3Backend(bridge: try requireBridge(bridge))
        case .sensevoice: SenseVoiceBackend(bridge: try requireBridge(bridge))
        }
    }

    private static func requireBridge(_ bridge: PythonBridge?) throws -> PythonBridge {
        guard let bridge else {
            throw BackendError.processFailed(PythonBridgeError.pylibsNotFound.localizedDescription)
        }
        return bridge
    }
}
