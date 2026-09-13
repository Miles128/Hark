import Foundation
import AVFoundation
import CryptoKit

/// 对齐 Rust 版 tts/mod.rs：Edge（edge-tts）/ CosyVoice（dashscope）双子进程桥 + 合成缓存。

struct TtsVoice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let locale: String
    let gender: String
}

enum TtsBackendKind: String, Codable, CaseIterable, Identifiable {
    case edge = "Edge"
    case cosyVoice = "CosyVoice"

    var id: String { rawValue }
    var title: String { self == .edge ? "Edge TTS" : "阿里云 CosyVoice" }
}

struct TtsConfig: Codable {
    var backend: TtsBackendKind
    var apiKey: String
    var voice: String
    /// Edge rate，如 `+0%` / `-20%` / `+50%`
    var rate: String
}

struct TtsBackendStatus: Identifiable, Equatable {
    let backend: String
    let installed: Bool
    let hint: String
    var id: String { backend }
}

enum TtsError: LocalizedError {
    case emptyText
    case tooLong
    case notInstalled(String)
    case missingAPIKey
    case noOutputFile

    var errorDescription: String? {
        switch self {
        case .emptyText: "请输入要朗读的文字"
        case .tooLong: "文本过长（最多 5000 字），请拆分后再试"
        case .notInstalled(let hint): "后端未安装。安装方式：\(hint)"
        case .missingAPIKey: "阿里云 CosyVoice 需要 DashScope API Key，请在设置中配置 DashScope 模型"
        case .noOutputFile: "合成完成但未找到输出文件"
        }
    }
}

struct SynthesizeResult: Equatable {
    let path: String
    let cached: Bool
}

enum TtsService {
    static var outputDir: URL { HarkPaths.ensure(HarkPaths.tts) }

    static func backendStatus(bridge: PythonBridge) -> [TtsBackendStatus] {
        [
            TtsBackendStatus(backend: "Edge", installed: bridge.isPackageInstalled("edge_tts"), hint: "pip install --target=pylibs edge-tts"),
            TtsBackendStatus(backend: "CosyVoice", installed: bridge.isPackageInstalled("dashscope"), hint: "pip install --target=pylibs dashscope"),
        ]
    }

    static func listVoices(_ backend: TtsBackendKind, bridge: PythonBridge) async throws -> [TtsVoice] {
        switch backend {
        case .cosyVoice: return cosyVoiceList
        case .edge:
            guard bridge.isPackageInstalled("edge_tts") else {
                throw TtsError.notInstalled("pip install --target=pylibs edge-tts")
            }
            let script = """
            import asyncio, json, edge_tts

            async def main():
                voices = await edge_tts.list_voices()
                out = []
                for v in voices:
                    out.append({
                        "id": v.get("ShortName", ""),
                        "name": v.get("FriendlyName") or v.get("ShortName", ""),
                        "locale": v.get("Locale", ""),
                        "gender": v.get("Gender", ""),
                    })
                print(json.dumps(out, ensure_ascii=False))

            asyncio.run(main())
            """
            let stdout = try await bridge.runAsync(script)
            guard let data = stdout.data(using: .utf8),
                  let voices = try? JSONDecoder().decode([TtsVoice].self, from: data) else {
                throw TtsError.noOutputFile
            }
            return voices.filter { !$0.id.isEmpty }
        }
    }

