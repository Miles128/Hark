use super::AsrConfig;
use std::path::{Path, PathBuf};
use std::process::Command;

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let path = path.to_string();
    let config = config.clone();
    tokio::task::spawn_blocking(move || transcribe_blocking(&path, &config))
        .await
        .map_err(|e| format!("转写任务被中断: {:?}", e))?
}

fn transcribe_blocking(path: &str, config: &AsrConfig) -> Result<String, String> {
    let binary = config
        .whisper_cpp_path
        .clone()
        .or_else(find_whisper_cli)
        .ok_or_else(|| "找不到 whisper-cli。请在设置中指定路径，或把 whisper-cli 加入 PATH".to_string())?;

    let model = config
        .whisper_model_path
        .clone()
        .or_else(default_whisper_model)
        .ok_or_else(|| "找不到 Whisper 模型。请在设置中指定模型路径".to_string())?;

    let lang = config.language_or_default();

    // whisper.cpp 默认会在音频同目录生成 audio.wav.txt
    let output_path = format!("{}.txt", path);

    let status = Command::new(&binary)
        .args([
            "-m", &model,
            "-f", path,
            "-l", &lang,
            "--no-timestamps",
            "-otxt",
        ])
        .status()
        .map_err(|e| format!("调用 whisper-cli 失败: {}", e))?;

    if !status.success() {
        return Err("whisper-cli 执行失败".to_string());
    }

    let content = std::fs::read_to_string(&output_path)
        .map_err(|e| format!("读取转写结果失败: {}", e))?;

    let _ = std::fs::remove_file(&output_path);

    Ok(content.trim().to_string())
}

pub fn is_installed(config: &AsrConfig) -> bool {
    config
        .whisper_cpp_path
        .clone()
        .or_else(find_whisper_cli)
        .is_some()
        && config
            .whisper_model_path
            .clone()
            .or_else(default_whisper_model)
            .is_some()
}

pub fn install_hint() -> String {
    "git clone https://github.com/ggerganov/whisper.cpp.git\ncd whisper.cpp && make\ncurl -L -o models/ggml-small.bin https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin".to_string()
}

fn find_whisper_cli() -> Option<String> {
    // 1. PATH 中的 whisper-cli / main
    for name in ["whisper-cli", "main"] {
        if let Ok(output) = Command::new("which").arg(name).output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    return Some(path);
                }
            }
        }
    }

    // 2. 项目目录下的 whisper.cpp/build/bin/whisper-cli
    if let Some(root) = project_root() {
        let candidate = root.join("whisper.cpp/build/bin/whisper-cli");
        if candidate.exists() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }

    None
}

fn default_whisper_model() -> Option<String> {
    let candidates = [
        "ggml-small.bin",
        "ggml-base.bin",
        "ggml-medium.bin",
    ];

    // 1. 项目目录下的 whisper.cpp/models
    if let Some(root) = project_root() {
        for name in &candidates {
            let path = root.join("whisper.cpp/models").join(name);
            if path.exists() {
                return Some(path.to_string_lossy().to_string());
            }
        }
    }

    // 2. 当前工作目录下的 models
    for name in &candidates {
        let path = Path::new("models").join(name);
        if path.exists() {
            return Some(path.to_string_lossy().to_string());
        }
    }

    // 3. 用户主目录下的 whisper.cpp/models
    if let Ok(home) = std::env::var("HOME") {
        for name in &candidates {
            let path = Path::new(&home).join("whisper.cpp/models").join(name);
            if path.exists() {
                return Some(path.to_string_lossy().to_string());
            }
        }
    }

    None
}

/// 尝试定位项目根目录（cwd 或相对于 exe 的上层目录）
fn project_root() -> Option<PathBuf> {
    // dev / 运行时 cwd 通常是项目根目录
    let cwd = std::env::current_dir().ok()?;
    if cwd.join("whisper.cpp").exists() || cwd.join("mlx-qwen3-asr").exists() {
        return Some(cwd);
    }

    // exe 在 target/debug/hark-asr，上溯三层到项目根目录
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let candidate = exe_dir.join("../../..").canonicalize().ok()?;
            if candidate.join("whisper.cpp").exists() || candidate.join("mlx-qwen3-asr").exists() {
                return Some(candidate);
            }
        }
    }

    None
}
