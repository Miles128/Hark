import SwiftUI
import AppKit

/// 复刻 App.vue 的左侧栏：模式切换 + ASR 双 tab + 各卡片。
struct SidebarView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette
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
                        VideoDownloadPanelView()
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
            Text("录音源")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.4)
                .foregroundColor(palette.textSecondary)

            HStack(spacing: 4) {
                ForEach(AudioSource.allCases) { option in
                    sourceChip(option)
                }
            }

            if model.source == .microphone || model.source == .both {
                deviceField(label: "麦克风设备", selection: $model.micDeviceName, options: model.micOptions)
            }
            if model.source == .system || model.source == .both {
                deviceField(label: "系统音频设备", selection: $model.systemDeviceName, options: model.systemOptions)
            }

            if !model.hasBlackhole {
                blackholeWarning
            }
        }
    }

    private func sourceChip(_ option: AudioSource) -> some View {
        let active = model.source == option
        let disabled = option.needsBlackhole && !model.hasBlackhole
        let color = Color(hex: option.optionColorHex)
        return Button {
            guard !disabled else { return }
            model.source = option
        } label: {
            HStack(spacing: 5) {
                Image(systemName: option == .microphone ? "mic" : option == .system ? "dot.radiowaves.right" : "mic.fill")
                    .font(.system(size: 11))
                Text(option.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(active ? .white : palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(active ? color : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? color : palette.border)
            )
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func deviceField(label: String, selection: Binding<String>, options: [AudioDeviceInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.textSecondary)
            Picker("", selection: selection) {
                Text("默认 / 自动").tag("")
                ForEach(options) { device in
                    Text(device.name).tag(device.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 12))
            .disabled(model.isRecording)
        }
    }

    private var blackholeWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("未检测到 BlackHole。要录外放或同时录，请先安装 BlackHole，然后在「音频 MIDI 设置」里创建多输出设备。")
                .font(.system(size: 11))
                .foregroundColor(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Link("下载 BlackHole", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole")!)
                    .font(.system(size: 11, weight: .medium))
                Button("打开音频 MIDI 设置") { model.openAudioMidiSetup() }
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.warning.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.warning.opacity(0.2)))
        .cornerRadius(6)
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
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("转写模型")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(0.5)
                    .foregroundColor(palette.textSecondary)
                Spacer()
                if model.activeProfile != nil {
                    Circle()
                        .fill(isInstalled(model.activeProfile?.backend) ? palette.success : palette.warning)
                        .frame(width: 7, height: 7)
                }
            }

            ZStack(alignment: .topLeading) {
                Button {
                    open.toggle()
                } label: {
                    HStack(spacing: 8) {
                        if let current = model.activeProfile {
                            backendIcon(current.backend, size: 18)
                            Text(current.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(palette.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(current.backend.sidebarLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(palette.textTertiary)
                        } else {
                            Text("未配置模型")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(palette.textTertiary)
                            Spacer(minLength: 0)
                        }
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(open ? -90 : 90))
                            .foregroundColor(palette.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(open ? palette.textTertiary : palette.border)
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(model.profiles.isEmpty)
                .opacity(model.profiles.isEmpty ? 0.6 : 1)

                if open && !model.profiles.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(model.profiles) { profile in
                            let isSelected = profile.id == model.selectedProfileId
                            Button {
                                model.selectedProfileId = profile.id
                                open = false
                            } label: {
                                HStack(spacing: 8) {
                                    backendIcon(profile.backend, size: 16)
                                    Text(profile.name)
                                        .font(.system(size: 13))
                                        .foregroundColor(isSelected ? palette.accent : palette.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(profile.backend.sidebarLabel)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(palette.textTertiary)
                                }
                                .padding(8)
                                .background(isSelected ? palette.accentSoft : Color.clear)
                                .cornerRadius(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(palette.surface)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
                    .cornerRadius(8)
                    .padding(.top, 42)
                    .zIndex(20)
                }
            }
        }
    }

    private func isInstalled(_ backend: AsrBackend?) -> Bool {
        guard let backend else { return false }
        return model.backendStatus.first { $0.backend == backend }?.installed ?? false
    }

    /// backendMeta 里是内联 SVG，这里用近似字形 + 主题色着色。
    @ViewBuilder
    private func backendIcon(_ backend: AsrBackend, size: CGFloat) -> some View {
        Image(systemName: backend.systemImage)
            .font(.system(size: size * 0.62, weight: .medium))
            .foregroundColor(backend.tintColor(in: palette))
            .frame(width: size, height: size)
    }
}

// MARK: - 网络视频转换（对齐 VideoDownloadPanel.vue）

struct VideoDownloadPanelView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette

    private struct VideoItem: Identifiable {
        enum Status { case pending, downloading, completed, error }

        let id: Int
        let url: String
        var status: Status = .pending
        var filePath: String?
        var error: String?
    }

    private static let pageSize = 5

    @State private var items: [VideoItem] = []
    @State private var newUrl = ""
    @State private var currentPage = 1
    @State private var nextID = 1
    @State private var error = ""

    private var totalPages: Int { (items.count + Self.pageSize - 1) / Self.pageSize }

    private var paginatedItems: [VideoItem] {
        let start = (currentPage - 1) * Self.pageSize
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + Self.pageSize, items.count)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            addSection
            if !items.isEmpty { actionsBar }
            content
            if totalPages > 1 { pagination }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("网络视频转换")
                .font(.system(size: 13, weight: .semibold))
                .kerning(0.5)
                .foregroundColor(palette.textSecondary)
            if !items.isEmpty {
                Text("\(items.count) 个视频")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("粘贴视频链接…", text: $newUrl)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit(addVideo)
                Button("添加", action: addVideo)
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(newUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("支持 YouTube、Bilibili 等主流视频网站，使用 yt-dlp 提取音频")
                .font(.system(size: 11))
                .foregroundColor(palette.textTertiary)
            if !error.isEmpty {
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
    }

    private var actionsBar: some View {
        HStack {
            Spacer()
            Button("全部下载") { Task { await downloadAll() } }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.bordered)
                .disabled(!items.contains { $0.status == .pending })
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            if items.isEmpty {
                Text("添加视频链接后，会显示在这里")
                    .font(.system(size: 13))
                    .foregroundColor(palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                ForEach(paginatedItems) { item in
                    videoRow(item)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
        .cornerRadius(8)
    }

    private func videoRow(_ item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.url)
                .font(.system(size: 13))
                .foregroundColor(palette.textPrimary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                statusBadge(item.status)
                switch item.status {
                case .pending:
                    rowButton("下载", background: palette.accent) { Task { await download(item) } }
                case .completed:
                    rowButton("转写", background: palette.success) { transcribe(item) }
                case .error:
                    rowButton("重试", background: palette.warning) { Task { await download(item) } }
                case .downloading:
                    EmptyView()
                }
                rowButton("移除", background: Color.clear, outlined: true) { remove(item.id) }
                Spacer(minLength: 0)
            }

            if let message = item.error {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(palette.danger)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceHover)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
        .cornerRadius(6)
    }

    private func statusBadge(_ status: VideoItem.Status) -> some View {
        let color: Color = switch status {
        case .pending: palette.warning
        case .downloading: palette.accent
        case .completed: palette.success
        case .error: palette.danger
        }
        let text: String = switch status {
        case .pending: "等待下载"
        case .downloading: "下载中..."
        case .completed: "✓ 完成"
        case .error: "✗ 失败"
        }
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    private func rowButton(_ title: String, background: Color, outlined: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(outlined ? palette.textSecondary : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(outlined ? Color.clear : background)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var pagination: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("‹") { goToPage(currentPage - 1) }
                .disabled(currentPage == 1)
            Text("\(currentPage) / \(totalPages)")
                .font(.system(size: 12))
                .foregroundColor(palette.textSecondary)
                .monospacedDigit()
            Button("›") { goToPage(currentPage + 1) }
                .disabled(currentPage == totalPages)
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    // MARK: - 行为

    private func addVideo() {
        error = ""
        let trimmed = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "请输入视频链接"
            return
        }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            error = "请输入有效的 HTTP/HTTPS 链接"
            return
        }
        guard !items.contains(where: { $0.url == trimmed }) else {
            error = "该链接已添加"
            return
        }
        items.append(VideoItem(id: nextID, url: trimmed))
        nextID += 1
        newUrl = ""
        currentPage = max(1, totalPages)
    }

    private func remove(_ id: Int) {
        items.removeAll { $0.id == id }
        if totalPages > 0 && currentPage > totalPages {
            currentPage = totalPages
        }
    }

    private func goToPage(_ page: Int) {
        guard page >= 1, page <= totalPages else { return }
        currentPage = page
    }

    private func downloadAll() async {
        for item in items.filter({ $0.status == .pending }) {
            await download(item)
        }
    }

    private func download(_ item: VideoItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].status = .downloading
        items[index].error = nil
        do {
            let file = try await model.downloadAudio(from: item.url)
            items[index].status = .completed
            items[index].filePath = file.path
        } catch {
            items[index].status = .error
            items[index].error = error.localizedDescription
        }
    }

    private func transcribe(_ item: VideoItem) {
        guard let path = item.filePath else { return }
        let url = URL(fileURLWithPath: path)
        model.recordedFileURL = url
        Task { await model.transcribeFile(at: url, index: 0) }
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
        .onChange(of: model.ttsBackend) { _, _ in
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
