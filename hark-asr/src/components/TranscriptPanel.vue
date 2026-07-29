<script setup lang="ts">
import { ref } from "vue";
import { save } from "@tauri-apps/plugin-dialog";
import { writeTextFile } from "@tauri-apps/plugin-fs";

export interface Segment {
  index: number;
  text: string;
  backend: string;
}

const props = defineProps<{
  segments: Segment[];
}>();

const emit = defineEmits<{
  (e: "clear"): void;
}>();

const copied = ref(false);

async function exportTxt() {
  const text = props.segments.map((s) => s.text).join("\n\n");
  const path = await save({
    defaultPath: `hark-transcript-${Date.now()}.txt`,
    filters: [{ name: "Text", extensions: ["txt"] }],
  });
  if (path) await writeTextFile(path, text);
}

async function exportMd() {
  const lines = props.segments.map((s, i) => `### 段 ${i + 1}\n\n${s.text}`);
  const text = `# Hark 转写结果\n\n${lines.join("\n\n")}`;
  const path = await save({
    defaultPath: `hark-transcript-${Date.now()}.md`,
    filters: [{ name: "Markdown", extensions: ["md"] }],
  });
  if (path) await writeTextFile(path, text);
}

async function exportJson() {
  const data = { segments: props.segments, exportedAt: new Date().toISOString() };
  const text = JSON.stringify(data, null, 2);
  const path = await save({
    defaultPath: `hark-transcript-${Date.now()}.json`,
    filters: [{ name: "JSON", extensions: ["json"] }],
  });
  if (path) await writeTextFile(path, text);
}

async function copyAll() {
  const text = props.segments.map((s) => s.text).join("\n\n");
  await navigator.clipboard.writeText(text);
  copied.value = true;
  setTimeout(() => (copied.value = false), 2000);
}
</script>

<template>
  <div class="transcript-panel">
    <div class="panel-header">
      <div class="actions">
        <template v-if="segments.length > 0">
          <button class="action-btn" @click="copyAll">
            {{ copied ? "已复制" : "复制" }}
          </button>
          <div class="export-group">
            <button class="action-btn" @click="exportTxt">TXT</button>
            <button class="action-btn" @click="exportMd">MD</button>
            <button class="action-btn" @click="exportJson">JSON</button>
          </div>
          <button class="clear-btn" @click="emit('clear')">清空</button>
        </template>
      </div>
    </div>

    <div class="content">
      <div v-if="segments.length === 0" class="empty">
        录音并转写后，文字会显示在这里
      </div>
      <div v-else class="segments">
        <p v-for="seg in segments" :key="seg.index" class="segment">
          {{ seg.text }}
        </p>
      </div>
    </div>
  </div>
</template>

<style scoped>
.transcript-panel {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
}

.panel-header {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  padding: 12px 16px;
  border-bottom: 1px solid var(--border);
  background: var(--surface);
}

.title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.count {
  font-size: 11px;
  font-weight: 500;
  color: var(--text-tertiary);
  text-transform: none;
  letter-spacing: 0;
}

.clear-btn {
  font-size: 11px;
  font-weight: 500;
  color: var(--text-secondary);
  background: transparent;
  padding: 3px 8px;
  border-radius: var(--radius-sm);
}

.clear-btn:hover {
  color: var(--danger);
}

.actions {
  display: flex;
  align-items: center;
  gap: 6px;
}

.action-btn {
  font-size: 11px;
  font-weight: 500;
  color: var(--text-secondary);
  background: transparent;
  padding: 3px 8px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
}

.action-btn:hover {
  color: var(--text-primary);
  border-color: var(--text-secondary);
}

.export-group {
  display: flex;
  gap: 0;
}

.export-group .action-btn {
  border-radius: 0;
  margin-left: -1px;
}

.export-group .action-btn:first-child {
  border-radius: var(--radius-sm) 0 0 var(--radius-sm);
  margin-left: 0;
}

.export-group .action-btn:last-child {
  border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
}

.content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 20px 24px;
  background: var(--surface);
}

.content::-webkit-scrollbar {
  width: 6px;
}

.content::-webkit-scrollbar-track {
  background: transparent;
}

.content::-webkit-scrollbar-thumb {
  background: var(--border);
  border-radius: 3px;
}

.content::-webkit-scrollbar-thumb:hover {
  background: var(--text-tertiary);
}

.empty {
  color: var(--text-tertiary);
  font-size: 13px;
  text-align: center;
  padding: 40px 0;
}

.segments {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.segment {
  margin: 0;
  font-size: 15px;
  line-height: 1.7;
  color: var(--text-primary);
}
</style>
