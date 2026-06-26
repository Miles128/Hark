# Hark 听录转文字 Implementation Plan

> **For agentic workers:** Use executing-plans skill to implement task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 重构 Hark 为支持三种音源、三种 ASR 后端、实时音量、边录边转切片模式的极简设计感桌面 App。

**Architecture:** Rust 后端负责音频采集/混音/切片/ASR 调用，通过 Tauri events 向前端推送音量和转写片段；Vue 前端负责状态展示与交互，使用 frontend-skill 打造极简 UI。

**Tech Stack:** Tauri 2, Vue 3, TypeScript, Rust, cpal, hound, Python (mlx-qwen3-asr / dashscope), whisper.cpp CLI

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src-tauri/src/lib.rs` | Tauri 命令注册、状态管理、事件总线 |
| `src-tauri/src/audio.rs` | 音频设备枚举、录音、混音、切片、音量计算 |
| `src-tauri/src/asr/mod.rs` | ASR 统一接口与配置 |
| `src-tauri/src/asr/mlx_qwen3.rs` | mlx-qwen3-asr 后端 |
| `src-tauri/src/asr/whisper_cpp.rs` | whisper.cpp 后端 |
| `src-tauri/src/asr/dashscope.rs` | DashScope 云端后端 |
| `src-tauri/src/asr/faster_whisper.rs` | （已移除） |
| `src/App.vue` | 主界面与状态管理 |
| `src/components/VolumeMeter.vue` | 音量条组件 |
| `src/components/SourceSelector.vue` | 音源选择组件 |
| `src/components/BackendSelector.vue` | ASR 后端选择组件 |
| `src/components/TranscriptPanel.vue` | 转写结果展示组件 |
| `src/style.css` | 全局样式变量与基础样式 |

---

## Task 1: 重构 Rust 音频模块

**Files:**
- Modify: `src-tauri/src/audio.rs`
- Modify: `src-tauri/src/lib.rs`

- [ ] **Step 1.1: 定义录音源类型**

```rust
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum AudioSource {
    Microphone,
    SystemAudio,
    Both,
}
```

- [ ] **Step 1.2: 重构 RecordingSession 支持音量事件与切片**

录音线程除了采集原始样本，还要：
- 每 100ms 计算 RMS 并 emit `audio:volume`
- 边录边转开启时，每 5 秒保存一个切片 WAV 并 emit `audio:slice`
- 停止时保存完整 WAV

- [ ] **Step 1.3: 更新 lib.rs 命令与事件**

新增命令：
- `start_recording(source: AudioSource, live_transcribe: bool)`
- `stop_recording()`
- `list_devices()`

新增事件发射：
- `audio:volume` `{db: f32, level: f32}`
- `audio:slice` `{path: String, index: u32}`
- `asr:segment` `{text: String, index: u32}`
- `audio:error` `{message: String}`

---

## Task 2: 实现 ASR 后端模块

**Files:**
- Create: `src-tauri/src/asr/mod.rs`
- Create: `src-tauri/src/asr/mlx_qwen3.rs`
- Create: `src-tauri/src/asr/whisper_cpp.rs`
- Create: `src-tauri/src/asr/dashscope.rs`
- Modify: `src-tauri/src/lib.rs`

- [ ] **Step 2.1: 统一 ASR 接口**

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AsrBackend {
    MlxQwen3,
    WhisperCpp,
    DashScope,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AsrConfig {
    pub backend: AsrBackend,
    pub api_key: Option<String>,
    pub whisper_cpp_path: Option<String>,
    pub model_name: Option<String>,
}

pub async fn transcribe_file(path: &str, config: &AsrConfig) -> Result<String, String>;
```

- [ ] **Step 2.2: 实现 mlx-qwen3-asr 后端**

调用 Python 脚本：
```python
import mlx_qwen3_asr
result = mlx_qwen3_asr.transcribe("path.wav")
print(result["text"])
```

- [ ] **Step 2.3: 实现 whisper.cpp 后端**

调用 `whisper-cli` 子进程：
```bash
whisper-cli -m <model> -l zh -f <path.wav> --no-timestamps -otxt
```
读取输出文件或 stdout。

- [ ] **Step 2.4: 实现 DashScope 后端**

复用 `dashscope.MultiModalConversation.call`。

- [ ] **Step 2.5: 移除 faster-whisper 相关代码**

删除 `src-tauri/src/transcriber.rs`，更新引用。

---

## Task 3: 边录边转调度

**Files:**
- Modify: `src-tauri/src/lib.rs`

- [ ] **Step 3.1: 切片队列与消费者任务**

当 `live_transcribe=true`：
- 收到 `audio:slice` 事件后，把 `(path, index)` 加入队列
- Tokio 任务依次消费队列，调用 ASR，emit `asr:segment`

---

## Task 4: 前端组件与状态

**Files:**
- Create: `src/components/VolumeMeter.vue`
- Create: `src/components/SourceSelector.vue`
- Create: `src/components/BackendSelector.vue`
- Create: `src/components/TranscriptPanel.vue`
- Modify: `src/App.vue`

- [ ] **Step 4.1: SourceSelector 组件**

三个卡片选项：麦克风、外放、同时。检测 BlackHole 是否存在，不存在时显示安装提示。

- [ ] **Step 4.2: BackendSelector 组件**

下拉选择 ASR 后端。选择 DashScope 时显示 API Key 输入框。

- [ ] **Step 4.3: VolumeMeter 组件**

接收 0-1 的 level，显示渐变音量条和分贝数值。

- [ ] **Step 4.4: TranscriptPanel 组件**

按片段追加显示转写结果，支持清空。

- [ ] **Step 4.5: App.vue 状态管理**

监听 Tauri events，管理录音状态、音量、转写片段。

---

## Task 5: 使用 frontend-skill 美化界面

**Files:**
- Modify: `src/App.vue`
- Modify: `src/style.css`
- Modify: `src/components/*.vue`

- [ ] **Step 5.1: 定义设计 token**

在 `src/style.css` 中定义：
- 颜色：主色 `#396cd8`、录音红 `#ff3b30`、背景、卡片背景
- 圆角：卡片 16px，按钮 12px
- 阴影：`0 4px 24px rgba(0,0,0,0.08)`
- 过渡：`all 0.2s cubic-bezier(0.25, 0.46, 0.45, 0.94)`

- [ ] **Step 5.2: 调用 frontend-skill 生成视觉方向**

应用高端极简设计语言：大量留白、克制动效、专业排版。

---

## Task 6: 测试运行

**Files:**
- All

- [ ] **Step 6.1: cargo check**

```bash
cd src-tauri && cargo check
```

- [ ] **Step 6.2: tauri dev**

```bash
npm run tauri dev
```

- [ ] **Step 6.3: 验证功能**

- 列出音频设备
- 选择麦克风开始录音，音量条跳动
- 停止录音，文件保存成功
- 选择 mlx-qwen3-asr 转写本地文件
- 开启边录边转，验证片段追加

---

## Spec Coverage Check

- [x] 三种音源（麦克风 / 外放 / 同时）→ Task 1, 4
- [x] 实时音量 → Task 1, 4
- [x] mlx-qwen3-asr / whisper.cpp / DashScope → Task 2
- [x] 边录边转切片 → Task 1, 3
- [x] 极简设计感 UI → Task 4, 5
- [x] 去掉 faster-whisper → Task 2
