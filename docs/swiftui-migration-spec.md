# Hark SwiftUI 迁移方案（spec）

> 状态：v2（2026-09-13）。M1–M5 全部完成，验收见 §4，里程碑结果见 §5。Tauri 版（hark-asr/）保留作参考与回退，行为对等仍以它为基准。

## 1. 现状盘点

- 技术栈：Tauri 2 + Vue 3 + TypeScript 前端；Rust 后端 27 个 `#[tauri::command]`
- **关键事实：Rust 层是纯壳，推理不在 Rust 里**：
  - `whisper_cpp.rs` → 起子进程跑 `whisper_cpp` CLI
  - `mlx_qwen3.rs` / `sense_voice.rs` / `dashscope.rs` → `pylibs::run_python` 跑 Python 包（mlx_qwen3_asr / dashscope SDK）
  - `edge.rs` / `cosyvoice.rs`（TTS）→ Python 包 edge-tts / cosyvoice
  - `openai_whisper.rs` → reqwest HTTP（唯一原生网络调用）
  - 音频采集：cpal（麦克风 + BlackHole 虚拟声卡双路）
- 存储：rusqlite **只存 `asr_profiles`**；转写记录不入库（`Mutex<Vec<TranscriptSegment>>` 内存态，唯一持久产物是 auto-save 的 txt/md）；配置走 `settings.json`

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
| 存储 | rusqlite | GRDB（选定，直接读写现有 `profiles.db`；未用 SwiftData） |
| 系统集成 | tauri-plugin-dialog/fs | NSOpenPanel / FileManager / NSWorkspace |

## 3. 推理层策略：已选 C（渐进）

M1 用 A 起步，但 M2–M4 的"逐个换成 B"没有发生：五路 ASR、TTS、yt-dlp 到今天仍是子进程。下表保留当时的取舍。

| 方案 | 工作量 | 结果 |
|---|---|---|
| A. 子进程桥（SwiftUI 壳 + 现有 Python/CLI） | 小（M1 即可对等） | 界面原生，依赖链仍是 Python+pylibs，瘦身目标打折 |
| B. 全原生（whisper.cpp SPM + mlx-swift + 原生 HTTP/WS） | 大（Edge TTS 的 WS 协议要自己实现） | 彻底摆脱 Python，真正"SwiftUI 原生 App" |
| C. 渐进：M1 用 A 快速对等，M2+ 逐个换成 B | 中 | 推荐——先能用，再逐块替换 |

## 4. 27 个命令 → Swift 对应清单（M5 验收）

对照 `hark-asr/src-tauri/src/lib.rs:599` 的 `generate_handler!` 逐条核销。§2 表格里"目标架构"写的原生方案（mlx-swift / URLSession REST / Edge WebSocket）最终**没有采用**，实际落地走 §3 的方案 C：推理层继续用 Python / CLI 子进程桥，Swift 只替换 UI 与 IPC。

| # | Rust command | Swift 对应 | 说明 |
|---|---|---|---|
| 1 | `list_devices` | `CoreAudioDevices.allDevices()` / `inputDevices()`，入口 `AppModel.loadDevices()` | 直接查 CoreAudio，不经 cpal |
| 2 | `has_blackhole` | `CoreAudioDevices.hasBlackhole()` | 复用 Rust 的 `BLACKHOLE_NAMES` 三关键字 |
| 3 | `open_audio_midi_setup` | `AppModel.openAudioMidiSetup()` | |
| 4 | `get_asr_config` | `AppModel.activeProfile`（`AsrProfile` 快照） | 无 IPC：Rust 的 `AsrConfig` 是内存态，Swift 拆成 `AsrBackendService.transcribe(fileURL:apiKey:apiBase:model:whisperCppPath:whisperModelPath:)` 的入参 |
| 5 | `set_asr_config` | `AppModel.selectedProfileId` 切换 | 配置源从"一个全局 config"变成"档案表里的活动档案" |
| 6 | `get_asr_backend_status` | `AsrStatus.all(bridge:profiles:activeProfile:)`，入口 `AppModel.refreshAsrStatus()` | |
| 7 | `get_tts_config` | `AppModel.ttsBackend/ttsVoiceId/ratePercent` → `TtsConfig` | |
| 8 | `set_tts_config` | 同上（直接改属性） | |
| 9 | `get_tts_backend_status` | `TtsService.backendStatus(bridge:)`，入口 `refreshTtsStatus()` | |
| 10 | `list_tts_voices` | `TtsService.listVoices(_:bridge:)`，入口 `AppModel.loadTtsVoices()` | Edge 仍走 pylibs `edge_tts`；CosyVoice 用静态列表 |
| 11 | `synthesize_tts` | `TtsService.synthesize(_:config:bridge:)`，入口 `synthesizeText(_:)` / `synthesizeAndPlay(_:)` | |
| 12 | `copy_tts_file` | `SidebarView.exportAudio()`：`NSSavePanel` + `FileManager.copyItem` | Rust 由前端传 dest 路径，Swift 用系统面板 |
| 13 | `read_tts_file_base64` | **无需对应**：`AVAudioPlayer(contentsOf:)` 直接读文件 | base64 只是为了喂给 Webview 的 `<audio>` |
| 14 | `get_asr_profiles` | `ProfileStore.list()`，入口 `AppModel.profiles` | GRDB，同一张 `asr_profiles` 表 |
| 15 | `add_asr_profile` | `ProfileStore.add(_:)`，入口 `AppModel.addProfile(_:)` | 空 id 补小写 uuid v4，`created_at` 写 unix 秒 |
| 16 | `update_asr_profile` | `ProfileStore.update(_:)`，入口 `updateProfile(_:)` | 不写 `created_at`，列表顺序不变 |
| 17 | `delete_asr_profile` | `ProfileStore.delete(id:)`，入口 `deleteProfile(_:)` | |
| 18 | `warmup_mlx_model` | `MlxQwen3Backend.warmupScript()`，入口 `AppModel.warmupModel()` | Rust `emit("asr:warmup")` → `AppModel.warmup: WarmupEvent?` |
| 19 | `warmup_sensevoice_model` | `SenseVoiceBackend.warmupScript(model:)` | 同上，走 `profile.modelName` |
| 20 | `start_recording` | `AppModel.toggleRecording()` → `AudioRecorder.start(...)` | AVAudioEngine 双 tap，替代 cpal |
| 21 | `stop_recording` | `AppModel.stopAndTranscribe()` → `AudioRecorder.stop()` | |
| 22 | `transcribe_file_cmd` | `AsrRouter.backend(for:bridge:)` 分发 5 个后端，入口 `transcribeFile(at:index:)` | whisper.cpp 仍是 CLI 子进程；DashScope/MLX/SenseVoice 仍是 Python |
| 23 | `download_audio_from_url` | `UrlAudioDownloader.download(url:outputDir:)`，入口 `AppModel.downloadAudio(from:)` | **仍是 yt-dlp 子进程**，不是 URLSession |
| 24 | `get_transcript` | `AppModel.segments` | 两版都是内存态，重启即空；不落库 |
| 25 | `clear_transcript` | `AppModel.clearSegments()` | |
| 26 | `get_app_settings` | `AppModel.settings`（`AppSettings`） | 同一个 `settings.json` |
| 27 | `set_app_settings` | `settings` 的 `didSet` → `persistSettings()` | 语义未变不写盘，对齐 Rust"只在 set 时写" |

