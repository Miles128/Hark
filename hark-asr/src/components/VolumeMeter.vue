<script setup lang="ts">
import { computed } from "vue";

const props = defineProps<{
  db: number;
  level: number;
  isRecording: boolean;
}>();

const bars = 24;

const activeBars = computed(() => {
  return Math.ceil(props.level * bars);
});

const dbText = computed(() => {
  if (!props.isRecording) return "--";
  return `${props.db.toFixed(1)} dB`;
});
</script>

<template>
  <div class="volume-meter" :class="{ recording: isRecording }">
    <div class="meter-header">
      <span class="label">输入音量</span>
      <span class="value">{{ dbText }}</span>
    </div>
    <div class="bars">
      <div
        v-for="i in bars"
        :key="i"
        class="bar"
        :class="{ active: i <= activeBars }"
        :style="{ opacity: i <= activeBars ? 1 : 0.15 }"
      />
    </div>
  </div>
</template>

<style scoped>
.volume-meter {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 14px;
  border-radius: var(--radius-md);
  background: var(--surface);
  border: 1px solid var(--border);
  opacity: 0.55;
  transition: var(--transition);
}

.volume-meter.recording {
  opacity: 1;
  border-color: var(--text-tertiary);
}

.meter-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.label {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.value {
  font-size: 12px;
  font-weight: 500;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}

.bars {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 24px;
}

.bar {
  flex: 1;
  height: 100%;
  border-radius: 1px;
  background: var(--text-primary);
  opacity: 0.08;
  transition: opacity 0.04s ease;
}

.bar.active {
  opacity: 1;
}
</style>
