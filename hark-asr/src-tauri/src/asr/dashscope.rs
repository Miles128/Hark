use super::{check_python_package, run_python, AsrConfig};

pub async fn transcribe(path: &str, config: &AsrConfig) -> Result<String, String> {
    let path = path.to_string();
    let config = config.clone();
    tokio::task::spawn_blocking(move || transcribe_blocking(&path, &config))
        .await
        .map_err(|e| format!("转写任务被中断: {:?}", e))?
}

fn transcribe_blocking(path: &str, config: &AsrConfig) -> Result<String, String> {
    let api_key = config
        .api_key
        .clone()
        .ok_or_else(|| "DashScope 需要 API Key".to_string())?;

    check_python_package("dashscope", "pip install dashscope")?;

    let model = config
        .model_name
        .clone()
        .unwrap_or_else(|| "qwen3-asr-flash".to_string());

    let script = format!(
        r#"
import dashscope

dashscope.api_key = "{}"
messages = [{{
    "role": "user",
    "content": [{{"audio": "{}"}}]
}}]

response = dashscope.MultiModalConversation.call(
    model="{}",
    messages=messages,
)

content = response.output.choices[0].message.content
if isinstance(content, list) and len(content) > 0:
    text = content[0].get("text", "")
else:
    text = str(content)
print(text.strip())
"#,
        api_key.replace('"', "\\\""),
        path.replace('"', "\\\""),
        model.replace('"', "\\\"")
    );

    run_python(&script)
}

pub fn is_installed() -> bool {
    // DashScope 只要有 Python 环境和 pip 即可安装，不单独检测
    true
}

pub fn install_hint() -> String {
    "pip install dashscope".to_string()
}
