# Hark SwiftUI 迁移方案（spec）

> 状态：草案 v1（2026-09-12）。Tauri 版（hark-asr/）保留作参考与回退，迁移验收以它为基准。

## 1. 现状盘点

- 技术栈：Tauri 2 + Vue 3 + TypeScript 前端；Rust 后端 27 个 `#[tauri::command]`
- **关键事实：Rust 层是纯壳，推理不在 Rust 里**：
  - `whisper_cpp.rs` → 起子进程跑 `whisper_cpp` CLI
  - `mlx_qwen3.rs` / `sense_voice.rs` / `dashscope.rs` → `pylibs::run_python` 跑 Python 包（mlx_qwen3_asr / dashscope SDK）
  - `edge.rs` / `cosyvoice.rs`（TTS）→ Python 包 edge-tts / cosyvoice
  - `openai_whisper.rs` → reqwest HTTP（唯一原生网络调用）
  - 音频采集：cpal（麦克风 + BlackHole 虚拟声卡双路）
- 存储：rusqlite（转写记录、档案），配置文件 JSON

## 2. 目标架构（SwiftUI 版，hark-swift/）

| 层 | Tauri 版 | SwiftUI 版 |
|---|---|---|
| UI | Vue 3 三栏 | SwiftUI `NavigationSplitView`，@Observable 状态 |
| 命令通道 | Tauri invoke（IPC） | 进程内 async 方法，无 IPC |
| 录音 | cpal | AVAudioEngine（多设备 tap：默认麦克风 + BlackHole） |
| 本地 ASR | whisper.cpp CLI 子进程 | whisper.cpp Swift Package（进程内）或保留 CLI 子进程（见 §3 决策） |
| MLX ASR | Python mlx_qwen3_asr 子进程 | mlx-swift-examples（qwen3-asr）或保留 Python 子进程 |
| 云端 ASR | Python dashscope SDK | URLSession 直调 DashScope REST（qwen3-asr-flash） |
| TTS | Python edge-tts / cosyvoice | Edge：URLSessionWebSocketTask 原生实现；CosyVoice：REST |
| 存储 | rusqlite | GRDB（SQLite，兼容现有库文件）或 SwiftData |
| 系统集成 | tauri-plugin-dialog/fs | NSOpenPanel / FileManager / NSWorkspace |

## 3. 待决策：推理层策略

| 方案 | 工作量 | 结果 |
|---|---|---|
| A. 子进程桥（SwiftUI 壳 + 现有 Python/CLI） | 小（M1 即可对等） | 界面原生，依赖链仍是 Python+pylibs，瘦身目标打折 |
| B. 全原生（whisper.cpp SPM + mlx-swift + 原生 HTTP/WS） | 大（Edge TTS 的 WS 协议要自己实现） | 彻底摆脱 Python，真正"SwiftUI 原生 App" |
| C. 渐进：M1 用 A 快速对等，M2+ 逐个换成 B | 中 | 推荐——先能用，再逐块替换 |

## 4. 27 个命令 → Swift 对应清单

设备与系统：
- `list_devices` / `has_blackhole` → CoreAudio `AudioObjectGetPropertyData` 枚举；BlackHole 按厂商 "Existential Audio" 识别
- `open_audio_midi_setup` → `NSWorkspace.shared.open(applicationAt:)` Audio MIDI Setup

配置与设置：
- `get/set_asr_config`、`get/set_tts_config`、`get/set_app_settings` → `@Observable` SettingsStore + Codable JSON（沿用现有配置文件结构）
- `get_asr_backend_status` / `get_tts_backend_status` → 各 Backend 协议 `status` 属性

ASR 推理：
- `transcribe_file_cmd`、`warmup_mlx_model`、`warmup_sensevoice_model` → `AsrBackend` 协议（`transcribe(url: AsyncStream<Progress>)`），四个实现：WhisperCppBackend / MlxBackend / SenseVoiceBackend / DashScopeBackend
- `get_transcript` / `clear_transcript` → TranscriptStore（GRDB）

档案：
- `get/add/update/delete_asr_profile`（4 个）→ ProfileStore（同一 SQLite）

录音与音频：
- `start_recording` / `stop_recording` → AudioRecorderService（AVAudioEngine installTap；BlackHole 第二 tap）
- `download_audio_from_url` → URLSession.download
- `copy_tts_file` / `read_tts_file_base64` → FileManager / Data(base64Encoded:)

TTS：
- `list_tts_voices` / `synthesize_tts` → EdgeTtsClient（WebSocket，SSML 拼接 + 音频分片重组） / CosyVoiceClient（REST）

## 5. 里程碑

- **M1 骨架 + 云端 ASR 对等**：XcodeGen 工程、三栏 UI、设置页、DashScope 文件转写、转写历史落库
- **M2 录音链路**：AVAudioEngine 双路采集 → whisper.cpp（策略按 §3）
- **M3 TTS**：Edge TTS 原生实现 + 音频播放/保存
- **M4 本地模型**：mlx-swift qwen3-asr；SenseVoice/onnxruntime 评估（可能砍掉）
- **M5 收尾**：数据迁移（复用现有 SQLite）、删除旧 target 依赖、验收对照 27 命令清单

## 6. 风险

- whisper.cpp 的 Swift 集成需 C++ interop（Swift 6.1 已稳定）或 xcframework 打包，构建脚本有坑
- SenseVoice 现在走 Python（sensevoice.rs 未接线），Swift 版需 onnxruntime + 导出 onnx，成本最高，建议放最后甚至砍掉
- BlackHole 双路采集在 AVAudioEngine 下要用多 tap + 设备选择，需真机验证
- 麦克风权限：Info.plist `NSMicrophoneUsageDescription` 必填
