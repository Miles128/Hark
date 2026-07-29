<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch, computed } from "vue";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { applyTheme } from "./utils/theme";
import SourceSelector, { type AudioSource } from "./components/SourceSelector.vue";
import BackendSelector from "./components/BackendSelector.vue";
import VolumeMeter from "./components/VolumeMeter.vue";
import VideoDownloadPanel from "./components/VideoDownloadPanel.vue";
import TranscriptPanel, { type Segment } from "./components/TranscriptPanel.vue";
import TtsControls from "./components/TtsControls.vue";
import TtsPanel from "./components/TtsPanel.vue";
import SettingsModal, { type AppSettings } from "./components/SettingsModal.vue";
import type { AsrBackend, AsrProfile } from "./types/asr";

type AppMode = "asr" | "tts";
type TabType = "recording" | "video";

interface VolumeEvent {
  db: number;
  level: number;
}

interface AudioDeviceInfo {
  name: string;
  is_input: boolean;
  index: number;
}

interface AsrConfig {
  backend: AsrBackend;
  api_key: string | null;
  api_base: string | null;
  whisper_cpp_path: string | null;
  whisper_model_path: string | null;
  model_name: string | null;
  language: string | null;
}

interface BackendStatus {
  backend: string;
  installed: boolean;
  hint: string;
}

interface WarmupEvent {
  status: string;
  message: string;
}

const activeMode = ref<AppMode>("asr");
const activeTab = ref<TabType>("recording");
const source = ref<AudioSource>("microphone");
const micDevice = ref<string>("");
const systemDevice = ref<string>("");
const hasBlackhole = ref(false);
const devices = ref<AudioDeviceInfo[]>([]);
const backendStatus = ref<BackendStatus[]>([]);
const sidebarCollapsed = ref(false);
const ttsText = ref("");

const profiles = ref<AsrProfile[]>([]);
const selectedProfileId = ref<string>("");
const activeProfile = computed(() =>
  profiles.value.find((p) => p.id === selectedProfileId.value)
);

const dashscopeApiKey = computed(() => {
  const fromActive =
    activeProfile.value?.backend === "DashScope" ? activeProfile.value.apiKey : "";
  if (fromActive) return fromActive;
  const any = profiles.value.find((p) => p.backend === "DashScope" && p.apiKey);
  return any?.apiKey ?? "";
});

const isRecording = ref(false);
const liveTranscribe = ref(false);
const volume = ref<VolumeEvent>({ db: -60, level: 0 });
const segments = ref<Segment[]>([]);
const recordedFile = ref("");
const error = ref("");
const isTranscribing = ref(false);
const warmupStatus = ref<WarmupEvent | null>(null);
const settingsOpen = ref(false);
const appSettings = ref<AppSettings>({
  theme: "system",
  autoSaveInterval: 60,
  autoSaveFormat: "txt",
  activeProfileId: "",
});

let unlistenVolume: UnlistenFn | null = null;
let unlistenSegment: UnlistenFn | null = null;
let unlistenWarmup: UnlistenFn | null = null;

function buildAsrConfig(profile: AsrProfile): AsrConfig {
  return {
    backend: profile.backend,
    api_key:
      profile.backend === "DashScope"
        ? profile.apiKey || null
        : profile.backend === "OpenAiWhisper"
        ? profile.apiKey || null
        : null,
    api_base: profile.backend === "OpenAiWhisper" ? profile.apiBase || null : null,
    whisper_cpp_path: profile.backend === "WhisperCpp" ? profile.whisperCppPath || null : null,
    whisper_model_path: profile.backend === "WhisperCpp" ? profile.whisperModelPath || null : null,
    model_name:
      profile.backend === "OpenAiWhisper"
        ? profile.modelName || null
        : profile.backend === "DashScope"
        ? profile.modelName || null
        : null,
    language: "zh",
  };
}

async function syncAsrConfig() {
  const p = activeProfile.value;
  if (!p) {
    backendStatus.value = [];
    return;
  }
  try {
    await invoke("set_asr_config", { config: buildAsrConfig(p) });
    backendStatus.value = await invoke("get_asr_backend_status");
  } catch {
    // ignore
  }
}

async function loadProfiles() {
  try {
    const list: AsrProfile[] = await invoke("get_asr_profiles");
    profiles.value = list;
  } catch {
    profiles.value = [];
  }
}

watch(
  appSettings,
  async (settings) => {
    applyTheme(settings.theme);
    try {
      await invoke("set_app_settings", { settings });
    } catch {
      // ignore
    }
    await syncAsrConfig();
  },
  { deep: true }
);

watch(selectedProfileId, () => {
  appSettings.value.activeProfileId = selectedProfileId.value;
});

