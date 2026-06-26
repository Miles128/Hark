<script setup lang="ts">
import { ref, watch, onMounted } from "vue";
import type { AsrBackend, AsrProfile } from "../types/asr";

export type ThemeMode = "system" | "light" | "dark";
export type AutoSaveInterval = 0 | 30 | 60 | 120 | 300 | 600;
export type AutoSaveFormat = "txt" | "md";

export interface AppSettings {
  theme: ThemeMode;
  autoSaveInterval: AutoSaveInterval;
  autoSaveFormat: AutoSaveFormat;
  activeProfileId: string;
}

interface BackendStatus {
  backend: string;
  installed: boolean;
  hint: string;
}

interface WarmupStatus {
  status: string;
  message: string;
}

type SettingsTab = "general" | "models" | "autosave";

const props = defineProps<{
  modelValue: boolean;
  settings: AppSettings;
  profiles: AsrProfile[];
  activeProfileId: string;
  status: BackendStatus[];
  warmupStatus?: WarmupStatus | null;
}>();

const emit = defineEmits<{
  (e: "update:modelValue", value: boolean): void;
  (e: "update:settings", value: AppSettings): void;
  (e: "addProfile", profile: AsrProfile): void;
  (e: "updateProfile", profile: AsrProfile): void;
  (e: "deleteProfile", id: string): void;
  (e: "warmup"): void;
}>();

const local = ref<AppSettings>({ ...props.settings });
const activeTab = ref<SettingsTab>("general");
const editingProfile = ref<AsrProfile | null>(null);

watch(
  () => props.settings,
  (v) => {
    local.value = { ...v };
  },
  { deep: true }
);

function applyTheme(theme: ThemeMode) {
  const root = document.documentElement;
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const isDark = theme === "dark" || (theme === "system" && prefersDark);
  if (isDark) {
    root.classList.add("dark");
  } else {
    root.classList.remove("dark");
  }
}

function update<K extends keyof AppSettings>(key: K, value: AppSettings[K]) {
  local.value = { ...local.value, [key]: value };
  emit("update:settings", local.value);
  if (key === "theme") {
    applyTheme(value as ThemeMode);
  }
}

onMounted(() => {
  applyTheme(props.settings.theme);
});

const tabs: { key: SettingsTab; label: string }[] = [
  { key: "general", label: "通用" },
  { key: "models", label: "模型与 API" },
  { key: "autosave", label: "自动保存" },
];

function isInstalled(backend: string) {
  return props.status.find((s) => s.backend === backend)?.installed ?? false;
}

const backendTypes: { value: AsrBackend; label: string }[] = [
  { value: "MlxQwen3", label: "mlx-qwen3-asr（本地）" },
  { value: "WhisperCpp", label: "whisper.cpp（本地）" },
  { value: "DashScope", label: "DashScope（联网）" },
  { value: "OpenAiWhisper", label: "OpenAI Whisper（联网）" },
];

function isOnlineBackend(backend: AsrBackend) {
  return backend === "DashScope" || backend === "OpenAiWhisper";
}

function backendLabel(backend: AsrBackend) {
  return backendTypes.find((t) => t.value === backend)?.label ?? backend;
}

function emptyProfile(): AsrProfile {
  return {
    id: "",
    name: "",
    backend: "MlxQwen3",
    apiKey: "",
    apiBase: "",
    modelName: "",
    whisperCppPath: "",
    whisperModelPath: "",
    installHint: "",
  };
}

function startAdd() {
  editingProfile.value = emptyProfile();
}

function startEdit(profile: AsrProfile) {
  editingProfile.value = { ...profile };
}

function saveProfile() {
  if (!editingProfile.value) return;
  const p = { ...editingProfile.value };
  if (!p.name.trim()) return;
  if (p.id) {
    emit("updateProfile", p);
  } else {
    emit("addProfile", p);
  }
  editingProfile.value = null;
}

