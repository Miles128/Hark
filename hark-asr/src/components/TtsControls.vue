<script setup lang="ts">
import { ref, computed, watch, onMounted } from "vue";
import { invoke } from "@tauri-apps/api/core";
import { save } from "@tauri-apps/plugin-dialog";
import { markdownToSpeech } from "../utils/markdownPlain";
import type {
  TtsBackend,
  TtsBackendStatus,
  TtsConfig,
  TtsVoice,
  SynthesizeResult,
} from "../types/tts";

const props = defineProps<{
  dashscopeApiKey: string;
  text: string;
}>();

const backend = ref<TtsBackend>("Edge");
const voice = ref("zh-CN-XiaoxiaoNeural");
const ratePercent = ref(0);
const voiceQuery = ref("");
const localeFilter = ref("all");
const voices = ref<TtsVoice[]>([]);
const status = ref<TtsBackendStatus[]>([]);
const busy = ref(false);
const error = ref("");
const lastPath = ref("");
const audioEl = ref<HTMLAudioElement | null>(null);

const rateStr = computed(() => {
  const n = ratePercent.value;
  return n >= 0 ? `+${n}%` : `${n}%`;
});

const locales = computed(() => {
  const set = new Set(voices.value.map((v) => v.locale).filter(Boolean));
  return Array.from(set).sort();
});

const filteredVoices = computed(() => {
  const q = voiceQuery.value.trim().toLowerCase();
  return voices.value.filter((v) => {
    if (localeFilter.value !== "all" && v.locale !== localeFilter.value) return false;
    if (!q) return true;
    return (
      v.id.toLowerCase().includes(q) ||
      v.name.toLowerCase().includes(q) ||
      v.locale.toLowerCase().includes(q) ||
      v.gender.toLowerCase().includes(q)
    );
  });
});

function buildConfig(): TtsConfig {
  return {
    backend: backend.value,
    api_key: backend.value === "CosyVoice" ? props.dashscopeApiKey || null : null,
    voice: voice.value,
    rate: rateStr.value,
  };
}

async function refreshStatus() {
  try {
    status.value = await invoke("get_tts_backend_status");
  } catch {
    status.value = [];
  }
}

async function loadVoices() {
  error.value = "";
  try {
    voices.value = await invoke("list_tts_voices", { backend: backend.value });
    if (!voices.value.some((v) => v.id === voice.value)) {
      const zh = voices.value.find((v) => v.locale.startsWith("zh"));
      voice.value = zh?.id ?? voices.value[0]?.id ?? voice.value;
    }
    await invoke("set_tts_config", { config: buildConfig() });
  } catch (e) {
    voices.value = [];
    error.value = String(e);
  }
}

async function synthesizeAndPlay() {
  const raw = props.text.trim();
  if (!raw) {
    error.value = "请先粘贴或输入文字";
    return;
  }
  const text = markdownToSpeech(raw);
  if (!text) {
    error.value = "没有可朗读的正文";
    return;
  }
  if (backend.value === "CosyVoice" && !props.dashscopeApiKey) {
    error.value = "请先在设置中配置 DashScope API Key";
    return;
  }
  busy.value = true;
  error.value = "";
  try {
    const config = buildConfig();
    await invoke("set_tts_config", { config });
    const result: SynthesizeResult = await invoke("synthesize_tts", { text, config });
    lastPath.value = result.path;
    const b64: string = await invoke("read_tts_file_base64", { path: result.path });
    const url = `data:audio/mpeg;base64,${b64}`;
    if (audioEl.value) {
      audioEl.value.pause();
      audioEl.value.src = url;
      await audioEl.value.play();
    }
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
  }
}

async function exportAudio() {
  const raw = props.text.trim();
  if (!raw) {
    error.value = "请先粘贴或输入文字";
    return;
  }
  const text = markdownToSpeech(raw);
  if (!text) {
    error.value = "没有可朗读的正文";
    return;
  }
  busy.value = true;
  error.value = "";
  try {
    const config = buildConfig();
    const result: SynthesizeResult = await invoke("synthesize_tts", { text, config });
    lastPath.value = result.path;
    const dest = await save({
      defaultPath: `hark-tts-${Date.now()}.mp3`,
      filters: [{ name: "MP3", extensions: ["mp3"] }],
    });
    if (dest) {
      await invoke("copy_tts_file", { src: result.path, dest });
    }
  } catch (e) {
    error.value = String(e);
  } finally {
    busy.value = false;
  }
}

function backendOk(name: string) {
  return status.value.find((s) => s.backend === name)?.installed ?? false;
}

watch(backend, async () => {
  localeFilter.value = "all";
  voiceQuery.value = "";
  if (backend.value === "CosyVoice") {
    voice.value = "longxiaochun";
  } else {
    voice.value = "zh-CN-XiaoxiaoNeural";
  }
  await loadVoices();
});