    static func synthesize(_ rawText: String, config: TtsConfig, bridge: PythonBridge) async throws -> SynthesizeResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw TtsError.emptyText }
        if text.count > 5000 { throw TtsError.tooLong }

        let cacheKey = self.cacheKey(text: text, config: config)
        let outURL = outputDir.appendingPathComponent("tts_\(cacheKey).mp3")
        if FileManager.default.fileExists(atPath: outURL.path) {
            return SynthesizeResult(path: outURL.path, cached: true)
        }

        switch config.backend {
        case .edge:
            guard bridge.isPackageInstalled("edge_tts") else {
                throw TtsError.notInstalled("pip install --target=pylibs edge-tts")
            }
            let script = """
            import asyncio, edge_tts

            text = \(pythonStr(text))
            voice = \(pythonStr(config.voice))
            rate = \(pythonStr(config.rate))
            output_path = \(pythonStr(outURL.path))

            async def main():
                communicate = edge_tts.Communicate(text, voice, rate=rate)
                await communicate.save(output_path)
                print(output_path)

            asyncio.run(main())
            """
            _ = try await bridge.runAsync(script)
        case .cosyVoice:
            guard bridge.isPackageInstalled("dashscope") else {
                throw TtsError.notInstalled("pip install --target=pylibs dashscope")
            }
            guard !config.apiKey.isEmpty else { throw TtsError.missingAPIKey }
            let rate = edgeRateToFloat(config.rate)
            let script = """
            import dashscope
            from dashscope.audio.tts_v2 import SpeechSynthesizer

            dashscope.api_key = \(pythonStr(config.apiKey))
            text = \(pythonStr(text))
            voice = \(pythonStr(config.voice))
            output_path = \(pythonStr(outURL.path))
            speech_rate = \(rate)

            synthesizer = SpeechSynthesizer(model="cosyvoice-v1", voice=voice, speech_rate=speech_rate)
            audio = synthesizer.call(text)
            if audio is None:
                raise RuntimeError("CosyVoice 返回空音频，请检查 API Key / 音色 / 额度")

            data = audio if isinstance(audio, (bytes, bytearray)) else bytes(audio)
            with open(output_path, "wb") as f:
                f.write(data)
            print(output_path)
            """
            _ = try await bridge.runAsync(script)
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw TtsError.noOutputFile
        }
        return SynthesizeResult(path: outURL.path, cached: false)
    }

    /// CosyVoice 常用音色（v1 / v2 常用 id）。
    static let cosyVoiceList: [TtsVoice] = [
        TtsVoice(id: "longxiaochun", name: "龙小淳（女声·知性）", locale: "zh-CN", gender: "Female"),
        TtsVoice(id: "longxiaoxia", name: "龙小夏（女声·温柔）", locale: "zh-CN", gender: "Female"),
        TtsVoice(id: "longxiaocheng", name: "龙小诚（男声·沉稳）", locale: "zh-CN", gender: "Male"),
        TtsVoice(id: "longxiaobai", name: "龙小白（女声·活泼）", locale: "zh-CN", gender: "Female"),
        TtsVoice(id: "longyuan", name: "龙媛（女声·温暖）", locale: "zh-CN", gender: "Female"),
        TtsVoice(id: "longhua", name: "龙华（女声·甜美女声）", locale: "zh-CN", gender: "Female"),
        TtsVoice(id: "longshu", name: "龙书（男声·磁性）", locale: "zh-CN", gender: "Male"),
        TtsVoice(id: "loongstella", name: "Stella（女声·英文）", locale: "en-US", gender: "Female"),
        TtsVoice(id: "loongbella", name: "Bella（女声·英文）", locale: "en-US", gender: "Female"),
    ]

    /// Python 字符串字面量，与 ASR 侧共用同一套转义规则。
    static func pythonStr(_ s: String) -> String {
        PythonBridge.pythonLiteral(s)
    }

    /// 将 Edge 风格 `+0%` / `-20%` 转为 CosyVoice 的 0.5–2.0 倍速。
    static func edgeRateToFloat(_ rate: String) -> Double {
        let s = rate.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "%"))
        guard let pct = Double(s) else { return 1.0 }
        return min(max(1.0 + pct / 100.0, 0.5), 2.0)
    }

    private static func cacheKey(text: String, config: TtsConfig) -> String {
        let material = "\(text)|\(config.backend.rawValue)|\(config.voice)|\(config.rate)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
