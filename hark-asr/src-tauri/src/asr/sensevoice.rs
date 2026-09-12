use super::{run_python_with_env, AsrConfig};

const DEFAULT_MODEL_PATH: &str = "~/models/mlx-community/SenseVoiceSmall";

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let path = path.to_string();
    let config = config.clone();
    tokio::task::spawn_blocking(move || transcribe_blocking(&path, &config))
        .await
        .map_err(|e| format!("转写任务被中断: {:?}", e))?
}

fn transcribe_blocking(path: &str, config: &AsrConfig) -> Result<String, String> {
    let python = find_mlx_python()?;
    let model_path = config
        .model_name
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(DEFAULT_MODEL_PATH)
        .replace("~", &std::env::var("HOME").unwrap_or_default());

    // 检查模型路径是否存在
    if !std::path::Path::new(&model_path).exists() {
        return Err(format!(
            "SenseVoice 模型未找到: {}。请从 HuggingFace 下载 mlx-community/SenseVoiceSmall",
            model_path
        ));
    }

    let language = config.language_or_default();
    let lang_code = match language.as_str() {
        "zh" => "zh",
        "en" => "en",
        "ja" => "ja",
        "ko" => "ko",
        "yue" => "yue",
        _ => "auto",
    };

    let script = format!(
        r#"
import os
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
home = os.path.expanduser("~")
os.environ.setdefault("HF_HOME", os.path.join(home, ".cache", "huggingface"))

# 先 import models 包，规避 mlx-audio 循环导入
import mlx_audio.stt.models  # noqa: F401
from mlx_audio.stt.generate import generate_transcription

segments = generate_transcription(
    model="{model}",
    audio="{audio}",
    format="txt",
    output_path="-",
    language="{lang}",
)
text = getattr(segments, "text", "") or str(segments)
print(text.strip())
"#,
        model = model_path.replace('"', "\\\""),
        audio = path.replace('"', "\\\""),
        lang = lang_code,
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

pub fn find_mlx_python() -> Result<String, String> {
    if let Some(path) = find_venv_python() {
        return Ok(path);
    }
    Err("未找到项目虚拟环境。请运行：uv venv && uv pip install mlx-audio".to_string())
}

fn find_venv_python() -> Option<String> {
    let cwd = std::env::current_dir().ok()?;
    for venv_rel in [".venv/bin/python3", ".venv/bin/python"] {
        let candidate = cwd.join(venv_rel);
        if candidate.exists() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }

    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            let base = exe_dir.join("../../..");
            for venv_rel in [".venv/bin/python3", ".venv/bin/python"] {
                let candidate = base.join(venv_rel);
                if candidate.exists() {
                    return Some(candidate.to_string_lossy().to_string());
                }
            }
        }
    }

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
    "uv pip install mlx-audio\n模型下载: huggingface-cli download mlx-community/SenseVoiceSmall --local-dir ~/models/mlx-community/SenseVoiceSmall".to_string()
}