onMounted(async () => {
  await refreshStatus();
  await loadVoices();
});
</script>

<template>
  <div class="tts-controls">
    <div class="field">
      <label>引擎</label>
      <div class="backend-row">
        <button
          class="chip"
          :class="{ active: backend === 'Edge' }"
          @click="backend = 'Edge'"
        >
          Edge TTS
          <span class="dot" :class="{ on: backendOk('Edge') }" />
        </button>
        <button
          class="chip"
          :class="{ active: backend === 'CosyVoice' }"
          @click="backend = 'CosyVoice'"
        >
          阿里云 CosyVoice
          <span class="dot" :class="{ on: backendOk('CosyVoice') }" />
        </button>
      </div>
    </div>

    <div class="field">
      <label>语速 {{ rateStr }}</label>
      <input v-model.number="ratePercent" type="range" min="-50" max="100" step="5" />
    </div>

    <div class="field">
      <label>音色</label>
      <div class="voice-filters">
        <select v-model="localeFilter" class="locale-select">
          <option value="all">全部语言</option>
          <option v-for="loc in locales" :key="loc" :value="loc">{{ loc }}</option>
        </select>
        <input
          v-model="voiceQuery"
          class="search"
          type="search"
          placeholder="搜索音色…"
        />
      </div>
      <div class="voice-list">
        <button
          v-for="v in filteredVoices"
          :key="v.id"
          class="voice-item"
          :class="{ active: voice === v.id }"
          @click="voice = v.id"
        >
          <span class="voice-name">{{ v.name }}</span>
          <span class="voice-meta">{{ v.locale }} · {{ v.gender || "—" }}</span>
        </button>
        <div v-if="filteredVoices.length === 0" class="voice-empty">无匹配音色</div>
      </div>
    </div>

    <div class="actions">
      <button class="primary-btn" :disabled="busy" @click="synthesizeAndPlay">
        {{ busy ? "合成中…" : "生成并播放" }}
      </button>
      <button class="secondary-btn" :disabled="busy" @click="exportAudio">导出音频</button>
    </div>

    <div v-if="lastPath" class="file-info">已生成 <code>{{ lastPath }}</code></div>
    <div v-if="error" class="error">{{ error }}</div>
    <audio ref="audioEl" class="hidden-audio" preload="auto" />
  </div>
</template>

<style scoped>
.tts-controls {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.field label {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
  letter-spacing: 0.3px;
}

.backend-row {
  display: flex;
  gap: 6px;
}

.chip {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  padding: 6px 8px;
  font-size: 12px;
  font-weight: 500;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  color: var(--text-secondary);
  background: transparent;
}

.chip.active {
  background: var(--accent);
  border-color: var(--accent);
  color: #fff;
}

.dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--text-tertiary);
}

.dot.on {
  background: var(--success);
}

.chip.active .dot.on {
  background: #fff;
}

input[type="range"] {
  width: 100%;
}

.voice-filters {
  display: flex;
  gap: 6px;
}

.locale-select,
.search {
  font-size: 12px;
  padding: 5px 8px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  background: var(--surface);
  color: var(--text-primary);
}

.locale-select {
  max-width: 110px;
}

.search {
  flex: 1;
  min-width: 0;
}

.voice-list {
  max-height: 180px;
  overflow-y: auto;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  background: var(--surface);
}

.voice-item {
  width: 100%;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 2px;
  padding: 7px 10px;
  border: none;
  border-bottom: 1px solid var(--border);
  background: transparent;
  text-align: left;
  color: var(--text-primary);
}

.voice-item:last-child {
  border-bottom: none;
}

.voice-item:hover {
  background: var(--surface-hover);
}

.voice-item.active {
  background: var(--accent-soft);
}

.voice-name {
  font-size: 12px;
  font-weight: 500;
}

.voice-meta {
  font-size: 10px;
  color: var(--text-tertiary);
}

.voice-empty {
  padding: 16px;
  text-align: center;
  font-size: 12px;
  color: var(--text-tertiary);
}

.actions {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.primary-btn,
.secondary-btn {
  padding: 8px 12px;
  font-size: 13px;
  font-weight: 600;
  border-radius: 999px;
}

.primary-btn {
  background: var(--accent);
  color: #fff;
}

.primary-btn:hover:not(:disabled) {
  background: var(--accent-hover);
}

.primary-btn:disabled,
.secondary-btn:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.secondary-btn {
  background: transparent;
  color: var(--text-secondary);
  border: 1px solid var(--border);
}

.secondary-btn:hover:not(:disabled) {
  color: var(--text-primary);
  border-color: var(--text-secondary);
}

.file-info {
  font-size: 11px;
  color: var(--text-secondary);
  word-break: break-all;
}

.file-info code {
  font-size: 10px;
  background: var(--surface);
  padding: 1px 4px;
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
}

.hidden-audio {
  display: none;
}
</style>
