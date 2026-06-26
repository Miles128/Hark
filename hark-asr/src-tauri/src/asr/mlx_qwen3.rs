use super::{run_python_with_env, AsrConfig};

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let path = path.to_string();
    let config = config.clone();
    tokio::task::spawn_blocking(move || transcribe_blocking(&path, &config))
        .await
        .map_err(|e| format!("转写任务被中断: {:?}", e))?
}

fn transcribe_blocking(path: &str, _config: &AsrConfig) -> Result<String, String> {
    let python = find_mlx_python()?;
    let script = format!(
        r#"
import os
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
# 复用用户主目录的 HuggingFace 缓存，避免每个 venv 重复下载
home = os.path.expanduser("~")
os.environ.setdefault("HF_HOME", os.path.join(home, ".cache", "huggingface"))

import mlx_qwen3_asr
result = mlx_qwen3_asr.transcribe("{}")
if isinstance(result, dict):
    print(result.get("text", "").strip())
elif hasattr(result, "text"):
    print(result.text.strip())
else:
    print(str(result).strip())
"#,
        path.replace('"', "\\\"")
    );

    run_python_with_env(
        &python,
        &script,
        &[
            ("HF_ENDPOINT", "https://hf-mirror.com"),
            ("HF_HUB_DOWNLOAD_TIMEOUT", "300"),
        ],
    )
}

pub fn is_installed() -> bool {
    find_mlx_python().is_ok()
}

/// 返回 UV 管理的项目虚拟环境 python3 路径。
/// 支持 dev（exe 在 src-tauri/target/debug）和打包后（macOS Resources）。
pub fn find_mlx_python() -> Result<String, String> {
    if let Some(path) = find_venv_python() {
        return Ok(path);
    }
    Err("未找到项目虚拟环境。请运行：uv venv && uv pip install mlx-qwen3-asr".to_string())
}

fn find_venv_python() -> Option<String> {
    // 1. 相对于当前工作目录（dev 时 npm run tauri dev 的 cwd）
    let cwd = std::env::current_dir().ok()?;
    for venv_rel in [".venv/bin/python3", ".venv/bin/python"] {
        let candidate = cwd.join(venv_rel);
        if candidate.exists() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }

    // 2. 相对于可执行文件：dev 为 target/debug/hark-asr -> ../../../.venv
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let base = exe_dir.join("../../..");
            for venv_rel in [".venv/bin/python3", ".venv/bin/python"] {
                let candidate = base.join(venv_rel);
                if candidate.exists() {
                    // 保留符号链接，不要 canonicalize 到真实 python，否则 venv site-packages 会丢失
                    return Some(candidate.to_string_lossy().to_string());
                }
            }
        }
    }

    // 3. macOS 打包后的 Resources 目录
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let base = exe_dir.join("../Resources");
            for venv_rel in [".venv/bin/python3", ".venv/bin/python"] {
                let candidate = base.join(venv_rel);
                if candidate.exists() {
                    return Some(candidate.to_string_lossy().to_string());
                }
            }
        }
    }

    None
}

pub fn install_hint() -> String {
    "uv pip install mlx-qwen3-asr".to_string()
}
