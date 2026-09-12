import SwiftUI

/// 对齐 SettingsModal.vue：三 tab（通用 / 模型与 API / 自动保存）+ 内联档案编辑表单。
struct SettingsSheet: View {
    @State private var model = AppModel.shared
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: SettingsTab = .general
    @State private var editingProfile: AsrProfile?
    @State private var pendingDeleteID: String?

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, models, autosave
        var id: Self { self }
        var label: String {
            switch self {
            case .general: "通用"
            case .models: "模型与 API"
            case .autosave: "自动保存"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch activeTab {
                    case .general: generalTab
                    case .models: modelsTab
                    case .autosave: autosaveTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 460, height: 520)
        .background(palette.surface)
        .confirmationDialog(
            "确定删除该模型配置？",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            ),
            presenting: pendingDeleteID
        ) { id in
            Button("删除", role: .destructive) { model.deleteProfile(id) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Header / Tabs

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(palette.textPrimary)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(activeTab == tab ? palette.accent : palette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(activeTab == tab ? palette.accent : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 41)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    // MARK: - 通用

    @ViewBuilder
    private var generalTab: some View {
        section("外观") {
            settingRow("主题") {
                segmented(
                    ThemeMode.allCases.map { ($0, $0.title) },
                    selection: Binding(get: { model.settings.theme }, set: { model.settings.theme = $0 })
                )
                .frame(width: 200)
            }
        }
    }

    // MARK: - 模型与 API

    @ViewBuilder
    private var modelsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                sectionTitle("已保存的模型")
                Spacer()
                actionButton("添加模型", primary: true) {
                    editingProfile = AsrProfile(name: "", backend: .mlxQwen3)
                }
            }

            if model.profiles.isEmpty {
                hint("暂无模型配置，请点击“添加模型”。")
            }

            ForEach(model.profiles) { profile in
                profileCard(profile)
            }
        }

        if let draft = editingProfile {
            profileForm(draft)
        }
    }

    private func profileCard(_ profile: AsrProfile) -> some View {
        let isActive = profile.id == model.selectedProfileId
        let installed = model.backendStatus.first { $0.backend == profile.backend }?.installed ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(profile.backend.settingsLabel)
                    .font(.system(size: 11))
                    .foregroundColor(palette.textTertiary)
                Circle()
                    .fill(installed ? palette.success : palette.warning)
                    .frame(width: 7, height: 7)
                Button("编辑") { editingProfile = profile }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                Button("删除") { pendingDeleteID = profile.id }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            if !profile.installHint.isEmpty {
                Text(profile.installHint)
                    .font(.system(size: 11))
                    .foregroundColor(palette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isActive ? palette.accentSoft : palette.surfaceHover)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isActive ? palette.accent : palette.border)
        )
        .cornerRadius(6)
    }

    @ViewBuilder
    private func profileForm(_ draft: AsrProfile) -> some View {
        // 表单直接绑定 editingProfile，所以用一个包装 View 拿 Binding。
        ProfileFormView(
            draft: Binding(
                get: { draft },
                set: { editingProfile = $0 }
            ),
            onSave: {
                let trimmed = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                var profile = $0
                profile.name = trimmed
                if profile.id.isEmpty {
                    model.addProfile(profile)
                } else {
                    model.updateProfile(profile)
                }
                editingProfile = nil
            },
            onCancel: { editingProfile = nil },
            onWarmup: { Task { await model.warmupModel() } },
            warmup: model.warmup
        )
    }

    // MARK: - 自动保存

    @ViewBuilder
    private var autosaveTab: some View {
        section("自动保存") {
            settingRow("保存间隔") {
                Picker("", selection: Binding(
                    get: { model.settings.autoSaveInterval },
                    set: { model.settings.autoSaveInterval = $0 }
                )) {
                    ForEach(Self.intervalOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            settingRow("保存格式") {
                segmented(
                    [("txt", "TXT"), ("md", "Markdown")],
                    selection: Binding(get: { model.settings.autoSaveFormat }, set: { model.settings.autoSaveFormat = $0 })
                )
                .frame(width: 160)
            }
            hint("自动保存路径：~/Music/hark-asr/auto-save/")
        }
    }

    /// intervalOptions：Rust 侧单位是秒，0 表示关闭。
    static let intervalOptions: [(UInt64, String)] = [
        (0, "关闭"),
        (30, "30 秒"),
        (60, "1 分钟"),
        (120, "2 分钟"),
        (300, "5 分钟"),
        (600, "10 分钟"),
    ]

    // MARK: - 复用小组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .kerning(0.5)
            .foregroundColor(palette.textSecondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title)
            content()
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(palette.textPrimary)
            Spacer(minLength: 16)
            content()
        }
        .frame(minHeight: 32)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(palette.textTertiary)
    }

    private func segmented<T: Hashable>(_ options: [(T, String)], selection: Binding<T>) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option in
                Button {
                    selection.wrappedValue = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selection.wrappedValue == option.0 ? .white : palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(selection.wrappedValue == option.0 ? palette.accent : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.surfaceHover)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func actionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(primary ? .white : palette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(primary ? palette.accent : palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(primary ? palette.accent : palette.border)
                )
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 档案编辑表单（SettingsModal.vue 的内联编辑区）

private struct ProfileFormView: View {
    @Binding var draft: AsrProfile
    var onSave: (AsrProfile) -> Void
    var onCancel: () -> Void
    var onWarmup: () -> Void
    var warmup: WarmupEvent?

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.id.isEmpty ? "添加模型" : "编辑模型")
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.5)
                .foregroundColor(palette.textSecondary)

            field("名称") { TextField("", text: $draft.name) }
            field("类型") {
                Picker("", selection: $draft.backend) {
                    ForEach(AsrBackend.settingsOrder) { backend in
                        Text(backend.settingsLabel).tag(backend)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if draft.backend.isOnline {
                field("API Key") { SecureField("", text: $draft.apiKey) }
                field("API Base URL") { TextField("", text: $draft.apiBase) }
                field("模型名称") { TextField("", text: $draft.modelName) }
            }

            if draft.backend == .sensevoice {
                field("模型路径") {
                    TextField("~/models/mlx-community/SenseVoiceSmall", text: $draft.modelName)
                }
            }

            if draft.backend == .whisperCpp {
                field("whisper-cli 路径") { TextField("", text: $draft.whisperCppPath) }
                field("模型路径") { TextField("", text: $draft.whisperModelPath) }
            }

            field("安装 / 接入说明") {
                TextEditor(text: $draft.installHint)
                    .font(.system(size: 12))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border))
            }

            if draft.backend == .mlxQwen3 {
                VStack(alignment: .leading, spacing: 6) {
                    Button("预加载 / 下载模型", action: onWarmup)
                    if let warmup {
                        Text(warmup.message)
                            .font(.system(size: 11))
                            .foregroundColor(warmup.status == "error" ? palette.danger
                                : warmup.status == "ready" ? palette.success
                                : palette.textTertiary)
                    }
                }
            }

            if draft.backend == .sensevoice {
                Text("模型路径默认为 ~/models/mlx-community/SenseVoiceSmall")
                    .font(.system(size: 11))
                    .foregroundColor(palette.textTertiary)
            }

            HStack(spacing: 8) {
                Button("保存") { onSave(draft) }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", action: onCancel)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceHover)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(palette.textSecondary)
            content()
                .font(.system(size: 12))
                .textFieldStyle(.roundedBorder)
        }
    }
}
