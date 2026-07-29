//! 文字转语音（TTS）后端。

pub mod cosyvoice;
pub mod edge;

use serde::{Deserialize, Serialize};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum TtsBackend {
    Edge,
    CosyVoice,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsConfig {
    pub backend: TtsBackend,
    pub api_key: Option<String>,
    pub voice: String,
    /// Edge rate，如 `+0%` / `-20%` / `+50%`
    pub rate: String,
}

impl Default for TtsConfig {
    fn default() -> Self {
        Self {
            backend: TtsBackend::Edge,
            api_key: None,
            voice: "zh-CN-XiaoxiaoNeural".to_string(),
            rate: "+0%".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TtsVoice {
    pub id: String,
    pub name: String,
    pub locale: String,
    pub gender: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct TtsBackendStatus {
    pub backend: String,
    pub installed: bool,
    pub hint: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SynthesizeResult {
    pub path: String,
    pub cached: bool,
}

pub fn backend_status() -> Vec<TtsBackendStatus> {
    vec![
        TtsBackendStatus {
            backend: "Edge".to_string(),
            installed: edge::is_installed(),
            hint: edge::install_hint(),
        },
        TtsBackendStatus {
            backend: "CosyVoice".to_string(),
            installed: cosyvoice::is_installed(),
            hint: cosyvoice::install_hint(),
        },
    ]
}

pub async fn list_voices(backend: TtsBackend) -> Result<Vec<TtsVoice>, String> {
    match backend {
        TtsBackend::Edge => edge::list_voices().await,
        TtsBackend::CosyVoice => Ok(cosyvoice::list_voices()),
    }
}

pub async fn synthesize(
    text: &str,
    config: &TtsConfig,
    output_dir: &Path,
) -> Result<SynthesizeResult, String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("请输入要朗读的文字".to_string());
    }
    if text.chars().count() > 5000 {
        return Err("文本过长（最多 5000 字），请拆分后再试".to_string());
    }

    std::fs::create_dir_all(output_dir).map_err(|e| format!("创建 TTS 目录失败: {}", e))?;

    let cache_key = cache_key(text, config);
    let out_path = output_dir.join(format!("tts_{}.mp3", cache_key));
    if out_path.is_file() {
        return Ok(SynthesizeResult {
            path: out_path.to_string_lossy().to_string(),
            cached: true,
        });
    }

    let path_str = out_path.to_string_lossy().to_string();
    match config.backend {
        TtsBackend::Edge => edge::synthesize(text, &config.voice, &config.rate, &path_str).await?,
        TtsBackend::CosyVoice => {
            let key = config
                .api_key
                .as_deref()
                .filter(|k| !k.is_empty())
                .ok_or_else(|| {
                    "阿里云 CosyVoice 需要 DashScope API Key，请在设置中配置 DashScope 模型"
                        .to_string()
                })?;
            let speech_rate = edge_rate_to_float(&config.rate);
            cosyvoice::synthesize(text, key, &config.voice, speech_rate, &path_str).await?;
        }
    }

    if !PathBuf::from(&path_str).is_file() {
        return Err("合成完成但未找到输出文件".to_string());
    }

    Ok(SynthesizeResult {
        path: path_str,
        cached: false,
    })
}

fn cache_key(text: &str, config: &TtsConfig) -> String {
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    format!("{:?}", config.backend).hash(&mut hasher);
    config.voice.hash(&mut hasher);
    config.rate.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// 将 Edge 风格 `+0%` / `-20%` 转为 CosyVoice 的 0.5–2.0 倍速。
fn edge_rate_to_float(rate: &str) -> f64 {
    let s = rate.trim().trim_end_matches('%');
    match s.parse::<f64>() {
        Ok(pct) => (1.0 + pct / 100.0).clamp(0.5, 2.0),
        Err(_) => 1.0,
    }
}
