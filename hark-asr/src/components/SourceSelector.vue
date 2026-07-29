<script setup lang="ts">
import { computed } from "vue";

export type AudioSource = "microphone" | "system" | "both";

interface AudioDeviceInfo {
  name: string;
  is_input: boolean;
  index: number;
}

const props = defineProps<{
  modelValue: AudioSource;
  micDevice: string;
  systemDevice: string;
  devices: AudioDeviceInfo[];
  hasBlackhole: boolean;
}>();

const emit = defineEmits<{
  (e: "update:modelValue", value: AudioSource): void;
  (e: "update:micDevice", value: string): void;
  (e: "update:systemDevice", value: string): void;
  (e: "openAudioMidi"): void;
}>();

const selected = computed({
  get: () => props.modelValue,
  set: (v) => emit("update:modelValue", v),
});

const micModel = computed({
  get: () => props.micDevice,
  set: (v) => emit("update:micDevice", v),
});

const systemModel = computed({
  get: () => props.systemDevice,
  set: (v) => emit("update:systemDevice", v),
});

const options: {
  value: AudioSource;
  label: string;
  desc: string;
  color: string;
  soft: string;
  icon: string;
}[] = [
  {
    value: "microphone",
    label: "麦克风",
    desc: "只录人声",
    color: "var(--mic-color)",
    soft: "rgba(255, 55, 95, 0.1)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="10" r="4"/><path d="M7 10v1a5 5 0 0 0 10 0v-1"/><line x1="12" y1="15" x2="12" y2="19"/></svg>`,
  },
  {
    value: "system",
    label: "外放",
    desc: "录系统声音",
    color: "var(--system-color)",
    soft: "rgba(50, 173, 230, 0.1)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 12c0-3 2.5-5 5-5"/><path d="M12 12c0-5 4-9 9-9"/><path d="M12 12c0 3 2.5 5 5 5"/><path d="M12 12c0 5 4 9 9 9"/></svg>`,
  },
  {
    value: "both",
    label: "同时录",
    desc: "人声 + 系统声音",
    color: "var(--both-color)",
    soft: "rgba(175, 82, 222, 0.1)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="10" r="4"/><path d="M4 10v1a5 5 0 0 0 9 2"/><path d="M15 7h3l4-4v14l-4-4h-3"/></svg>`,
  },
];

const micOptions = computed(() =>
  props.devices.filter((d) => !isBlackhole(d.name))
);

const systemOptions = computed(() =>
  props.devices.filter((d) => isBlackhole(d.name))
);

function isBlackhole(name: string) {
  return ["blackhole", "soundflower", "loopback"].some((b) =>
    name.toLowerCase().includes(b)
  );
}

function needsBlackhole(value: AudioSource) {
  return value === "system" || value === "both";
}

function selectOption(value: AudioSource) {
  if (!needsBlackhole(value) || props.hasBlackhole) {
    selected.value = value;
  }
}
</script>

<template>
  <div class="source-selector">
    <label class="section-label">录音源</label>
    <div class="options">
      <button
        v-for="opt in options"
        :key="opt.value"
        class="option"
        :class="{
          active: selected === opt.value,
          disabled: needsBlackhole(opt.value) && !hasBlackhole,
        }"
        :style="{ '--opt-color': opt.color, '--opt-soft': opt.soft }"
        @click="selectOption(opt.value)"
      >
        <span class="icon" v-html="opt.icon" />
        <span class="label">{{ opt.label }}</span>
        <span class="desc">{{ opt.desc }}</span>
      </button>
    </div>

    <div v-if="selected === 'microphone' || selected === 'both'" class="field">
      <label>麦克风设备</label>
      <select v-model="micModel">
        <option value="">默认 / 自动</option>
        <option v-for="d in micOptions" :key="d.index" :value="d.name">
          {{ d.name }}
        </option>
      </select>
    </div>

    <div v-if="selected === 'system' || selected === 'both'" class="field">
      <label>系统音频设备</label>
      <select v-model="systemModel">
        <option value="">默认 / 自动</option>
        <option v-for="d in systemOptions" :key="d.index" :value="d.name">
          {{ d.name }}
        </option>
      </select>
    </div>

    <div v-if="!hasBlackhole" class="blackhole-warning">
      <p>未检测到 BlackHole。要录外放或同时录，请先安装 BlackHole，然后在「音频 MIDI 设置」里创建多输出设备。</p>
      <div class="hint-actions">
        <a href="https://github.com/ExistentialAudio/BlackHole" target="_blank">下载 BlackHole</a>
        <button @click="$emit('openAudioMidi')">打开音频 MIDI 设置</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.source-selector {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.section-label {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.4px;
}

.options {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 4px;
}

.option {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
  gap: 5px;
  padding: 6px 6px;
  border-radius: var(--radius-sm);
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-secondary);
  transition: var(--transition);
  min-height: 0;
}

.option:hover:not(.disabled) {
  border-color: var(--text-tertiary);
  color: var(--text-primary);
}

.option.active {
  border-color: var(--opt-color);
  background: var(--opt-color);
  color: #fff;
}

.option.active .icon {
  color: #fff;
}

.option.disabled {
  opacity: 0.4;
  cursor: not-allowed;
}

.icon {
  width: 16px;
  height: 16px;
  flex-shrink: 0;
  transition: var(--transition);
}

.icon :deep(svg) {
  width: 100%;
  height: 100%;
}

.label {
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0;
  line-height: 1;
}

.desc {
  display: none;
}

.field {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.field label {
  font-size: 11px;
  font-weight: 500;
  color: var(--text-secondary);
}

.field select {
  padding: 5px 8px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  background: var(--surface-hover);
  color: var(--text-primary);
  font-size: 12px;
  cursor: pointer;
}

.blackhole-warning {
  font-size: 11px;
  color: var(--text-secondary);
  background: rgba(255, 149, 0, 0.08);
  border: 1px solid rgba(255, 149, 0, 0.2);
  border-radius: var(--radius-sm);
  padding: 8px 10px;
  line-height: 1.45;
}

.blackhole-warning p {
  margin: 0;
}

.hint-actions {
  display: flex;
  gap: 6px;
  margin-top: 6px;
}

.hint-actions a,
.hint-actions button {
  font-size: 11px;
  padding: 4px 8px;
  border-radius: 6px;
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--text-primary);
  text-decoration: none;
  font-weight: 500;
  flex: 1;
  text-align: center;
}

.hint-actions a:hover,
.hint-actions button:hover {
  background: var(--surface-hover);
}

.hint-actions a {
  color: var(--accent);
}
</style>
