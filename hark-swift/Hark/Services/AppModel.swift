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
        case .system: "外放"
        case .both: "同时录"
        }
    }
    var desc: String {
        switch self {
        case .microphone: "只录人声"
        case .system: "录系统声音"
        case .both: "人声 + 系统声音"
        }
    }
    /// options[].color（--mic-color / --system-color / --both-color），选中时作为底色。
    var optionColorHex: UInt32 {
        switch self {
        case .microphone: 0xFF375F
        case .system: 0x32ADE6
        case .both: 0xAF52DE
        }
    }
    var needsBlackhole: Bool { self == .system || self == .both }
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
        didSet {
            guard settings != oldValue else { return }
            persistSettings()
        }
    }
    /// asr_profiles 表的只读快照，改动一律走 ProfileStore 再 reloadProfiles()。
    var profiles: [AsrProfile] = [] {
        didSet { refreshAsrStatus() }
    }
    var selectedProfileId: String = "" {
        didSet {
            refreshAsrStatus()
            if oldValue != selectedProfileId {
                settings.activeProfileId = selectedProfileId
            }
        }
    }
    /// 对齐 Rust：转写记录只在内存里（`Mutex<Vec<TranscriptSegment>>`），
    /// 重启即空，持久出口是自动保存的文本文件。
    var segments: [Segment] = []
    var isTranscribing = false
    var errorMessage: String?
    var statusMessage: String?

    private let store: ProfileStore?
    private let autoSave = AutoSaveLoop()

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
    private var sliceConsumer: Task<Void, Never>?

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
            warmup = WarmupEvent(status: "ready", message: profile.backend.warmupReadyMessage)
        } catch {
            warmup = WarmupEvent(status: "error", message: error.localizedDescription)
        }
    }

    func loadDevices() {
        devices = CoreAudioDevices.inputDevices()
        hasBlackhole = CoreAudioDevices.hasBlackhole()
        if micDeviceName.isEmpty {
            let builtin = micOptions.first {
                $0.name.localizedCaseInsensitiveContains("macbook") || $0.name.localizedCaseInsensitiveContains("built-in")
            } ?? micOptions.first {
                $0.name.localizedCaseInsensitiveContains("microphone") || $0.name.contains("麦克风")
            }
            micDeviceName = builtin?.name ?? micOptions.first?.name ?? ""
        }
        if systemDeviceName.isEmpty {
            systemDeviceName = systemOptions.first?.name ?? ""
        }
    }

    var micOptions: [AudioDeviceInfo] { devices.filter { !CoreAudioDevices.isLoopbackDevice($0.name) } }
    var systemOptions: [AudioDeviceInfo] { devices.filter { CoreAudioDevices.isLoopbackDevice($0.name) } }

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

        if liveTranscribe {
            recorder.enableSlicing()
        } else {
            recorder.disableSlicing()
        }

        let mic = devices.first { $0.name == micDeviceName }
        let system = devices.first { $0.name == systemDeviceName }
        do {
            try recorder.startRecording(
                source: source.recorderKind,
                micDevice: mic,
                systemDevice: system
            )
            if liveTranscribe, let stream = recorder.sliceStream {
                consumeSlices(from: stream)
            }
            statusMessage = nil
        } catch {
            recorder.disableSlicing()
            errorMessage = error.localizedDescription
        }
    }

    /// 停止录音；边录边转关掉时立即转写整段。
    private func stopAndTranscribe() {
        guard let url = recorder.stopRecording() else { return }
        recordedFileURL = url
        if !liveTranscribe {
            Task { await transcribeFile(at: url, index: 0) }
        }
    }

    // MARK: - 持久化

    private static var legacyProfilesJSON: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hark/profiles.json")
    }

    private init() {
        store = ProfileStore.open()
        store?.importLegacyJSONIfNeeded(from: Self.legacyProfilesJSON)

        settings = Self.loadSettings()
        profiles = (try? store?.list()) ?? []
        selectedProfileId = settings.activeProfileId
        if profiles.first(where: { $0.id == selectedProfileId }) == nil {
            selectedProfileId = profiles.first?.id ?? ""
        }
        // init 中的赋值不走 didSet，这里手动同步，避免 Rust 读到已失效的 activeProfileId。
        if settings.activeProfileId != selectedProfileId {
            settings.activeProfileId = selectedProfileId
        }
        refreshAsrStatus()
        startAutoSave()
    }

    private static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: HarkPaths.settingsFile) else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    /// 与 Rust 的 `serde_json::to_string_pretty` 对齐：两空格缩进、activeProfileId 为空写 null。
    /// （JSONEncoder 不保证键序，但 JSON 语义与键序无关。）
    ///
    /// Rust 只在 `set_app_settings` 里写盘；这里靠"语义未变就不写"抵消 @Observable
    /// 让 init 赋值也触发 didSet 的后果，避免每次启动都覆盖共享配置文件。
    private func persistSettings() {
        if let data = try? Data(contentsOf: HarkPaths.settingsFile),
           let onDisk = try? JSONDecoder().decode(AppSettings.self, from: data),
           onDisk == settings {
            return
        }
        HarkPaths.ensure(HarkPaths.appData)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: HarkPaths.settingsFile, options: .atomic)
    }

    private func reloadProfiles() {
        profiles = (try? store?.list()) ?? []
    }

    private func startAutoSave() {
        autoSave.start(
            intervalProvider: { [weak self] in
                guard let settings = self?.settings else { return (interval: 0, format: "txt") }
                return (interval: settings.autoSaveInterval, format: settings.autoSaveFormat)
            },
            segmentsProvider: { [weak self] in self?.segments ?? [] }
        )
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
        errorMessage = nil
        do {
            guard let store else { throw ProfileStoreError.unavailable }
            let added = try store.add(profile)
            reloadProfiles()
            selectedProfileId = added.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateProfile(_ profile: AsrProfile) {
        errorMessage = nil
        do {
            guard let store else { throw ProfileStoreError.unavailable }
            try store.update(profile)
            reloadProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProfile(_ id: String) {
        errorMessage = nil
        do {
            guard let store else { throw ProfileStoreError.unavailable }
            try store.delete(id: id)
            reloadProfiles()
            if selectedProfileId == id {
                selectedProfileId = profiles.first?.id ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 转写

    /// 对齐 `transcribe_file_cmd`：转写一个文件，结果按 index 追加进内存转写记录。
    func transcribeFile(at url: URL, index: Int? = nil) async {
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
            appendSegment(Segment(index: index ?? segments.count, text: text, backend: profile.backend.rawValue))
            statusMessage = "转写完成"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 等价于 Rust 的 `transcript.push(segment)` + `emit("asr:segment")`。
    private func appendSegment(_ segment: Segment) {
        segments.append(segment)
    }

    func clearSegments() {
        segments = []
    }

    // MARK: - 边录边转（对齐 Rust 的 slice_queue 生产者/消费者）

    /// 消费者逐个 await，所以切片转写天然串行，与 Rust 的 mpsc 消费者一致。
    private func consumeSlices(from stream: AsyncStream<(URL, Int)>) {
        sliceConsumer?.cancel()
        sliceConsumer = Task { [weak self] in
            for await (url, index) in stream {
                guard !Task.isCancelled else { break }
                await self?.transcribeFile(at: url, index: index)
            }
        }
    }

    // MARK: - 链接下载（对齐 download_audio_from_url）

    /// yt-dlp 抽音频到 ~/Music/hark-asr/downloads，返回落盘的 wav 路径。
    func downloadAudio(from link: String) async throws -> URL {
        let outputDir = HarkPaths.downloads
        return try await Task.detached(priority: .userInitiated) {
            try UrlAudioDownloader.download(url: link, outputDir: outputDir)
        }.value
    }

    /// 对齐 `open_audio_midi_setup`：用 `open -a` 拉起系统音频 MIDI 设置。
    func openAudioMidiSetup() {
        errorMessage = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Audio MIDI Setup"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            errorMessage = "打开音频 MIDI 设置失败: \(error.localizedDescription)"
        }
    }
}
