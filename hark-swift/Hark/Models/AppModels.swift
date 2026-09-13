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

    /// 侧边栏短标签，对应 BackendSelector.vue 的 backendMeta[...].label。
    var sidebarLabel: String {
        switch self {
        case .dashscope: "DashScope"
        case .whisperCpp: "whisper.cpp"
        case .mlxQwen3: "mlx-qwen3-asr"
        case .sensevoice: "SenseVoice (MLX)"
        case .openaiWhisper: "OpenAI Whisper"
        }
    }

    /// 设置面板标签，对应 SettingsModal.vue 的 backendTypes。
    var settingsLabel: String {
        switch self {
        case .dashscope: "DashScope（联网）"
        case .whisperCpp: "whisper.cpp（本地）"
        case .mlxQwen3: "mlx-qwen3-asr（本地）"
        case .sensevoice: "SenseVoice（本地）"
        case .openaiWhisper: "OpenAI Whisper（联网）"
        }
    }

    /// backendTypes 的下拉顺序（MlxQwen3 在首位，也是新建档案的默认值）。
    static let settingsOrder: [AsrBackend] = [.mlxQwen3, .sensevoice, .whisperCpp, .dashscope, .openaiWhisper]

    /// 对应 isOnlineBackend()：联网后端需要 API Key / Base URL。
    var isOnline: Bool { self == .dashscope || self == .openaiWhisper }

    /// backendMeta 的内联 SVG 在 SwiftUI 侧用近似字形替代。
    var systemImage: String {
        switch self {
        case .mlxQwen3: "square.stack.3d.up"
        case .sensevoice: "waveform.path"
        case .whisperCpp: "mic"
        case .dashscope: "clock"
        case .openaiWhisper: "sparkles"
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

    var warmupReadyMessage: String {
        switch self {
        case .sensevoice: "SenseVoice 模型就绪"
        default: "模型就绪"
        }
    }
}

struct AsrProfile: Codable, Identifiable, Equatable {
    var id: String = ""
    var name: String = ""
    var backend: AsrBackend = .dashscope
    var apiKey: String = ""
    var apiBase: String = ""
    var modelName: String = ""
    var whisperCppPath: String = ""
    var whisperModelPath: String = ""
    var installHint: String = ""
}

/// 对齐 Rust `AppSettings`：`#[serde(rename_all = "camelCase", default)]`。
/// Rust 侧 `activeProfileId` 是 `Option<String>`，可能是 null；缺键走默认值。
struct AppSettings: Codable, Equatable {
    var theme: ThemeMode = .system
    /// 单位是秒，0 表示关闭自动保存（与 Rust 的 Duration::from_secs 一致）。
    var autoSaveInterval: UInt64 = 60
    var autoSaveFormat: String = "txt"
    var activeProfileId: String = ""

    enum CodingKeys: String, CodingKey {
        case theme, autoSaveInterval, autoSaveFormat, activeProfileId
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(ThemeMode.self, forKey: .theme) ?? .system
        autoSaveInterval = try container.decodeIfPresent(UInt64.self, forKey: .autoSaveInterval) ?? 60
        autoSaveFormat = try container.decodeIfPresent(String.self, forKey: .autoSaveFormat) ?? "txt"
        activeProfileId = try container.decodeIfPresent(String.self, forKey: .activeProfileId) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme.rawValue, forKey: .theme)
        try container.encode(autoSaveInterval, forKey: .autoSaveInterval)
        try container.encode(autoSaveFormat, forKey: .autoSaveFormat)
        try container.encode(activeProfileId.isEmpty ? nil : activeProfileId, forKey: .activeProfileId)
    }
}
