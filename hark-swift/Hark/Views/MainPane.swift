import SwiftUI
import AppKit

/// 主区：ASR 模式显示转写记录，TTS 模式显示文本编辑。
struct MainPane: View {
    @State private var model = AppModel.shared

    var body: some View {
        Group {
            if model.mode == .asr {
                TranscriptPanelView()
            } else {
                TtsPanelView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 转写记录面板（对齐 TranscriptPanel.vue）

struct TranscriptPanelView: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border)
            if model.segments.isEmpty {
                ContentUnavailableView(
                    "暂无转写记录",
                    systemImage: "waveform.badge.magnifyingglass",
                    description: Text("录音或导入音频后，转写结果会显示在这里")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.segments) { segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("段 \(segment.index + 1)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(palette.accent)
                                    Text(segment.backend)
                                        .font(.system(size: 10))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(palette.surfaceHover)
                                        .overlay(Capsule().strokeBorder(palette.border))
                                        .clipShape(Capsule())
                                    Spacer()
                                    Text(segment.createdAt, style: .time)
                                        .font(.system(size: 10))
                                        .foregroundColor(palette.textTertiary)
                                }
                                Text(segment.text)
                                    .font(.system(size: 14))
                                    .foregroundColor(palette.textPrimary)
                                    .textSelection(.enabled)
                            }
                            .padding(14)
                            Divider().overlay(palette.border)
                        }
                    }
                }
            }
        }
        .background(palette.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("转写记录")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.textPrimary)
            Text("\(model.segments.count) 段")
                .font(.system(size: 11))
                .foregroundColor(palette.textTertiary)
            Spacer()
            if copied {
                Text("已复制")
                    .font(.system(size: 11))
                    .foregroundColor(palette.success)
            }
            Button("复制全部") { copyAll() }
                .font(.system(size: 12))
                .disabled(model.segments.isEmpty)
            Menu("导出") {
                Button("导出为 TXT") { exportAs { url in save(segmentsText, to: url) } }
                    .disabled(model.segments.isEmpty)
                Button("导出为 Markdown") { exportAs { url in save(markdownText, to: url) } }
                    .disabled(model.segments.isEmpty)
                Button("导出为 JSON") { exportAs { url in save(jsonText, to: url) } }
                    .disabled(model.segments.isEmpty)
            }
            .font(.system(size: 12))
            .disabled(model.segments.isEmpty)
            Button("清空", role: .destructive) { model.clearSegments() }
                .font(.system(size: 12))
                .disabled(model.segments.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var segmentsText: String {
        model.segments.map(\.text).joined(separator: "\n\n")
    }

    private var markdownText: String {
        let lines = model.segments.enumerated().map { "### 段 \($0.offset + 1)\n\n\($0.element.text)" }
        return "# Hark 转写结果\n\n" + lines.joined(separator: "\n\n")
    }

    private var jsonText: String {
        let payload: [String: Any] = [
            "segments": model.segments.map { ["text": $0.text, "backend": $0.backend] },
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(segmentsText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func exportAs(_ writer: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hark-transcript-\(Int(Date().timeIntervalSince1970))"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writer(url)
    }

    private func save(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - TTS 文本面板（对齐 TtsPanel.vue）

struct TtsPanelView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ContentUnavailableView(
            "TTS 合成",
            systemImage: "waveform.badge.mic",
            description: Text("文本转语音将在 M3 里程碑接入")
        )
    }
}
