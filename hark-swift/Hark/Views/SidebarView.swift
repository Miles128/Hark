import SwiftUI
import AppKit

/// 复刻 App.vue 的左侧栏：模式切换 + ASR 双 tab + 各卡片。
struct SidebarView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette
    @State private var videoURL = ""
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.sidebarCollapsed {
                content
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: model.sidebarCollapsed ? 56 : 320)
        .background(palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.border).frame(width: 1)
        }
        .animation(.easeInOut(duration: 0.25), value: model.sidebarCollapsed)
        .task { model.loadDevices() }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result {
                Task { await model.transcribeFile(at: url) }
            }
        }
    }

    // MARK: - Header：模式切换 + 设置/折叠

    private var header: some View {
        HStack(spacing: 8) {
            if !model.sidebarCollapsed {
                ModeSwitcher(mode: $model.mode)
            }
            HStack(spacing: 4) {
                iconButton("gearshape") { model.settingsOpen = true }
                iconButton(model.sidebarCollapsed ? "chevron.right" : "chevron.left") {
                    model.sidebarCollapsed.toggle()
                }
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func iconButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.textSecondary)
                .frame(width: 30, height: 30)
                .background(palette.surfaceHover)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.mode == .asr {
                    TabSwitcher(tab: $model.tab)
                    switch model.tab {
                    case .recording:
                        SourceSelectorView()
                        VolumeMeterView(db: model.volumeDb, level: model.volumeLevel, isRecording: model.isRecording)
                        BackendSelectorView()
                        recordCard
                        if model.isTranscribing {
                            statusText("正在转写…\n本地模型首次加载较慢，请稍等")
                        }
                        if model.isRecording {
                            statusText("录音中…")
                        }
                        if let url = model.recordedFileURL, !model.isRecording, !model.liveTranscribe {
                            statusText("已保存 \(url.lastPathComponent)")
                        }
                        if let status = model.statusMessage {
                            statusText(status)
                        }
                        if let error = model.errorMessage {
                            errorBanner(error)
                        }
                    case .video:
                        VideoDownloadPanelView(url: $videoURL)
                    }
                } else {
                    TtsControlsView(text: $model.ttsText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .padding(.top, 6)
    }

    // MARK: - 录音卡（录音按钮 + 边录边转）

    private var recordCard: some View {
        VStack(spacing: 8) {
            Button {
                Task { await model.toggleRecording() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                    Text(model.isRecording ? "停止" : "录音")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(model.isRecording ? palette.danger : palette.accent)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                showFilePicker = true
            } label: {
                Label("导入音频文件转写", systemImage: "doc.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
            }
            .buttonStyle(.bordered)
            .tint(palette.accent)
            .disabled(model.isTranscribing)

            Toggle(isOn: $model.liveTranscribe) {
                Text("边录边转")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(model.isRecording)
            .padding(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .fill(palette.border)
            )
        }
        .padding(10)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border)
        )
        .cornerRadius(10)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(palette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(palette.danger)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.danger.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(palette.danger.opacity(0.15))
            )
            .cornerRadius(6)
    }
}

// MARK: - ASR / TTS 模式切换

struct ModeSwitcher: View {
    @Binding var mode: AppMode
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppMode.allCases, id: \.self) { m in
                Button {
                    withAnimation { mode = m }
                } label: {
                    Text(m == .asr ? "ASR" : "TTS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(mode == m ? .white : palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(mode == m ? palette.accent : .clear)
                }
                .buttonStyle(.plain)
                if m != AppMode.allCases.last {
                    Rectangle().fill(palette.border).frame(width: 1)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 录音 / 视频 tab 切换

struct TabSwitcher: View {
    @Binding var tab: AsrTab
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AsrTab.allCases, id: \.self) { t in
                Button {
                    withAnimation { tab = t }
                } label: {
                    Label(t == .recording ? "录音" : "视频",
                          systemImage: t == .recording ? "mic" : "film")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(tab == t ? palette.accent : palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(tab == t ? palette.accentSoft : .clear)
                }
                .buttonStyle(.plain)
                if t != AsrTab.allCases.last {
                    Rectangle().fill(palette.border).frame(width: 1)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 声音来源

struct SourceSelectorView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("声音来源")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.textSecondary)
            Picker("", selection: $model.source) {
                ForEach(AudioSource.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRecording)

            if model.source != .microphone {
                devicePicker(
                    label: "系统声音设备",
                    selection: $model.systemDeviceName,
                    devices: model.devices.filter { $0.name.contains("BlackHole") },
                    placeholder: model.hasBlackhole ? nil : "未检测到 BlackHole"
                )
                if !model.hasBlackhole {
                    Text("系统声音需安装 BlackHole 并开启多输出设备")
                        .font(.system(size: 11))
                        .foregroundColor(palette.textTertiary)
                }
            }
            if model.source != .system {
                devicePicker(
                    label: "麦克风",
                    selection: $model.micDeviceName,
                    devices: model.devices.filter { !$0.name.contains("BlackHole") },
                    placeholder: nil
                )
            }
            Button("打开音频 MIDI 设置") {
                SystemAudio.openAudioMIDISetup()
            }
            .font(.system(size: 11))
            .buttonStyle(.link)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func devicePicker(
        label: String,
        selection: Binding<String>,
        devices: [AudioDeviceInfo],
        placeholder: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(palette.textSecondary)
            if devices.isEmpty {
                Text(placeholder ?? "没有可用设备")
                    .font(.system(size: 11))
                    .foregroundColor(palette.textTertiary)
            } else {
                Picker("", selection: selection) {
                    ForEach(devices) { d in
                        Text(d.name).tag(d.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(.system(size: 11))
                .disabled(model.isRecording)
            }
        }
    }
}

// MARK: - 音量条

struct VolumeMeterView: View {
    var db: Float
    var level: Double
    var isRecording: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("音量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.textSecondary)
                Spacer()
                Text(String(format: "%.0f dB", db))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.textTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.surfaceHover)
                    Capsule()
                        .fill(isRecording ? palette.success : palette.surfaceHover)
                        .frame(width: max(2, geo.size.width * level))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border))
        .cornerRadius(10)
    }
}

// MARK: - 后端（档案）选择

struct BackendSelectorView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别模型")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.textSecondary)
            ForEach(model.profiles) { profile in
                Button {
                    model.selectedProfileId = profile.id
                    model.settings.activeProfileId = profile.id
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: profile.backend.themeColorHex))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name.isEmpty ? profile.backend.displayName : profile.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(palette.textPrimary)
                            Text(profile.backend.displayName)
                                .font(.system(size: 10))
                                .foregroundColor(palette.textTertiary)
                        }
                        Spacer()
                        if profile.id == model.selectedProfileId {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(palette.accent)
                        }
                    }
                    .padding(8)
                    .background(profile.id == model.selectedProfileId ? palette.accentSoft : palette.surfaceHover)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            Text("后端状态检测将随 M2 接入")
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border))
        .cornerRadius(10)
    }
}

// MARK: - 视频下载面板（M2 接 yt-dlp）

struct VideoDownloadPanelView: View {
    @Binding var url: String
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("视频 / 音频链接")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.textSecondary)
            TextField("https://…", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Button {
                model.errorMessage = "URL 下载转写将在 M2 里程碑接入（yt-dlp）"
            } label: {
                Text("下载并转写")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            Text("下载引擎：yt-dlp（M2 接入）")
                .font(.system(size: 10))
                .foregroundColor(palette.textTertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border))
        .cornerRadius(10)
    }
}