onMounted(async () => {
  devices.value = await invoke("list_devices");
  hasBlackhole.value = await invoke("has_blackhole");

  await loadProfiles();

  // 加载应用设置
  try {
    const savedSettings: AppSettings = await invoke("get_app_settings");
    appSettings.value = savedSettings;
    applyTheme(savedSettings.theme);
  } catch {
    // 使用默认设置
  }

  // 选中上次使用的模型，或第一个可用模型
  if (appSettings.value.activeProfileId) {
    const exists = profiles.value.some((p) => p.id === appSettings.value.activeProfileId);
    selectedProfileId.value = exists ? appSettings.value.activeProfileId : (profiles.value[0]?.id ?? "");
  } else {
    selectedProfileId.value = profiles.value[0]?.id ?? "";
  }

  await syncAsrConfig();

  // 默认优先选择本机自带麦克风，其次按名称匹配麦克风
  const builtInMic = devices.value.find((d) =>
    /macbook|built-in/i.test(d.name)
  );
  const anyMic = devices.value.find((d) =>
    /microphone|麦克风/i.test(d.name)
  );
  const defaultMic = builtInMic || anyMic;
  if (defaultMic) {
    micDevice.value = defaultMic.name;
  }

  const history: Segment[] = await invoke("get_transcript");
  segments.value = history;

  unlistenVolume = await listen<VolumeEvent>("audio:volume", (e) => {
    volume.value = e.payload;
  });

  unlistenSegment = await listen<Segment>("asr:segment", (e) => {
    segments.value.push(e.payload);
  });

  unlistenWarmup = await listen<WarmupEvent>("asr:warmup", (e) => {
    warmupStatus.value = e.payload;
  });

  if (activeProfile.value?.backend === "MlxQwen3") {
    warmupMlxModel();
  }
});

onUnmounted(() => {
  unlistenVolume?.();
  unlistenSegment?.();
  unlistenWarmup?.();
});

async function addProfile(profile: AsrProfile) {
  try {
    const added: AsrProfile = await invoke("add_asr_profile", { profile });
    await loadProfiles();
    selectedProfileId.value = added.id;
  } catch (e) {
    error.value = String(e);
  }
}

async function updateProfile(profile: AsrProfile) {
  try {
    await invoke("update_asr_profile", { profile });
    await loadProfiles();
    if (selectedProfileId.value === profile.id) {
      await syncAsrConfig();
    }
  } catch (e) {
    error.value = String(e);
  }
}

async function deleteProfile(id: string) {
  try {
    await invoke("delete_asr_profile", { id });
    await loadProfiles();
    if (selectedProfileId.value === id) {
      selectedProfileId.value = profiles.value[0]?.id ?? "";
    }
  } catch (e) {
    error.value = String(e);
  }
}

async function toggleRecording() {
  error.value = "";

  if (isRecording.value) {
    try {
      const file = await invoke<string>("stop_recording");
      recordedFile.value = file;
      isRecording.value = false;

      if (!liveTranscribe.value) {
        await transcribeSlice(file, 0);
      }
    } catch (e) {
      error.value = String(e);
      isRecording.value = false;
    }
  } else {
    try {
      segments.value = [];
      await invoke("clear_transcript");
      recordedFile.value = "";
      await invoke("start_recording", {
        source: source.value,
        micDevice: micDevice.value || null,
        systemDevice: systemDevice.value || null,
        liveTranscribe: liveTranscribe.value,
      });
      isRecording.value = true;
    } catch (e) {
      error.value = String(e);
    }
  }
}

async function transcribeSlice(path: string, index: number) {
  isTranscribing.value = true;
  try {
    await invoke("transcribe_file_cmd", { filePath: path, index });
  } catch (e) {
    error.value = String(e);
  } finally {
    isTranscribing.value = false;
  }
}

async function handleUrlTranscribe(filePath: string) {
  recordedFile.value = filePath;
  await transcribeSlice(filePath, 0);
}

async function clearTranscript() {
  segments.value = [];
  await invoke("clear_transcript");
}

async function openAudioMidiSetup() {
  await invoke("open_audio_midi_setup");
}

async function warmupMlxModel() {
  warmupStatus.value = { status: "downloading", message: "正在准备 mlx-qwen3-asr 模型（首次使用需下载）…" };
  try {
    await invoke("warmup_mlx_model");
  } catch (e) {
    warmupStatus.value = { status: "error", message: String(e) };
  }
}
</script>

