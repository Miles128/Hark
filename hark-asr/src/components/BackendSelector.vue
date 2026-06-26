<script setup lang="ts">
import { computed, ref, onMounted, onUnmounted } from "vue";
import type { AsrBackend, AsrProfile } from "../types/asr";

interface BackendStatus {
  backend: string;
  installed: boolean;
  hint: string;
}

const props = defineProps<{
  modelValue: string;
  profiles: AsrProfile[];
  status: BackendStatus[];
}>();

const emit = defineEmits<{
  (e: "update:modelValue", value: string): void;
}>();

const selectedId = computed({
  get: () => props.modelValue,
  set: (v) => emit("update:modelValue", v),
});

const current = computed(() =>
  props.profiles.find((p) => p.id === selectedId.value)
);

const open = ref(false);
const dropdownRef = ref<HTMLElement | null>(null);

const backendMeta: Record<
  AsrBackend,
  { label: string; color: string; icon: string }
> = {
  MlxQwen3: {
    label: "mlx-qwen3-asr",
    color: "var(--accent)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L2 7l10 5 10-5-10-5z"/><path d="M2 17l10 5 10-5"/><path d="M2 12l10 5 10-5"/></svg>`,
  },
  WhisperCpp: {
    label: "whisper.cpp",
    color: "var(--whisper-color)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" y1="19" x2="12" y2="22"/><line x1="8" y1="22" x2="16" y2="22"/></svg>`,
  },
  DashScope: {
    label: "DashScope",
    color: "var(--dashscope-color)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>`,
  },
  OpenAiWhisper: {
    label: "OpenAI Whisper",
    color: "var(--openai-color)",
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-6.219-8.56"/><path d="M12 7v5l3 3"/></svg>`,
  },
};

function meta(backend: AsrBackend) {
  return backendMeta[backend] ?? backendMeta.MlxQwen3;
}

function isInstalled(backend: string) {
  return props.status.find((s) => s.backend === backend)?.installed ?? false;
}

function select(id: string) {
  selectedId.value = id;
  open.value = false;
}

function onClickOutside(e: MouseEvent) {
  if (dropdownRef.value && !dropdownRef.value.contains(e.target as Node)) {
    open.value = false;
  }
}

onMounted(() => window.addEventListener("click", onClickOutside));
onUnmounted(() => window.removeEventListener("click", onClickOutside));
</script>

<template>
  <div class="backend-selector">
    <div class="row">
      <label class="section-label">转写模型</label>
      <span
        v-if="current"
        class="status-dot"
        :class="isInstalled(current.backend) ? 'ok' : 'warn'"
      />
    </div>

    <div ref="dropdownRef" class="dropdown">
      <button class="trigger" @click.stop="open = !open" :disabled="profiles.length === 0">
        <template v-if="current">
          <span class="icon" :style="{ color: meta(current.backend).color }" v-html="meta(current.backend).icon" />
          <span class="trigger-label">{{ current.name }}</span>
          <span class="trigger-backend">{{ meta(current.backend).label }}</span>
        </template>
        <template v-else>
          <span class="trigger-label empty">未配置模型</span>
        </template>
        <span class="chevron" :class="{ open }">›</span>
      </button>

      <Transition name="menu">
        <div v-if="open && profiles.length > 0" class="menu">
          <button
            v-for="profile in profiles"
            :key="profile.id"
            class="item"
            :class="{ active: selectedId === profile.id }"
            @click.stop="select(profile.id)"
          >
            <span class="icon" :style="{ color: meta(profile.backend).color }" v-html="meta(profile.backend).icon" />
            <span class="item-label">{{ profile.name }}</span>
            <span class="item-backend">{{ meta(profile.backend).label }}</span>
          </button>
        </div>
      </Transition>
    </div>
  </div>
</template>

<style scoped>
.backend-selector {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.row {
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.section-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.status-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
}

.status-dot.ok {
  background: var(--success);
}

.status-dot.warn {
  background: var(--warning);
}

.dropdown {
  position: relative;
}

.trigger {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 9px 12px;
  border-radius: var(--radius-md);
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-size: 13px;
  font-weight: 600;
  text-align: left;
}

.trigger:hover:not(:disabled) {
  border-color: var(--text-tertiary);
}

.trigger:disabled {
  cursor: not-allowed;
  opacity: 0.6;
}

.trigger .icon {
  width: 18px;
  height: 18px;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
}

.trigger .icon :deep(svg) {
  width: 100%;
  height: 100%;
}

.trigger-label {
  flex: 1;
}

.trigger-label.empty {
  color: var(--text-tertiary);
  font-weight: 500;
}

.trigger-backend,
.item-backend {
  font-size: 11px;
  font-weight: 500;
  color: var(--text-tertiary);
}

.chevron {
  font-size: 14px;
  color: var(--text-secondary);
  transform: rotate(90deg);
  transition: transform 0.2s ease;
}

.chevron.open {
  transform: rotate(-90deg);
}

.menu {
  position: absolute;
  top: calc(100% + 6px);
  left: 0;
  right: 0;
  display: flex;
  flex-direction: column;
  gap: 0;
  padding: 4px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-md);
  z-index: 20;
}

.menu-enter-active,
.menu-leave-active {
  transition: opacity 0.15s ease, transform 0.15s ease;
}

.menu-enter-from,
.menu-leave-to {
  opacity: 0;
  transform: translateY(-4px);
}

.item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px;
  border-radius: var(--radius-sm);
  background: transparent;
  border: none;
  color: var(--text-primary);
  font-size: 13px;
  text-align: left;
}

.item:hover {
  background: var(--surface-hover);
}

.item.active {
  background: var(--accent-soft);
  color: var(--accent);
}

.item .icon {
  width: 16px;
  height: 16px;
  flex-shrink: 0;
  display: flex;
  align-items: center;
  justify-content: center;
}

.item .icon :deep(svg) {
  width: 100%;
  height: 100%;
}

.item-label {
  flex: 1;
}
</style>