唯一持久产物是 `~/Music/hark-asr/auto-save/hark-auto-save.{txt,md}`，由 `AutoSaveLoop` 每 N 秒覆盖写。

## 5. 里程碑

- **M1 骨架 + 云端 ASR 对等** ✅：XcodeGen 工程、三栏 UI、设置页、DashScope 文件转写
- **M1.5 界面复刻** ✅（计划外补做）：按 Vue 源 1:1 移植布局与文案，不接受骨架版
- **M2 录音链路** ✅：AVAudioEngine 双路采集 → whisper.cpp（走 CLI 子进程，即 §3 方案 A/C）
- **M3 TTS** ✅：Edge TTS + CosyVoice、播放与导出。**偏离**：Edge 没有实现原生 WebSocket 客户端，仍调 pylibs `edge_tts`
- **M4 本地模型** ✅：mlx-qwen3-asr / SenseVoice / OpenAI Whisper。SenseVoice 未砍，仍走 Python（mlx_audio）
- **M5 收尾** ✅：GRDB 接现有 `profiles.db`、27 命令对照 §4 核销、`xcodebuild test` 51 项通过

自动化跑测里 `-skip-testing` 掉 3 个起子进程的用例（`PythonBridgeTests/testRunPythonPrintsOK`、`AsrBackendsTests/testSenseVoiceTranscribesSpeechThroughPythonBridge`、`AsrBackendsTests/testWhisperCppTranscribesSpeech`）：在 Xcode 测试宿主里 spawn Python 会卡在解释器初始化，见 §6。这三条改为手动验证。

## 6. 风险与实际结果

- ~~whisper.cpp 的 Swift 集成需 C++ interop 或 xcframework 打包~~ —— 未发生：继续用 CLI 子进程，构建零改动
- SenseVoice 实际接线的是 Rust `asr/sense_voice.rs`（走 Python `mlx_audio`）；`asr/sensevoice.rs` 是**孤儿文件**，`asr/mod.rs` 里没有 `pub mod` 声明，从未参与编译。Swift 版照抄 `sense_voice.rs`，因此不需要 onnxruntime 与 onnx 导出
- BlackHole 双路采集已按 AVAudioEngine 多 tap 实现，但**仍需在装了 BlackHole 的机器上实测**；本机未装，只验过禁用态样式
- **`xcodebuild test` 宿主里 spawn Python 会挂**：解释器初始化阶段阻塞在 `os.listdir → open()`，连 `python -s -c "print('ok')"` 也不返回；同一条命令在普通 shell 里 19 ms 完成。测试宿主进程 `cwd=/`、stdin 是 tty、`PYTHONPATH` 指向 `~/Documents` 下的 pylibs（iCloud「桌面与文稿」同步开启），三者之一导致内核态等待。M5 期间 03:10 / 03:15 两次跑测这三条用例还是通过的，之后稳定复现挂起，故按环境问题处理
- 麦克风权限：Info.plist `NSMicrophoneUsageDescription` 必填 —— 已配在 `project.yml`（`INFOPLIST_KEY_NSMicrophoneUsageDescription`）
- **`@Observable` 的 `didSet` 在 `init` 里也会触发**（普通 class 不会）。M5 就栽在这一点上：AppModel 启动时的赋值链让 `settings` 的 didSet 跑起来，每次开 App 都重写一遍与 Tauri 共享的 `settings.json`，而 Rust 只在 `set_app_settings` 时写盘。用"语义未变就不写"抵消。**任何 @Observable + didSet 持久化的组合都要按这个前提设计**，LearnEnglish 迁移同理
- 顺带暴露：`PythonBridge.run` / `UrlAudioDownloader.download` 都是 `readDataToEndOfFile()` + `waitUntilExit()`，**没有超时**，子进程卡死会永久占住一条 userInitiated 工作线程。方案 B（真原生推理）落地前值得补上
