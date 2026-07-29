<script setup lang="ts">
const modelValue = defineModel<string>({ default: "" });
</script>

<template>
  <div class="tts-panel">
    <div class="panel-header">
      <span class="hint">可粘贴 Markdown；朗读时不念格式符，按标题/段落/列表自动停顿</span>
      <span class="count">{{ modelValue.length }} 字</span>
    </div>
    <textarea
      v-model="modelValue"
      class="editor"
      placeholder="在此粘贴或输入要朗读的文字…"
    />
  </div>
</template>

<style scoped>
.tts-panel {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
}

.panel-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 10px 16px;
  border-bottom: 1px solid var(--border);
  background: var(--surface);
}

.hint {
  font-size: 12px;
  color: var(--text-secondary);
}

.count {
  font-size: 11px;
  color: var(--text-tertiary);
}

.editor {
  flex: 1;
  min-height: 0;
  width: 100%;
  border: none;
  resize: none;
  padding: 20px 24px;
  font-size: 15px;
  line-height: 1.7;
  font-family: var(--font-stack);
  color: var(--text-primary);
  background: var(--surface);
  outline: none;
}

.editor::placeholder {
  color: var(--text-tertiary);
}
</style>
