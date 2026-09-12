import Foundation
import AVFoundation

enum AppMode: String, CaseIterable { case asr, tts }
enum AsrTab: String, CaseIterable { case recording, video }

struct WarmupEvent: Equatable {
    let status: String
    let message: String
}

enum AudioSource: String, CaseIterable, Identifiable {
    case microphone, system, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: "麦克风"
        case .system: "系统"
        case .both: "双通道"
        }
    }
    var recorderKind: AudioSourceKind {
        switch self {
        case .microphone: .microphone
        case .system: .system
        case .both: .both
        }
    }
}

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    // MARK: - 界面状态
    var mode: AppMode = .asr
    var tab: AsrTab = .recording
    var sidebarCollapsed = false
    var settingsOpen = false

    // MARK: - 数据状态
    var settings: AppSettings = AppSettings() {
        didSet { persist(settings, to: Self.settingsURL) }
    }
    var profiles: [AsrProfile] = [] {
        didSet {
            persist(profiles, to: Self.profilesURL)
            refreshAsrStatus()
        }
    }
    var selectedProfileId: String = "" {
        didSet { refreshAsrStatus() }
    }
    var segments: [Segment] = []
    var isTranscribing = false
    var errorMessage: String?
    var statusMessage: String?

    // MARK: - 后端状态 / 模型预热
    var backendStatus: [AsrBackendStatus] = []
    var warmup: WarmupEvent?

    // MARK: - 录音状态
    let recorder = AudioRecorder()
    var devices: [AudioDeviceInfo] = []
    var micDeviceName = ""
    var systemDeviceName = ""
    var source: AudioSource = .microphone
    var liveTranscribe = false
    var recordedFileURL: URL?
    var hasBlackhole = false

    var isRecording: Bool { recorder.isRecording }
    var volumeDb: Float { recorder.db }
    var volumeLevel: Double { recorder.level }

    var activeProfile: AsrProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    func refreshAsrStatus() {
        let bridge = try? PythonBridge()
        backendStatus = AsrStatus.all(bridge: bridge, profiles: profiles, activeProfile: activeProfile)
    }

    /// 预热本地模型（MLX qwen3-asr / SenseVoice），首次会触发权重下载。
    func warmupModel() async {
        guard let profile = activeProfile, profile.backend.needsWarmup else { return }
        warmup = WarmupEvent(status: "downloading", message: profile.backend.warmupMessage)
        do {
            let bridge = try PythonBridge()
            let script: String
            switch profile.backend {
            case .mlxQwen3:
                script = MlxQwen3Backend.warmupScript()
            case .sensevoice:
                script = SenseVoiceBackend.warmupScript(model: profile.modelName)
            default:
                return
            }
            _ = try await bridge.runAsync(script, extraEnv: MlxQwen3Backend.hfEnv)
            warmup = WarmupEvent(status: "ready", message: "模型就绪")
        } catch {
            warmup = WarmupEvent(status: "error", message: error.localizedDescription)
        }
    }

    func loadDevices() {
        devices = CoreAudioDevices.inputDevices()
        hasBlackhole = CoreAudioDevices.hasBlackhole()
        if micDeviceName.isEmpty {
            let builtin = devices.first {
                $0.name.localizedCaseInsensitiveContains("macbook") || $0.name.localizedCaseInsensitiveContains("built-in")
            } ?? devices.first {
                $0.name.localizedCaseInsensitiveContains("microphone") || $0.name.contains("麦克风")
            }
            micDeviceName = builtin?.name ?? devices.first?.name ?? ""
        }
        if systemDeviceName.isEmpty {
            systemDeviceName = devices.first { $0.name.contains("BlackHole") }?.name ?? ""
        }
    }

    func toggleRecording() async {
        if isRecording {
            stopAndTranscribe()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        errorMessage = nil
        statusMessage = nil
        segments = []
        recordedFileURL = nil

        let mic = devices.first { $0.name == micDeviceName }
        let system = devices.first { $0.name == systemDeviceName }
        do {
            try recorder.startRecording(
                source: source.recorderKind,
                micDevice: mic,
                systemDevice: system
            )
            statusMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 停止录音；边录边转关掉时立即转写整段。
    private func stopAndTranscribe() {
        guard let url = recorder.stopRecording() else { return }
        recordedFileURL = url
        if !liveTranscribe {
            Task { await transcribeFile(at: url) }
        }
    }

    // MARK: - 持久化

    private static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hark", isDirectory: true)

    private static var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    private static var profilesURL: URL { dir.appendingPathComponent("profiles.json") }
    private static var segmentsURL: URL { dir.appendingPathComponent("segments.json") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        settings = Self.load(Self.settingsURL) ?? AppSettings()
        profiles = Self.load(Self.profilesURL) ?? Self.defaultProfiles()
        selectedProfileId = settings.activeProfileId
        if profiles.first(where: { $0.id == selectedProfileId }) == nil {
            selectedProfileId = profiles.first?.id ?? ""
        }
        segments = Self.load(Self.segmentsURL) ?? []
        refreshAsrStatus()
    }

    private static func defaultProfiles() -> [AsrProfile] {
        [AsrProfile(name: "DashScope 默认", backend: .dashscope, modelName: "qwen3-asr-flash")]
    }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - TTS 状态
    var ttsBackend: TtsBackendKind = .edge
    var ttsVoiceId = "zh-CN-XiaoxiaoNeural"
    var ratePercent = 0
    var voiceQuery = ""
    var localeFilter = "all"
    var ttsVoices: [TtsVoice] = []
    var ttsStatus: [TtsBackendStatus] = []
    var isSynthesizing = false
    var lastTtsPath: String?
    var ttsError: String?
    var ttsText = ""
    private var audioPlayer: AVAudioPlayer?

    var rateStr: String { ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%" }

    var dashscopeApiKey: String {
        if let p = activeProfile, p.backend == .dashscope, !p.apiKey.isEmpty {
            return p.apiKey
        }
        return profiles.first { $0.backend == .dashscope && !$0.apiKey.isEmpty }?.apiKey ?? ""
    }

    var locales: [String] {
        Array(Set(ttsVoices.map(\.locale).filter { !$0.isEmpty })).sorted()
    }

    var filteredTtsVoices: [TtsVoice] {
        let q = voiceQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return ttsVoices.filter { v in
            if localeFilter != "all" && v.locale != localeFilter { return false }
            if q.isEmpty { return true }
            return v.id.lowercased().contains(q)
                || v.name.lowercased().contains(q)
                || v.locale.lowercased().contains(q)
                || v.gender.lowercased().contains(q)
        }
    }

    func refreshTtsStatus() {
        guard let bridge = try? PythonBridge() else {
            ttsStatus = []
            return
        }
        ttsStatus = TtsService.backendStatus(bridge: bridge)
    }

    func loadTtsVoices() async {
        ttsError = nil
        guard let bridge = try? PythonBridge() else {
            ttsVoices = []
            ttsError = PythonBridgeError.pylibsNotFound.localizedDescription
            return
        }
        do {
            ttsVoices = try await TtsService.listVoices(ttsBackend, bridge: bridge)
            if !ttsVoices.contains(where: { $0.id == ttsVoiceId }) {
                let zh = ttsVoices.first { $0.locale.hasPrefix("zh") }
                ttsVoiceId = zh?.id ?? ttsVoices.first?.id ?? ttsVoiceId
            }
        } catch {
            ttsVoices = []
            ttsError = error.localizedDescription
        }
    }

    /// 合成当前文本（markdown → 朗读文本），返回文件路径。
    func synthesizeText(_ rawText: String) async throws -> String {
        let speech = MarkdownPlain.toSpeech(rawText)
        if speech.isEmpty {
            throw TtsError.emptyText
        }
        if ttsBackend == .cosyVoice && dashscopeApiKey.isEmpty {
            throw TtsError.missingAPIKey
        }
        let config = TtsConfig(
            backend: ttsBackend,
            apiKey: ttsBackend == .cosyVoice ? dashscopeApiKey : "",
            voice: ttsVoiceId,
            rate: rateStr
        )
        let bridge = try PythonBridge()
        let result = try await TtsService.synthesize(speech, config: config, bridge: bridge)
        lastTtsPath = result.path
        return result.path
    }

    func synthesizeAndPlay(_ rawText: String) async {
        guard !rawText.trimmingCharacters(in: .whitespaces).isEmpty else {
            ttsError = "请先粘贴或输入文字"
            return
        }
        isSynthesizing = true
        ttsError = nil
        defer { isSynthesizing = false }
        do {
            let path = try await synthesizeText(rawText)
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            self.audioPlayer = player
            player.play()
        } catch {
            ttsError = error.localizedDescription
        }
    }

    // MARK: - 档案管理（对齐 add/update/delete_asr_profile）

    func addProfile(_ profile: AsrProfile) {
        profiles.append(profile)
        selectedProfileId = profile.id
        settings.activeProfileId = profile.id
    }

    func updateProfile(_ profile: AsrProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    func deleteProfile(_ id: String) {
        profiles.removeAll { $0.id == id }
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id ?? ""
            settings.activeProfileId = selectedProfileId
        }
    }

    // MARK: - 转写

    func transcribeFile(at url: URL) async {
        guard let profile = activeProfile else {
            errorMessage = "请先在设置中选择语音识别档案"
            return
        }
        errorMessage = nil
        statusMessage = nil
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let backend = try AsrRouter.backend(
                for: profile.backend,
                bridge: try? PythonBridge()
            )
            let text = try await backend.transcribe(
                fileURL: url,
                apiKey: profile.apiKey,
                apiBase: profile.apiBase,
                model: profile.modelName,
                whisperCppPath: profile.whisperCppPath,
                whisperModelPath: profile.whisperModelPath
            )
            let segment = Segment(index: segments.count, text: text, backend: profile.backend.rawValue)
            segments.append(segment)
            persist(segments, to: Self.segmentsURL)
            statusMessage = "转写完成"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSegments() {
        segments = []
        persist(segments, to: Self.segmentsURL)
    }
}
