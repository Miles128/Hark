use super::AsrConfig;
use reqwest::multipart::{Form, Part};
use std::path::Path;

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let api_key = config
        .api_key
        .as_ref()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "缺少 OpenAI API Key".to_string())?;

    let api_base = config
        .api_base
        .as_ref()
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| "https://api.openai.com/v1".to_string());

    let model = config
        .model_name
        .as_ref()
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| "whisper-1".to_string());

    let url = format!("{}/audio/transcriptions", api_base.trim_end_matches('/'));

    let file_bytes = tokio::fs::read(path)
        .await
        .map_err(|e| format!("读取音频文件失败: {}", e))?;

    let filename = Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("audio.wav")
        .to_string();

    let part = Part::bytes(file_bytes)
        .file_name(filename)
        .mime_str("audio/wav")
        .map_err(|e| format!("构建文件请求体失败: {}", e))?;

    let form = Form::new()
        .text("model", model)
        .text("response_format", "text")
        .part("file", part);

    let client = reqwest::Client::new();
    let mut request = client.post(&url).multipart(form);
    if !api_key.starts_with("Bearer ") {
        request = request.bearer_auth(api_key);
    } else {
        request = request.header("Authorization", api_key);
    }

    let response = request
        .send()
        .await
        .map_err(|e| format!("请求失败: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response
            .text()
            .await
            .unwrap_or_else(|_| "无法读取错误响应".to_string());
        return Err(format!("API 错误 ({}): {}", status, text));
    }

    let text = response
        .text()
        .await
        .map_err(|e| format!("读取响应失败: {}", e))?;

    Ok(text.trim().to_string())
}

pub fn is_installed(config: &AsrConfig) -> bool {
    config
        .api_key
        .as_ref()
        .map(|s| !s.is_empty())
        .unwrap_or(false)
}

pub fn install_hint() -> String {
    "需要 OpenAI API Key（也兼容 Groq / 自定义 baseURL）".to_string()
}