function deleteProfile(id: string) {
  if (confirm("确定删除该模型配置？")) {
    emit("deleteProfile", id);
    if (editingProfile.value?.id === id) {
      editingProfile.value = null;
    }
  }
}

const themeOptions: { value: ThemeMode; label: string }[] = [
  { value: "system", label: "跟随系统" },
  { value: "light", label: "浅色" },
  { value: "dark", label: "深色" },
];

const intervalOptions: { value: AutoSaveInterval; label: string }[] = [
  { value: 0, label: "关闭" },
  { value: 30, label: "30 秒" },
  { value: 60, label: "1 分钟" },
  { value: 120, label: "2 分钟" },
  { value: 300, label: "5 分钟" },
  { value: 600, label: "10 分钟" },
];

const formatOptions: { value: AutoSaveFormat; label: string }[] = [
  { value: "txt", label: "TXT" },
  { value: "md", label: "Markdown" },
];
</script>

<template>
  <Teleport to="body">
    <Transition name="overlay">
      <div v-if="modelValue" class="settings-overlay" @click.self="$emit('update:modelValue', false)">
        <Transition name="modal">
          <div v-if="modelValue" class="settings-modal">
            <div class="settings-header">
              <h2>设置</h2>
              <button class="close-btn" @click="$emit('update:modelValue', false)">✕</button>
            </div>

            <div class="settings-tabs">
              <button
                v-for="t in tabs"
                :key="t.key"
                class="tab"
                :class="{ active: activeTab === t.key }"
                @click="activeTab = t.key"
              >
                {{ t.label }}
              </button>
            </div>

            <div class="settings-body">
              <!-- 通用 -->
              <template v-if="activeTab === 'general'">
                <section class="setting-section">
                  <h3>外观</h3>
                  <div class="setting-row">
                    <span class="setting-label">主题</span>
                    <div class="segmented">
                      <button
                        v-for="opt in themeOptions"
                        :key="opt.value"
                        class="segment"
                        :class="{ active: local.theme === opt.value }"
                        @click="update('theme', opt.value)"
                      >
                        {{ opt.label }}
                      </button>
                    </div>
                  </div>
                </section>
              </template>

              <!-- 模型与 API -->
              <template v-if="activeTab === 'models'">
                <section class="setting-section">
                  <div class="section-header">
                    <h3>已保存的模型</h3>
                    <button class="action-btn primary" @click="startAdd">添加模型</button>
                  </div>

                  <p v-if="profiles.length === 0" class="setting-hint">暂无模型配置，请点击“添加模型”。</p>

                  <div
                    v-for="profile in profiles"
                    :key="profile.id"
                    class="profile-card"
                    :class="{ active: profile.id === activeProfileId }"
                  >
                    <div class="profile-row">
                      <span class="profile-name">{{ profile.name }}</span>
                      <span class="profile-backend">{{ backendLabel(profile.backend) }}</span>
                      <span
                        class="status-dot"
                        :class="isInstalled(profile.backend) ? 'ok' : 'warn'"
                      />
                      <button class="icon-btn" @click="startEdit(profile)">编辑</button>
                      <button class="icon-btn danger" @click="deleteProfile(profile.id)">删除</button>
                    </div>
                    <p v-if="profile.installHint" class="profile-hint">{{ profile.installHint }}</p>
                  </div>
                </section>

                <section v-if="editingProfile" class="setting-section">
                  <h3>{{ editingProfile.id ? "编辑模型" : "添加模型" }}</h3>

                  <div class="field mini">
                    <label>名称</label>
                    <input v-model="editingProfile.name" />
                  </div>

                  <div class="field mini">
                    <label>类型</label>
                    <select v-model="editingProfile.backend" class="setting-select">
                      <option v-for="opt in backendTypes" :key="opt.value" :value="opt.value">
                        {{ opt.label }}
                      </option>
                    </select>
                  </div>

                  <template v-if="isOnlineBackend(editingProfile.backend)">
                    <div class="field mini">
                      <label>API Key</label>
                      <input v-model="editingProfile.apiKey" type="password" />
                    </div>
                    <div class="field mini">
                      <label>API Base URL</label>
                      <input v-model="editingProfile.apiBase" />
                    </div>
                    <div class="field mini">
                      <label>模型名称</label>
                      <input v-model="editingProfile.modelName" />
                    </div>
                  </template>

                  <template v-if="editingProfile.backend === 'WhisperCpp'">
                    <div class="field mini">
                      <label>whisper-cli 路径</label>
                      <input v-model="editingProfile.whisperCppPath" />
                    </div>
                    <div class="field mini">
                      <label>模型路径</label>
                      <input v-model="editingProfile.whisperModelPath" />
                    </div>
                  </template>

                  <div class="field mini">
                    <label>安装 / 接入说明</label>
                    <textarea v-model="editingProfile.installHint" rows="3" />
                  </div>

                  <div v-if="editingProfile.backend === 'MlxQwen3'" class="warmup-block">
                    <button class="action-btn" @click="$emit('warmup')">预加载 / 下载模型</button>
                    <div v-if="warmupStatus" class="warmup-msg" :class="warmupStatus.status">
                      {{ warmupStatus.message }}
                    </div>
                  </div>

                  <div class="form-actions">
                    <button class="action-btn primary" @click="saveProfile">保存</button>
                    <button class="action-btn" @click="editingProfile = null">取消</button>
                  </div>
                </section>
              </template>

              <!-- 自动保存 -->
              <template v-if="activeTab === 'autosave'">
                <section class="setting-section">
                  <h3>自动保存</h3>
                  <div class="setting-row">
                    <span class="setting-label">保存间隔</span>
                    <select
                      :value="local.autoSaveInterval"
                      class="setting-select"
                      @change="update('autoSaveInterval', Number(($event.target as HTMLSelectElement).value) as AutoSaveInterval)"
                    >
                      <option v-for="opt in intervalOptions" :key="opt.value" :value="opt.value">
                        {{ opt.label }}
                      </option>
                    </select>
                  </div>
                  <div class="setting-row">
                    <span class="setting-label">保存格式</span>
                    <div class="segmented">
                      <button
                        v-for="opt in formatOptions"
                        :key="opt.value"
                        class="segment"
                        :class="{ active: local.autoSaveFormat === opt.value }"
                        @click="update('autoSaveFormat', opt.value)"
                      >
                        {{ opt.label }}
                      </button>
                    </div>
                  </div>
                  <p class="setting-hint">
                    自动保存路径：~/Music/hark-asr/auto-save/
                  </p>
                </section>
              </template>
            </div>
          </div>
        </Transition>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.settings-overlay {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.25);
  backdrop-filter: blur(2px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 100;
}

