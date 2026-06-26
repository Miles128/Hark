<script setup lang="ts">
import { ref, computed } from "vue";

interface VideoItem {
  id: number;
  url: string;
  status: "pending" | "downloading" | "completed" | "error";
  filePath?: string;
  error?: string;
}

const emit = defineEmits<{
  (e: "transcribe", filePath: string): void;
}>();

const videos = ref<VideoItem[]>([]);
const newUrl = ref("");
const isAdding = ref(false);
const currentPage = ref(1);
const pageSize = 5;
let nextId = 1;

const totalPages = computed(() => Math.ceil(videos.value.length / pageSize));

const paginatedVideos = computed(() => {
  const start = (currentPage.value - 1) * pageSize;
  return videos.value.slice(start, start + pageSize);
});

function addVideo() {
  error.value = "";
  const trimmed = newUrl.value.trim();

  if (!trimmed) {
    error.value = "请输入视频链接";
    return;
  }

  if (!trimmed.startsWith("http://") && !trimmed.startsWith("https://")) {
    error.value = "请输入有效的 HTTP/HTTPS 链接";
    return;
  }

  const exists = videos.value.some(v => v.url === trimmed);
  if (exists) {
    error.value = "该链接已添加";
    return;
  }

  videos.value.push({
    id: nextId++,
    url: trimmed,
    status: "pending",
  });

  newUrl.value = "";
  currentPage.value = totalPages.value;
}

async function downloadVideo(video: VideoItem) {
  video.status = "downloading";
  video.error = undefined;

  try {
    const { invoke } = await import("@tauri-apps/api/core");
    const filePath: string = await invoke("download_audio_from_url", {
      url: video.url,
    });
    video.status = "completed";
    video.filePath = filePath;
  } catch (e) {
    video.status = "error";
    video.error = String(e);
  }
}

async function downloadAll() {
  const pending = videos.value.filter((v) => v.status === "pending");
  for (const video of pending) {
    await downloadVideo(video);
  }
}

function removeVideo(id: number) {
  videos.value = videos.value.filter((v) => v.id !== id);
  if (currentPage.value > totalPages.value && totalPages.value > 0) {
    currentPage.value = totalPages.value;
  }
}

function goToPage(page: number) {
  if (page >= 1 && page <= totalPages.value) {
    currentPage.value = page;
  }
}

function startTranscribe(video: VideoItem) {
  if (video.filePath) {
    emit("transcribe", video.filePath);
  }
}

const error = ref("");
</script>

<template>
  <div class="video-download-panel">
    <div class="panel-header">
      <div class="title">
        <span>网络视频转换</span>
        <span v-if="videos.length > 0" class="count">{{ videos.length }} 个视频</span>
      </div>
    </div>

    <div class="add-section">
      <div class="input-row">
        <input
          v-model="newUrl"
          type="text"
          placeholder="粘贴视频链接…"
          :disabled="isAdding"
          @keydown.enter="addVideo"
        />
        <button
          class="add-btn"
          :disabled="isAdding || !newUrl.trim()"
          @click="addVideo"
        >
          添加
        </button>
      </div>
      <p class="hint">支持 YouTube、Bilibili 等主流视频网站，使用 yt-dlp 提取音频</p>
      <div v-if="error" class="error">{{ error }}</div>
    </div>

    <div v-if="videos.length > 0" class="actions-bar">
      <button
        class="download-all-btn"
        :disabled="videos.every(v => v.status !== 'pending')"
        @click="downloadAll"
      >
        全部下载
      </button>
    </div>

    <div class="content">
      <div v-if="videos.length === 0" class="empty">
        添加视频链接后，会显示在这里
      </div>
      <div v-else class="video-list">
        <div
          v-for="video in paginatedVideos"
          :key="video.id"
          class="video-item"
          :class="video.status"
        >
          <div class="video-info">
            <div class="video-url">{{ video.url }}</div>
          </div>
          <div class="video-actions">
            <div v-if="video.status === 'pending'" class="status-badge pending">
              等待下载
            </div>
            <div v-else-if="video.status === 'downloading'" class="status-badge downloading">
              <span class="spinner-small" />
              下载中...
            </div>
            <div v-else-if="video.status === 'completed'" class="status-badge completed">
              ✓ 完成
            </div>
            <div v-else-if="video.status === 'error'" class="status-badge error-badge">
              ✗ 失败
            </div>

            <button
              v-if="video.status === 'pending'"
              class="action-btn download"
              @click="downloadVideo(video)"
            >
              下载
            </button>
            <button
              v-if="video.status === 'completed'"
              class="action-btn transcribe"
              @click="startTranscribe(video)"
            >
              转写
            </button>
            <button
              v-if="video.status === 'error'"
              class="action-btn retry"
              @click="downloadVideo(video)"
            >
              重试
            </button>
            <button
              class="action-btn remove"
              @click="removeVideo(video.id)"
            >
              移除
            </button>
          </div>
          <div v-if="video.error" class="video-error">{{ video.error }}</div>
        </div>
      </div>
    </div>

    <div v-if="totalPages > 1" class="pagination">
      <button
        class="page-btn"
        :disabled="currentPage === 1"
        @click="goToPage(currentPage - 1)"
      >
        ‹
      </button>
      <span class="page-info">{{ currentPage }} / {{ totalPages }}</span>
      <button
        class="page-btn"
        :disabled="currentPage === totalPages"
        @click="goToPage(currentPage + 1)"
      >
        ›
      </button>
    </div>
  </div>
