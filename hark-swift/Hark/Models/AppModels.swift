import Foundation

/// 对齐 Vue 版类型：Segment / AsrProfile / AppSettings / AsrConfig。

struct Segment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var index: Int
    var text: String
    var backend: String
    var createdAt: Date = Date()
}

enum AsrBackend: String, Codable, CaseIterable, Identifiable {
    case dashscope = "DashScope"
    case whisperCpp = "WhisperCpp"
    case mlxQwen3 = "MlxQwen3"
    case sensevoice = "SenseVoice"
    case openaiWhisper = "OpenAiWhisper"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashscope: "DashScope（云端）"
        case .whisperCpp: "whisper.cpp（本地）"
        case .mlxQwen3: "MLX Qwen3-ASR（本地）"
        case .sensevoice: "SenseVoice（本地）"
        case .openaiWhisper: "OpenAI Whisper API（云端）"
        }
    }

    /// 该后端是否需要预热（首次加载/下载模型）。
    var needsWarmup: Bool { self == .mlxQwen3 || self == .sensevoice }

    var warmupMessage: String {
        switch self {
        case .mlxQwen3: "正在准备 mlx-qwen3-asr 模型（首次使用需下载）…"
        case .sensevoice: "正在加载 SenseVoice 模型…"
        default: "正在预热模型…"
        }
    }

    var themeColorHex: UInt32 {
        switch self {
        case .dashscope: 0xFF6B00
        case .whisperCpp: 0x5856D6
        case .mlxQwen3: 0xAF52DE
        case .sensevoice: 0x30D158
        case .openaiWhisper: 0x10A37F
        }
    }
}

struct AsrProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var backend: AsrBackend = .dashscope
    var apiKey: String = ""
    var apiBase: String = ""
    var whisperCppPath: String = ""
    var whisperModelPath: String = ""
    var modelName: String = ""
}

/// 对齐 SettingsModal.vue 的 AppSettings。
struct AppSettings: Codable, Equatable {
    var theme: ThemeMode = .system
    var autoSaveInterval: Int = 60
    var autoSaveFormat: String = "txt"
    var activeProfileId: String = ""
}
