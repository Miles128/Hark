import Foundation

enum AppMode: String, CaseIterable { case asr, tts }
enum AsrTab: String, CaseIterable { case recording, video }

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
        didSet { persist(profiles, to: Self.profilesURL) }
    }
    var selectedProfileId: String = ""
    var segments: [Segment] = []
    var isTranscribing = false
    var errorMessage: String?
    var statusMessage: String?

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
            let bridge = try PythonBridge()
            let backend = try AsrRouter.backend(for: profile.backend, bridge: bridge)
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
