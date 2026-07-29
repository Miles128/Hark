//! SenseVoice Small (MLX 版) 转写后端。
//!
//! 通过 `mlx-audio` 库调用 `mlx-community/SenseVoiceSmall` 模型，
//! 支持 50+ 语言（中/粤/英/日/韩），内置 VAD、情感识别与事件检测。

use super::pylibs;
use crate::asr::AsrConfig;

/// 默认 SenseVoice 模型本地路径。
///
/// 用户已下载到 `~/models/mlx-community/SenseVoiceSmall`。
const DEFAULT_MODEL_PATH: &str = "~/models/mlx-community/SenseVoiceSmall";

/// HuggingFace repo ID（备用，当本地路径不存在时由 mlx-audio 自动下载）。
const HF_REPO_ID: &str = "mlx-community/SenseVoiceSmall";

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let path = path.to_string();
    let config = config.clone();
    tokio::task::spawn_blocking(move || transcribe_blocking(&path, &config))
        .await
        .map_err(|e| format!("转写任务被中断: {:?}", e))?
}

fn transcribe_blocking(path: &str, config: &AsrConfig) -> Result<String, String> {
    let model_path = resolve_model_path(config);
    // SenseVoice language 接受 "auto" 或具体语言代码（zh/en/ja/ko/yue/nospeech）
    let language = config
        .language
        .as_deref()
        .map(map_language)
        .unwrap_or_else(|| "auto".to_string());

    let script = format!(
        r#"
import os
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
home = os.path.expanduser("~")
os.environ.setdefault("HF_HOME", os.path.join(home, ".cache", "huggingface"))

from mlx_audio.stt import load

model_path = "{model_path}"
audio_path = "{audio_path}"
language = "{language}"

# 展开用户路径
model_path = os.path.expanduser(model_path)

model = load(model_path)
result = model.generate(audio_path, language=language, use_itn=True)

text = ""
if hasattr(result, "text"):
    text = result.text or ""
elif isinstance(result, dict):
    text = result.get("text", "")
else:
    text = str(result)

print(text.strip())
"#,
        model_path = model_path.replace('"', "\\\""),
        audio_path = path.replace('"', "\\\""),
        language = language.replace('"', "\\\"")
    );

    pylibs::run_python(
        &script,
        &[
            ("HF_ENDPOINT", "https://hf-mirror.com"),
            ("HF_HUB_DOWNLOAD_TIMEOUT", "300"),
        ],
    )
}

/// 解析模型路径：优先配置 → 默认本地路径 → HuggingFace repo ID。
fn resolve_model_path(config: &AsrConfig) -> String {
    if let Some(custom) = config.model_name.as_ref().filter(|s| !s.is_empty()) {
        // 用户在 modelName 里配置的可能是路径或 repo ID
        return custom.clone();
    }
    // 默认尝试本地路径，如果展开后存在则用，否则用 HF repo ID（让 mlx-audio 自动下载）
    let expanded = expand_home(DEFAULT_MODEL_PATH);
    if std::path::Path::new(&expanded).is_dir() {
        DEFAULT_MODEL_PATH.to_string()
    } else {
        HF_REPO_ID.to_string()
    }
}

/// 展开 ~ 为 $HOME
fn expand_home(p: &str) -> String {
    if let Some(stripped) = p.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{}/{}", home, stripped);
        }
    }
    p.to_string()
}

/// 把 ASR config 里的 language（如 "zh"、"en"）映射到 SenseVoice 接受的语言代码。
///
/// SenseVoice 接受: "auto", "zh", "en", "ja", "ko", "yue", "nospeech"
fn map_language(lang: &str) -> String {
    match lang.to_lowercase().as_str() {
        "auto" | "" => "auto".to_string(),
        "zh" | "chinese" | "cmn" => "zh".to_string(),
        "en" | "english" => "en".to_string(),
        "ja" | "japanese" => "ja".to_string(),
        "ko" | "korean" => "ko".to_string(),
        "yue" | "cantonese" | "粤语" => "yue".to_string(),
        "nospeech" | "none" => "nospeech".to_string(),
        // 未知语言代码原样传递，让 SenseVoice 处理
        _ => lang.to_string(),
    }
}

pub fn is_installed() -> bool {
    pylibs::is_package_installed("mlx_audio")
}

pub fn install_hint() -> String {
    "在项目根目录运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs \"mlx-audio[stt]\"".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn map_language_known_codes() {
        assert_eq!(map_language("zh"), "zh");
        assert_eq!(map_language("EN"), "en");
        assert_eq!(map_language("japanese"), "ja");
        assert_eq!(map_language("粤语"), "yue");
        assert_eq!(map_language(""), "auto");
    }

    #[test]
    fn map_language_unknown_passthrough() {
        assert_eq!(map_language("fr"), "fr");
    }

    #[test]
    fn resolve_model_path_prefers_local_download() {
        let config = AsrConfig {
            backend: crate::asr::AsrBackend::SenseVoice,
            api_key: None,
            api_base: None,
            whisper_cpp_path: None,
            whisper_model_path: None,
            model_name: None,
            language: None,
        };
        // 默认路径或 HF ID
        let path = resolve_model_path(&config);
        assert!(path == DEFAULT_MODEL_PATH || path == HF_REPO_ID);
    }

    #[test]
    fn resolve_model_path_uses_custom_when_set() {
        let config = AsrConfig {
            backend: crate::asr::AsrBackend::SenseVoice,
            api_key: None,
            api_base: None,
            whisper_cpp_path: None,
            whisper_model_path: None,
            model_name: Some("/custom/path".to_string()),
            language: None,
        };
        assert_eq!(resolve_model_path(&config), "/custom/path");
    }
}