<template>
  <div class="app">
    <aside class="sidebar" :class="{ collapsed: sidebarCollapsed }">
      <div class="sidebar-header" data-tauri-drag-region>
        <div class="header-spacer" />
        <div class="header-actions">
          <button class="settings-btn" @click="settingsOpen = true" title="设置">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 0 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 0 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 0 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 0 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1Z"/></svg>
          </button>
          <button class="collapse-btn" @click="sidebarCollapsed = !sidebarCollapsed">
            {{ sidebarCollapsed ? "›" : "‹" }}
          </button>
        </div>
      </div>

      <div class="sidebar-content">
        <div class="mode-switcher">
          <button
            class="mode-btn"
            :class="{ active: activeMode === 'asr' }"
            @click="activeMode = 'asr'"
          >
            ASR
          </button>
          <button
            class="mode-btn"
            :class="{ active: activeMode === 'tts' }"
            @click="activeMode = 'tts'"
          >
            TTS
          </button>
        </div>

        <template v-if="activeMode === 'asr'">
          <div class="tab-switcher">
            <button
              class="tab-btn"
              :class="{ active: activeTab === 'recording' }"
              @click="activeTab = 'recording'"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="22"/><line x1="8" y1="22" x2="16" y2="22"/></svg>
              <span>录音</span>
            </button>
            <button
              class="tab-btn"
              :class="{ active: activeTab === 'video' }"
              @click="activeTab = 'video'"
            >
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="20" height="20" rx="2.18" ry="2.18"/><line x1="7" y1="2" x2="7" y2="22"/><line x1="17" y1="2" x2="17" y2="22"/><line x1="2" y1="12" x2="22" y2="12"/><line x1="2" y1="7" x2="7" y2="7"/><line x1="2" y1="17" x2="7" y2="17"/><line x1="17" y1="17" x2="22" y2="17"/><line x1="17" y1="7" x2="22" y2="7"/></svg>
              <span>视频</span>
            </button>
          </div>

          <template v-if="activeTab === 'recording'">
            <SourceSelector
              v-model="source"
              v-model:mic-device="micDevice"
              v-model:system-device="systemDevice"
              :devices="devices"
              :has-blackhole="hasBlackhole"
              @open-audio-midi="openAudioMidiSetup"
            />

            <VolumeMeter :db="volume.db" :level="volume.level" :is-recording="isRecording" />

            <BackendSelector
              v-model="selectedProfileId"
              :profiles="profiles"
              :status="backendStatus"
            />

            <div class="record-card">
              <button
                class="record-btn"
                :class="{ recording: isRecording }"
                @click="toggleRecording"
              >
                <span class="record-dot" />
                <span>{{ isRecording ? "停止" : "录音" }}</span>
              </button>

              <div class="live-switch-row" :class="{ disabled: isRecording }">
                <span class="live-switch-label">边录边转</span>
                <label class="live-switch">
                  <input v-model="liveTranscribe" type="checkbox" :disabled="isRecording" />
                  <span class="live-switch-track">
                    <span class="live-switch-thumb" />
                  </span>
                </label>
              </div>
            </div>

            <div v-if="isTranscribing" class="status">
              正在转写…<br /><small>本地模型首次加载较慢，请稍等</small>
            </div>
            <div v-if="recordedFile && !isRecording && !liveTranscribe" class="file-info">
              已保存 <code>{{ recordedFile }}</code>
            </div>
            <div v-if="error" class="error">{{ error }}</div>
          </template>

          <template v-else>
            <VideoDownloadPanel @transcribe="handleUrlTranscribe" />
          </template>
        </template>

        <template v-else>
          <TtsControls :text="ttsText" :dashscope-api-key="dashscopeApiKey" />
        </template>
      </div>
    </aside>

    <main class="main">
      <TranscriptPanel v-if="activeMode === 'asr'" :segments="segments" @clear="clearTranscript" />
      <TtsPanel v-else v-model="ttsText" />
    </main>
  </div>

  <SettingsModal
    v-model="settingsOpen"
    v-model:settings="appSettings"
    :profiles="profiles"
    :active-profile-id="selectedProfileId"
    :status="backendStatus"
    :warmup-status="warmupStatus"
    @add-profile="addProfile"
    @update-profile="updateProfile"
    @delete-profile="deleteProfile"
    @warmup="warmupMlxModel"
  />
</template>

<style scoped>
.app {
  display: flex;
  width: 100vw;
  height: 100vh;
  overflow: hidden;
  background: var(--bg);
}

.sidebar {
  width: var(--sidebar-width);
  flex-shrink: 0;
  display: flex;
  flex-direction: column;
  background: var(--surface);
  border-right: 1px solid var(--border);
  transition: width 0.3s ease;
  z-index: 10;
}

.sidebar.collapsed {
  width: var(--sidebar-collapsed);
}

.sidebar-header {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  padding: 10px 12px 8px;
  -webkit-app-region: drag;
  app-region: drag;
}

.header-spacer {
  flex: 1;
}

.header-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  -webkit-app-region: no-drag;
  app-region: no-drag;
}

.settings-btn,
.collapse-btn {
  width: 24px;
  height: 24px;
  border-radius: 6px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-secondary);
  background: var(--surface-hover);
}

