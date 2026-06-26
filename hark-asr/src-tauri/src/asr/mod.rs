use serde::{Deserialize, Serialize};

pub mod dashscope;
pub mod mlx_qwen3;
pub mod openai_whisper;
pub mod whisper_cpp;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum AsrBackend {
    MlxQwen3,
    WhisperCpp,
    DashScope,
    OpenAiWhisper,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AsrConfig {
    pub backend: AsrBackend,
    pub api_key: Option<String>,
    pub api_base: Option<String>,
    pub whisper_cpp_path: Option<String>,
    pub whisper_model_path: Option<String>,
    pub model_name: Option<String>,
    pub language: Option<String>,
}

impl AsrConfig {
    pub fn language_or_default(&self) -> String {
        self.language.clone().unwrap_or_else(|| "zh".to_string())
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct AsrBackendStatus {
    pub backend: String,
    pub installed: bool,
    pub hint: String,
}

pub async fn transcribe_file(path: &str, config: &AsrConfig) -> Result<String, String> {
    match config.backend {
        AsrBackend::MlxQwen3 => mlx_qwen3::transcribe(path, config).await,
        AsrBackend::WhisperCpp => whisper_cpp::transcribe(path, config).await,
        AsrBackend::DashScope => dashscope::transcribe(path, config).await,
        AsrBackend::OpenAiWhisper => openai_whisper::transcribe(path, config).await,
    }
}

pub fn backend_status(config: &AsrConfig) -> Vec<AsrBackendStatus> {
    vec![
        AsrBackendStatus {
            backend: "MlxQwen3".to_string(),
            installed: mlx_qwen3::is_installed(),
            hint: mlx_qwen3::install_hint(),
        },
        AsrBackendStatus {
            backend: "WhisperCpp".to_string(),
            installed: whisper_cpp::is_installed(config),
            hint: whisper_cpp::install_hint(),
        },
        AsrBackendStatus {
            backend: "DashScope".to_string(),
            installed: dashscope::is_installed(),
            hint: dashscope::install_hint(),
        },
        AsrBackendStatus {
            backend: "OpenAiWhisper".to_string(),
            installed: openai_whisper::is_installed(config),
            hint: openai_whisper::install_hint(),
        },
    ]
}

pub(crate) fn run_python(script: &str) -> Result<String, String> {
    run_python_with("python3", script)
}

pub(crate) fn run_python_with(python: &str, script: &str) -> Result<String, String> {
    run_python_with_env(python, script, &[])
}

pub(crate) fn run_python_with_env(
    python: &str,
    script: &str,
    env_vars: &[(&str, &str)],
) -> Result<String, String> {
    let mut cmd = std::process::Command::new(python);
    cmd.args(["-c", script]);
    for (key, value) in env_vars {
        cmd.env(key, value);
    }

    let output = cmd
        .output()
        .map_err(|e| format!("运行 Python 失败: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Python 执行失败: {}", stderr));
    }

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

pub(crate) fn check_python_package(package: &str, install_hint: &str) -> Result<(), String> {
    let output = std::process::Command::new("python3")
        .args(["-c", &format!("import {}; print('ok')", package)])
        .output()
        .map_err(|e| format!("检查 Python 环境失败: {}", e))?;

    if !output.status.success() {
        return Err(format!(
            "未安装 {}，请运行: {}",
            package, install_hint
        ));
    }
    Ok(())
}