</template>

<style scoped>
.video-download-panel {
  display: flex;
  flex-direction: column;
  gap: 16px;
  height: 100%;
}

.panel-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
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

.add-section {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.input-row {
  display: flex;
  gap: 8px;
}

.input-row input {
  flex: 1;
  padding: 10px 12px;
  border-radius: var(--radius-sm);
  border: 1.5px solid var(--border);
  background: var(--surface);
  color: var(--text-primary);
  font-size: 13px;
  transition: var(--transition);
  min-width: 0;
}

.input-row input:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 3px var(--accent-soft);
}

.input-row input::placeholder {
  color: var(--text-tertiary);
}

.input-row input:disabled {
  opacity: 0.5;
}

.add-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 10px 18px;
  border-radius: var(--radius-sm);
  background: var(--accent);
  color: white;
  font-size: 13px;
  font-weight: 600;
  white-space: nowrap;
  flex-shrink: 0;
  min-width: 56px;
}

.add-btn:hover:not(:disabled) {
  background: var(--accent-hover);
}

.add-btn:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}

.hint {
  font-size: 11px;
  color: var(--text-tertiary);
  margin: 0;
  line-height: 1.4;
}

.error {
  font-size: 12px;
  color: var(--danger);
  background: rgba(255, 59, 48, 0.08);
  border: 1px solid rgba(255, 59, 48, 0.15);
  border-radius: var(--radius-sm);
  padding: 8px 10px;
  white-space: pre-wrap;
  word-break: break-all;
}

.actions-bar {
  display: flex;
  justify-content: flex-end;
}

.download-all-btn {
  padding: 8px 16px;
  border-radius: var(--radius-sm);
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-size: 12px;
  font-weight: 500;
}

.download-all-btn:hover:not(:disabled) {
  background: var(--surface-hover);
}

.download-all-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.content {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 16px;
  border-radius: var(--radius-md);
  background: var(--surface);
  border: 1.5px solid var(--border);
}

.empty {
  color: var(--text-tertiary);
  font-size: 13px;
  text-align: center;
  padding: 40px 0;
}

.video-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.video-item {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px;
  border-radius: var(--radius-sm);
  background: var(--surface-hover);
  border: 1px solid var(--border);
}

.video-info {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.video-url {
  font-size: 13px;
  color: var(--text-primary);
  word-break: break-all;
}

.video-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}

.status-badge {
  font-size: 10px;
  font-weight: 600;
  padding: 3px 8px;
  border-radius: 4px;
  display: flex;
  align-items: center;
  gap: 4px;
}

.status-badge.pending {
  background: rgba(255, 149, 0, 0.12);
  color: var(--warning);
}

.status-badge.downloading {
  background: rgba(0, 113, 227, 0.12);
  color: var(--accent);
}

.status-badge.completed {
  background: rgba(52, 199, 89, 0.12);
  color: var(--success);
}

.status-badge.error-badge {
  background: rgba(255, 59, 48, 0.12);
  color: var(--danger);
}

.spinner-small {
  width: 10px;
  height: 10px;
  border: 1.5px solid rgba(0, 113, 227, 0.3);
  border-top-color: var(--accent);
  border-radius: 50%;
  animation: spin 0.6s linear infinite;
}

@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

.action-btn {
  padding: 5px 10px;
  border-radius: 6px;
  font-size: 11px;
  font-weight: 500;
}

.action-btn.download {
  background: var(--accent);
  color: white;
}

.action-btn.download:hover {
  background: var(--accent-hover);
}

.action-btn.transcribe {
  background: var(--success);
  color: white;
}

.action-btn.transcribe:hover {
  background: #2db84e;
}

.action-btn.retry {
  background: var(--warning);
  color: white;
}

.action-btn.retry:hover {
  background: #e68600;
}

.action-btn.remove {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-secondary);
}

.action-btn.remove:hover {
  color: var(--danger);
  border-color: rgba(255, 59, 48, 0.3);
  background: rgba(255, 59, 48, 0.08);
}

.video-error {
  font-size: 11px;
  color: var(--danger);
  word-break: break-word;
}

.pagination {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  padding: 8px 0;
}

.page-btn {
  width: 28px;
  height: 28px;
  border-radius: 6px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-size: 14px;
}

.page-btn:hover:not(:disabled) {
  background: var(--surface-hover);
}

.page-btn:disabled {
  opacity: 0.3;
  cursor: not-allowed;
}

.page-info {
  font-size: 12px;
  color: var(--text-secondary);
  font-variant-numeric: tabular-nums;
}
</style>