.settings-modal {
  width: 460px;
  max-width: calc(100vw - 32px);
  max-height: calc(100vh - 64px);
  overflow: hidden;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  display: flex;
  flex-direction: column;
}

.settings-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 16px 20px;
  border-bottom: 1px solid var(--border);
}

.settings-header h2 {
  margin: 0;
  font-size: 16px;
  font-weight: 600;
}

.close-btn {
  width: 28px;
  height: 28px;
  border-radius: var(--radius-sm);
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-secondary);
  background: transparent;
  border: 1px solid var(--border);
  font-size: 14px;
}

.close-btn:hover {
  color: var(--text-primary);
  border-color: var(--text-tertiary);
}

.settings-tabs {
  display: flex;
  padding: 0 20px;
  border-bottom: 1px solid var(--border);
  gap: 4px;
}

.settings-tabs .tab {
  padding: 10px 12px;
  font-size: 13px;
  font-weight: 500;
  color: var(--text-secondary);
  background: transparent;
  border: none;
  border-bottom: 2px solid transparent;
  margin-bottom: -1px;
}

.settings-tabs .tab:hover {
  color: var(--text-primary);
}

.settings-tabs .tab.active {
  color: var(--accent);
  border-bottom-color: var(--accent);
}

.settings-body {
  padding: 16px 20px 20px;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 20px;
}