.settings-btn svg,
.collapse-btn svg {
  width: 13px;
  height: 13px;
}

.settings-btn:hover,
.collapse-btn:hover {
  color: var(--text-primary);
  background: var(--border);
}

.sidebar.collapsed .collapse-btn {
  transform: rotate(180deg);
}

.sidebar-content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 6px 12px 16px;
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.sidebar.collapsed .sidebar-content {
  opacity: 0;
  pointer-events: none;
}

.main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  min-height: 0;
  overflow: hidden;
}

.mode-switcher {
  display: flex;
  gap: 0;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  overflow: hidden;
  flex-shrink: 0;
}

.mode-btn {
  flex: 1;
  padding: 6px 8px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.4px;
  color: var(--text-secondary);
  background: transparent;
  transition: var(--transition);
  border-right: 1px solid var(--border);
}

.mode-btn:last-child {
  border-right: none;
}

.mode-btn:hover:not(.active) {
  background: var(--surface-hover);
  color: var(--text-primary);
}

.mode-btn.active {
  background: var(--accent);
  color: #fff;
}

.tab-switcher {
  display: flex;
  gap: 0;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  overflow: hidden;
}

.tab-btn {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  padding: 6px 8px;
  font-size: 12px;
  font-weight: 500;
  color: var(--text-secondary);
  background: transparent;
  transition: var(--transition);
  border-right: 1px solid var(--border);
}

.tab-btn:last-child {
  border-right: none;
}

.tab-btn:hover:not(.active) {
  background: var(--surface-hover);
  color: var(--text-primary);
}

.tab-btn.active {
  background: var(--accent-soft);
  color: var(--accent);
}

.tab-btn svg {
  width: 13px;
  height: 13px;
  flex-shrink: 0;
}

.record-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 10px;
  border-radius: var(--radius-md);
  background: var(--surface);
  border: 1px solid var(--border);
  flex-shrink: 0;
}

.record-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 8px 14px;
  border-radius: 999px;
  background: var(--accent);
  color: #fff;
  font-size: 13px;
  font-weight: 600;
  letter-spacing: 0.2px;
}

.record-btn:hover {
  background: var(--accent-hover);
}

.record-btn.recording {
  background: var(--danger);
  animation: pulse 1.5s ease-in-out infinite;
}

.record-btn.recording:hover {
  background: var(--danger-hover);
}

@keyframes pulse {
  0%, 100% {
    opacity: 1;
  }
  50% {
    opacity: 0.8;
  }
}

.record-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: currentColor;
}

.record-btn.recording .record-dot {
  border-radius: 2px;
}

.live-switch-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 6px 8px;
  border-radius: var(--radius-sm);
  background: transparent;
  border: 1px dashed var(--border);
  color: var(--text-secondary);
  font-size: 12px;
  font-weight: 500;
  cursor: default;
  transition: var(--transition);
}

.live-switch-row:hover:not(.disabled) {
  border-color: var(--text-secondary);
}

.live-switch-row.disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.live-switch-label {
  color: var(--text-primary);
}

.live-switch {
  position: relative;
  display: inline-block;
  width: 36px;
  height: 20px;
  cursor: pointer;
}

.live-switch input {
  position: absolute;
  opacity: 0;
  width: 0;
  height: 0;
}

.live-switch-track {
  position: absolute;
  inset: 0;
  border-radius: 999px;
  background: var(--surface-hover);
  border: 1px solid var(--border);
  transition: var(--transition);
}

.live-switch-thumb {
  position: absolute;
  top: 1px;
  left: 1px;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: var(--surface);
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.15);
  transition: var(--transition);
}

.live-switch input:checked + .live-switch-track {
  background: var(--accent);
  border-color: var(--accent);
}

.live-switch input:checked + .live-switch-track .live-switch-thumb {
  transform: translateX(16px);
  background: #fff;
}

.live-switch input:disabled + .live-switch-track {
  opacity: 0.6;
  cursor: not-allowed;
}

.status {
  font-size: 12px;
  color: var(--text-secondary);
  text-align: center;
  flex-shrink: 0;
}

.file-info {
  font-size: 11px;
  color: var(--text-secondary);
  word-break: break-all;
  text-align: center;
  flex-shrink: 0;
}

.file-info code {
  background: var(--surface);
  padding: 2px 6px;
  border-radius: 4px;
  border: 1px solid var(--border);
}

.error {
  font-size: 12px;
  color: var(--danger);
  background: rgba(255, 59, 48, 0.08);
  border: 1px solid rgba(255, 59, 48, 0.15);
  border-radius: var(--radius-sm);
  padding: 8px 10px;
  white-space: pre-wrap;
  flex-shrink: 0;
}
</style>
