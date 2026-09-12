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

enum BackendError: LocalizedError {
    case missingAPIKey(String)
    case packageMissing(String, hint: String)
    case unsupportedBackend(AsrBackend)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let msg): msg
        case .packageMissing(let pkg, let hint): "pylibs 中缺少 \(pkg)。请运行：\(hint)"
        case .unsupportedBackend(let kind): "\(kind.displayName) 将在后续里程碑接入"
        }
    }
}

enum AsrRouter {
    static func backend(for kind: AsrBackend, bridge: PythonBridge) throws -> AsrBackendService {
        switch kind {
        case .dashscope: DashScopeBackend(bridge: bridge)
        case let other: throw BackendError.unsupportedBackend(other)
        }
    }
}
