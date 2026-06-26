# Hark · 谛听

一个 macOS 本地桌面端听录转文字 App，支持同时录制麦克风和外放声音，可选择本地或云端 ASR 模型。

## 开发

```bash
npm install
npm run tauri dev
```

## 技术栈

- Tauri 2 + Vue 3 + TypeScript
- Rust + cpal
- mlx-qwen3-asr / whisper.cpp / DashScope