// MARK: - TTS 控制区（对齐 TtsControls.vue）

struct TtsControlsView: View {
    @Binding var text: String
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("引擎")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.textSecondary)
                HStack(spacing: 6) {
                    backendChip(.edge)
                    backendChip(.cosyVoice)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("语速 \(model.rateStr)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.textSecondary)
                Slider(
                    value: Binding(
                        get: { Double(model.ratePercent) },
                        set: { model.ratePercent = Int(($0 / 5).rounded() * 5) }
                    ),
                    in: -50...100,
                    step: 5
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("音色")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.textSecondary)
                HStack(spacing: 6) {
                    Picker("", selection: $model.localeFilter) {
                        Text("全部语言").tag("all")
                        ForEach(model.locales, id: \.self) { loc in
                            Text(loc).tag(loc)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 110)
                    .font(.system(size: 12))
                    TextField("搜索音色…", text: $model.voiceQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                voiceList
            }

            VStack(spacing: 6) {
                Button {
                    Task { await model.synthesizeAndPlay(text) }
                } label: {
                    Text(model.isSynthesizing ? "合成中…" : "生成并播放")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(palette.accent)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isSynthesizing)

                Button {
                    exportAudio()
                } label: {
                    Text("导出音频")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .overlay(Capsule().strokeBorder(palette.border))
                        .foregroundColor(palette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isSynthesizing)
            }

            if let path = model.lastTtsPath {
                Text("已生成 \(path)")
                    .font(.system(size: 11))
                    .foregroundColor(palette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if let error = model.ttsError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(palette.danger)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.danger.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.danger.opacity(0.15)))
                    .cornerRadius(6)
            }
        }
        .task {
            model.refreshTtsStatus()
            await model.loadTtsVoices()
        }
        .onChange(of: model.ttsBackend) { _ in
            model.localeFilter = "all"
            model.voiceQuery = ""
            model.ttsVoiceId = model.ttsBackend == .cosyVoice ? "longxiaochun" : "zh-CN-XiaoxiaoNeural"
            Task { await model.loadTtsVoices() }
        }
    }

    private func backendChip(_ kind: TtsBackendKind) -> some View {
        let installed = model.ttsStatus.first { $0.backend == kind.rawValue }?.installed ?? false
        let active = model.ttsBackend == kind
        return Button {
            model.ttsBackend = kind
        } label: {
            HStack(spacing: 6) {
                Text(kind.title)
                    .font(.system(size: 12, weight: .medium))
                Circle()
                    .fill(active && installed ? Color.white : (installed ? palette.success : palette.textTertiary))
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(active ? palette.accent : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? palette.accent : palette.border))
            .foregroundColor(active ? .white : palette.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var voiceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.filteredTtsVoices) { v in
                    Button {
                        model.ttsVoiceId = v.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(palette.textPrimary)
                            Text("\(v.locale) · \(v.gender.isEmpty ? "—" : v.gender)")
                                .font(.system(size: 10))
                                .foregroundColor(palette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(model.ttsVoiceId == v.id ? palette.accentSoft : .clear)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(palette.border).frame(height: 1)
                    }
                }
                if model.filteredTtsVoices.isEmpty {
                    Text("无匹配音色")
                        .font(.system(size: 12))
                        .foregroundColor(palette.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
        }
        .frame(maxHeight: 180)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func exportAudio() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hark-tts-\(Int(Date().timeIntervalSince1970 * 1000)).mp3"
        panel.allowedContentTypes = [.mp3]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            do {
                let src = try await model.synthesizeText(text)
                try FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(atPath: src, toPath: dest.path)
            } catch {
                model.ttsError = error.localizedDescription
            }
        }
    }
}