.setting-section h3 {
  margin: 0 0 12px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.section-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 12px;
}

.section-header h3 {
  margin: 0;
}

.profile-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 10px 12px;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: var(--surface-hover);
}

.profile-card.active {
  border-color: var(--accent);
  background: var(--accent-soft);
}

.profile-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.profile-name {
  flex: 1;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-primary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.profile-backend {
  font-size: 11px;
  color: var(--text-tertiary);
}

.profile-hint {
  margin: 0;
  font-size: 11px;
  color: var(--text-secondary);
  white-space: pre-wrap;
  line-height: 1.4;
}

.status-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  flex-shrink: 0;
}

.status-dot.ok {
  background: var(--success);
}

.status-dot.warn {
  background: var(--warning);
}

.icon-btn {
  padding: 4px 8px;
  border-radius: 6px;
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-secondary);
  font-size: 11px;
  font-weight: 500;
}

.icon-btn:hover {
  color: var(--text-primary);
  border-color: var(--text-tertiary);
}

.icon-btn.danger:hover {
  color: var(--danger);
  border-color: var(--danger);
}

.setting-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  min-height: 32px;
}

.setting-label {
  font-size: 13px;
  color: var(--text-primary);
}

.segmented {
  display: flex;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  overflow: hidden;
}

.segment {
  padding: 5px 12px;
  font-size: 12px;
  font-weight: 500;
  color: var(--text-secondary);
  background: transparent;
  border: none;
  border-right: 1px solid var(--border);
}

.segment:last-child {
  border-right: none;
}

.segment.active {
  background: var(--accent);
  color: #fff;
}

.setting-select {
  padding: 5px 10px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--text-primary);
  font-size: 12px;
  min-width: 120px;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.field.mini label {
  font-size: 11px;
  font-weight: 500;
  color: var(--text-secondary);
}

.field.mini input,
.field.mini textarea,
.field.mini select {
  padding: 8px 10px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--text-primary);
  font-size: 12px;
  resize: vertical;
}

.field.mini input:focus,
.field.mini textarea:focus,
.field.mini select:focus {
  border-color: var(--text-tertiary);
}

.action-btn {
  align-self: flex-start;
  padding: 7px 12px;
  border-radius: var(--radius-sm);
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-size: 12px;
  font-weight: 500;
}

.action-btn:hover {
  background: var(--bg);
}

.action-btn.primary {
  background: var(--accent);
  border-color: var(--accent);
  color: #fff;
}

.action-btn.primary:hover {
  background: var(--accent-hover);
}

.form-actions {
  display: flex;
  gap: 8px;
  margin-top: 4px;
}

.install-hint {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.install-hint p {
  margin: 0;
  font-size: 10px;
  color: var(--text-secondary);
  white-space: pre-wrap;
  line-height: 1.5;
}

.copy-btn {
  align-self: flex-start;
  padding: 5px 8px;
  border-radius: 6px;
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-size: 11px;
  font-weight: 500;
}

.copy-btn:hover {
  background: var(--bg);
}

.warmup-block {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.warmup-msg {
  font-size: 10px;
  line-height: 1.4;
}

.warmup-msg.downloading {
  color: var(--text-secondary);
}

.warmup-msg.ready {
  color: var(--success);
}

.warmup-msg.error {
  color: var(--danger);
}

.setting-hint {
  margin: 0;
  font-size: 11px;
  color: var(--text-tertiary);
}

.overlay-enter-active,
.overlay-leave-active {
  transition: opacity 0.2s ease;
}

.overlay-enter-from,
.overlay-leave-to {
  opacity: 0;
}

.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
  transform: translateY(8px) scale(0.98);
}
</style>
