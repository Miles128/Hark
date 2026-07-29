use super::pylibs;
use crate::asr::AsrConfig;

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let path = path.to_string();
    let config = config.clone();
    tokio::task::spawn_blocking(move || transcribe_blocking(&path, &config))
        .await
        .map_err(|e| format!("转写任务被中断: {:?}", e))?
}

fn transcribe_blocking(path: &str, _config: &AsrConfig) -> Result<String, String> {
    let script = format!(
        r#"
import os
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
# 复用用户主目录的 HuggingFace 缓存，避免重复下载
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

    pylibs::run_python(
        &script,
        &[
            ("HF_ENDPOINT", "https://hf-mirror.com"),
            ("HF_HUB_DOWNLOAD_TIMEOUT", "300"),
        ],
    )
}

pub fn is_installed() -> bool {
    pylibs::is_package_installed("mlx_qwen3_asr")
}

pub fn install_hint() -> String {
    "在项目根目录运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs mlx-qwen3-asr".to_string()
}
