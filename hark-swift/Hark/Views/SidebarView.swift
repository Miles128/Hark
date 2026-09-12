import SwiftUI
import AppKit

/// 复刻 App.vue 的左侧栏：模式切换 + ASR 双 tab + 各卡片。
struct SidebarView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette
    @State private var source = AudioSource.microphone
    @State private var liveTranscribe = false
    @State private var videoURL = ""
    @State private var ttsText = ""
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
                        SourceSelectorView(source: $source)
                        VolumeMeterView()
                        BackendSelectorView()
                        recordCard
                        if model.isTranscribing {
                            statusText("正在转写…\n本地模型首次加载较慢，请稍等")
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
                    TtsControlsView(text: $ttsText)
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
                model.errorMessage = "录音链路将在 M2 里程碑接入，当前可先用下方「导入音频文件」转写"
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                    Text("录音")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(palette.accent)
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

            Toggle(isOn: $liveTranscribe) {
                Text("边录边转")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
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
}

struct SourceSelectorView: View {
    @Binding var source: AudioSource
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("声音来源")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.textSecondary)
            Picker("", selection: $source) {
                ForEach(AudioSource.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if source != .microphone {
                HStack(spacing: 6) {
                    Circle().fill(palette.systemColor).frame(width: 7, height: 7)
                    Text("系统声音经 BlackHole 采集（M2 接入设备枚举）")
                        .font(.system(size: 11))
                        .foregroundColor(palette.textTertiary)
                }
            }
            Button("打开音频 MIDI 设置") {
                if let url = URL(string: "file:///System/Applications/Utilities/Audio%20MIDI%20Setup.app") {
                    NSWorkspace.shared.open(url)
                }
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
}

// MARK: - 音量条（M2 接实时电平）

struct VolumeMeterView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("音量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.textSecondary)
                Spacer()
                Text("-60 dB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.textTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.surfaceHover)
                    Capsule().fill(palette.success).frame(width: 2)
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

// MARK: - TTS 控制区（M3 接入合成）

struct TtsControlsView: View {
    @Binding var text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文本转语音")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.textSecondary)
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .background(palette.surfaceHover)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
                .cornerRadius(6)
            Button("开始合成") {}
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(true)
            Text("Edge / CosyVoice 合成将在 M3 里程碑接入")
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
