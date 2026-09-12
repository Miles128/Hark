import SwiftUI

/// 对齐 SettingsModal.vue：主题 / 自动保存 / 档案 CRUD / 模型预热。
struct SettingsSheet: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var draftProfile: AsrProfile?
    @State private var isEditingExisting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border)
            Form {
                Section("外观") {
                    Picker("主题", selection: binding(\.theme)) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("自动保存") {
                    Stepper("间隔：\(model.settings.autoSaveInterval) 分钟",
                            value: binding(\.autoSaveInterval), in: 15...300, step: 15)
                    Picker("格式", selection: binding(\.autoSaveFormat)) {
                        Text("TXT").tag("txt")
                        Text("Markdown").tag("md")
                        Text("JSON").tag("json")
                    }
                    .pickerStyle(.segmented)
                }

                Section("识别档案") {
                    ForEach(model.profiles) { profile in
                        HStack {
                            Circle()
                                .fill(Color(hex: profile.backend.themeColorHex))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name.isEmpty ? profile.backend.displayName : profile.name)
                                    .font(.system(size: 13))
                                Text(profile.backend.displayName)
                                    .font(.system(size: 10))
                                    .foregroundColor(palette.textTertiary)
                            }
                            Spacer()
                            Button("编辑") {
                                isEditingExisting = true
                                draftProfile = profile
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                            Button("删除", role: .destructive) {
                                model.deleteProfile(profile.id)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                        }
                    }
                    Button {
                        isEditingExisting = false
                        draftProfile = AsrProfile(name: "", backend: .dashscope)
                    } label: {
                        Label("添加档案", systemImage: "plus")
                    }
                }

                Section("说明") {
                    Text("M1 阶段仅 DashScope（云端）可转写；录音、本地模型（whisper.cpp / MLX / SenseVoice）与 TTS 将在 M2-M4 里程碑接入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 520)
        .background(palette.bg)
        .sheet(item: $draftProfile) { profile in
            ProfileEditSheet(
                profile: profile,
                isNew: !isEditingExisting
            )
        }
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }
}


// MARK: - 档案编辑

struct ProfileEditSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var model = AppModel.shared

    @State var profile: AsrProfile
    let isNew: Bool

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("档案名称", text: $profile.name)
                Picker("后端", selection: $profile.backend) {
                    ForEach(AsrBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
            }
            Section("凭据与模型") {
                if profile.backend == .dashscope || profile.backend == .openaiWhisper {
                    SecureField("API Key", text: $profile.apiKey)
                    if profile.backend == .dashscope {
                        TextField("模型名", text: $profile.modelName, prompt: Text("qwen3-asr-flash"))
                    } else {
                        TextField("模型名", text: $profile.modelName, prompt: Text("whisper-1"))
                        TextField("API Base（可选）", text: $profile.apiBase)
                    }
                }
                if profile.backend == .whisperCpp {
                    TextField("whisper-cli 路径", text: $profile.whisperCppPath)
                    TextField("模型路径（ggml）", text: $profile.whisperModelPath)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "添加" : "保存") {
                    if isNew {
                        model.addProfile(profile)
                    } else {
                        model.updateProfile(profile)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.isEmpty)
            }
            .padding(.vertical, 8)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
    }
}
