mod asr;
mod audio;
mod profiles;
mod url_audio;

use asr::{backend_status, transcribe_file, AsrBackend, AsrBackendStatus, AsrConfig};
use profiles::AsrProfile;
use audio::{list_audio_devices, AudioDeviceInfo, AudioSource, RecordingHandle};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Emitter, Manager};

pub struct AppState {
    recording: Mutex<Option<RecordingHandle>>,
    recordings_dir: Mutex<Option<PathBuf>>,
    asr_config: Mutex<AsrConfig>,
    transcript: Mutex<Vec<TranscriptSegment>>,
    settings: Mutex<AppSettings>,
    last_auto_save_hash: Mutex<Option<u64>>,
    db: Mutex<Option<rusqlite::Connection>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    pub theme: String,
    pub auto_save_interval: u64,
    pub auto_save_format: String,
    pub active_profile_id: Option<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            theme: "system".to_string(),
            auto_save_interval: 60,
            auto_save_format: "txt".to_string(),
            active_profile_id: None,
        }
    }
}

fn settings_dir(app_handle: &tauri::AppHandle) -> PathBuf {
    app_handle
        .path()
        .app_config_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("hark-asr-config"))
}

fn settings_path(app_handle: &tauri::AppHandle) -> PathBuf {
    settings_dir(app_handle).join("settings.json")
}

fn load_settings(app_handle: &tauri::AppHandle) -> AppSettings {
    let path = settings_path(app_handle);
    if let Ok(content) = std::fs::read_to_string(path) {
        if let Ok(settings) = serde_json::from_str::<AppSettings>(&content) {
            return settings;
        }
    }
    AppSettings::default()
}

fn save_settings(app_handle: &tauri::AppHandle, settings: &AppSettings) -> Result<(), String> {
    let dir = settings_dir(app_handle);
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建配置目录失败: {}", e))?;
    let path = dir.join("settings.json");
    let content = serde_json::to_string_pretty(settings).map_err(|e| format!("序列化设置失败: {}", e))?;
    std::fs::write(path, content).map_err(|e| format!("保存设置失败: {}", e))?;
    Ok(())
}

fn auto_save_dir(app_handle: &tauri::AppHandle) -> PathBuf {
    app_handle
        .path()
        .audio_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("hark-asr"))
        .join("hark-asr")
        .join("auto-save")
}

fn format_auto_save_text(segments: &[TranscriptSegment], format: &str) -> String {
    match format {
        "md" => {
            let mut s = "# Hark 自动保存\n\n".to_string();
            for seg in segments {
                s.push_str(&format!("## 段落 {}\n\n{}\n\n", seg.index + 1, seg.text));
            }
            s
        }
        _ => segments
            .iter()
            .map(|s| s.text.trim())
            .collect::<Vec<_>>()
            .join("\n\n"),
    }
}

fn do_auto_save(app_handle: &tauri::AppHandle) -> Result<(), String> {
    let state = app_handle.state::<AppState>();
    let segments = state.transcript.lock().unwrap().clone();
    if segments.is_empty() {
        return Ok(());
    }

    let format = state.settings.lock().unwrap().auto_save_format.clone();
    let text = format_auto_save_text(&segments, &format);

    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    let hash = hasher.finish();

    let mut last_hash = state.last_auto_save_hash.lock().unwrap();
    if last_hash.as_ref() == Some(&hash) {
        return Ok(());
    }

    let dir = auto_save_dir(app_handle);
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建自动保存目录失败: {}", e))?;
    let ext = if format == "md" { "md" } else { "txt" };
    let path = dir.join(format!("hark-auto-save.{}", ext));
    std::fs::write(&path, text).map_err(|e| format!("自动保存失败: {}", e))?;
    *last_hash = Some(hash);
    Ok(())
}

fn start_auto_save_loop(app_handle: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            let interval = {
                let state = app_handle.state::<AppState>();
                let interval = state.settings.lock().unwrap().auto_save_interval;
                interval
            };

            if interval == 0 {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }

            tokio::time::sleep(std::time::Duration::from_secs(interval)).await;

            if let Err(e) = do_auto_save(&app_handle) {
                eprintln!("[auto-save] {}", e);
            }
        }
    });
}

#[derive(Debug, Clone, Serialize)]
pub struct TranscriptSegment {
    pub index: u32,
    pub text: String,
    pub backend: String,
}

#[tauri::command]
fn list_devices() -> Result<Vec<AudioDeviceInfo>, String> {
    Ok(list_audio_devices())
}

#[tauri::command]
fn has_blackhole() -> bool {
    audio::has_blackhole()
}

#[tauri::command]
fn open_audio_midi_setup() -> Result<(), String> {
    std::process::Command::new("open")
        .args(["-a", "Audio MIDI Setup"])
        .spawn()
        .map_err(|e| format!("打开音频 MIDI 设置失败: {}", e))?;
    Ok(())
}

#[tauri::command]
fn get_asr_config(state: tauri::State<AppState>) -> AsrConfig {
    state.asr_config.lock().unwrap().clone()
}

#[tauri::command]
fn set_asr_config(state: tauri::State<AppState>, config: AsrConfig) -> Result<(), String> {
    *state.asr_config.lock().unwrap() = config;
    Ok(())
}

#[tauri::command]
fn get_asr_backend_status(state: tauri::State<AppState>) -> Vec<AsrBackendStatus> {
    let config = state.asr_config.lock().unwrap().clone();
    backend_status(&config)
}

#[tauri::command]
fn get_asr_profiles(state: tauri::State<AppState>) -> Result<Vec<AsrProfile>, String> {
    let guard = state.db.lock().unwrap();
    let conn = guard.as_ref().ok_or("数据库未初始化")?;
    profiles::list_profiles(conn).map_err(|e| e.to_string())
}

#[tauri::command]
fn add_asr_profile(
    state: tauri::State<AppState>,
    profile: AsrProfile,
) -> Result<AsrProfile, String> {
    let guard = state.db.lock().unwrap();
    let conn = guard.as_ref().ok_or("数据库未初始化")?;
    profiles::add_profile(conn, profile).map_err(|e| e.to_string())
}

#[tauri::command]
fn update_asr_profile(state: tauri::State<AppState>, profile: AsrProfile) -> Result<(), String> {
    let guard = state.db.lock().unwrap();
    let conn = guard.as_ref().ok_or("数据库未初始化")?;
    profiles::update_profile(conn, &profile).map_err(|e| e.to_string())
}

#[tauri::command]
fn delete_asr_profile(state: tauri::State<AppState>, id: String) -> Result<(), String> {
    let guard = state.db.lock().unwrap();
    let conn = guard.as_ref().ok_or("数据库未初始化")?;
    profiles::delete_profile(conn, &id).map_err(|e| e.to_string())
}

#[tauri::command]
fn start_recording(
    state: tauri::State<AppState>,
    app_handle: tauri::AppHandle,
    source: AudioSource,
    mic_device: Option<String>,
    system_device: Option<String>,
    live_transcribe: bool,
) -> Result<String, String> {
    let recordings_dir = {
        let dir_guard = state.recordings_dir.lock().unwrap();
        dir_guard.clone().unwrap_or_else(|| {
            app_handle
                .path()
                .audio_dir()
                .unwrap_or_else(|_| std::env::temp_dir())
                .join("hark-asr")
        })
    };

    let handle = audio::start_recording(
        source,
        mic_device,
        system_device,
        live_transcribe,
        recordings_dir,
        app_handle,
    )?;
    *state.recording.lock().unwrap() = Some(handle);

    // 清空之前的转写
    state.transcript.lock().unwrap().clear();

    Ok("录音已开始".to_string())
}

#[tauri::command]
async fn stop_recording(state: tauri::State<'_, AppState>) -> Result<String, String> {
    let handle = state
        .recording
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| "没有正在进行的录音".to_string())?;

    let result = handle
        .stop()
        .await
        .map_err(|e| format!("停止录音失败: {:?}", e))?;
    result
}

#[tauri::command]
async fn warmup_mlx_model(app_handle: tauri::AppHandle) -> Result<(), String> {
    let _ = app_handle.emit("asr:warmup", WarmupEvent { status: "downloading".to_string(), message: "正在准备 mlx-qwen3-asr 模型（首次使用需下载）…".to_string() });

    tokio::task::spawn_blocking(move || {
        let python = asr::mlx_qwen3::find_mlx_python()?;
        let script = r#"
import os
os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "300")
home = os.path.expanduser("~")
os.environ.setdefault("HF_HOME", os.path.join(home, ".cache", "huggingface"))

import mlx_qwen3_asr
mlx_qwen3_asr.load_model()
print("ok")
"#;
        asr::run_python_with_env(
            &python,
            script,
            &[
                ("HF_ENDPOINT", "https://hf-mirror.com"),
                ("HF_HUB_DOWNLOAD_TIMEOUT", "300"),
            ],
        )
    })
    .await
    .map_err(|e| format!("模型预热任务被中断: {:?}", e))?
    .map_err(|e| e)?;

    let _ = app_handle.emit("asr:warmup", WarmupEvent { status: "ready".to_string(), message: "模型就绪".to_string() });
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
struct WarmupEvent {
    status: String,
    message: String,
}

#[tauri::command]
async fn transcribe_file_cmd(
    state: tauri::State<'_, AppState>,
    app_handle: tauri::AppHandle,
    file_path: String,
    index: u32,
) -> Result<String, String> {
    let config = state.asr_config.lock().unwrap().clone();
    let backend_name = format!("{:?}", config.backend);

    let text = transcribe_file(&file_path, &config).await?;

    let segment = TranscriptSegment {
        index,
        text: text.clone(),
        backend: backend_name,
    };

    state.transcript.lock().unwrap().push(segment.clone());
    let _ = app_handle.emit("asr:segment", segment);

    Ok(text)
}

#[tauri::command]
async fn download_audio_from_url(
    state: tauri::State<'_, AppState>,
    app_handle: tauri::AppHandle,
    url: String,
) -> Result<String, String> {
    let output_dir = {
        let dir_guard = state.recordings_dir.lock().unwrap();
        dir_guard.clone().unwrap_or_else(|| {
            app_handle
                .path()
                .audio_dir()
                .unwrap_or_else(|_| std::env::temp_dir())
                .join("hark-asr")
        })
    }
    .join("downloads");

    let filepath = tokio::task::spawn_blocking(move || url_audio::download_audio(&url, &output_dir))
        .await
        .map_err(|e| format!("下载任务被中断: {:?}", e))?
        .map_err(|e| e)?;

    Ok(filepath.to_string_lossy().to_string())
}

#[tauri::command]
fn get_transcript(state: tauri::State<AppState>) -> Vec<TranscriptSegment> {
    state.transcript.lock().unwrap().clone()
}

#[tauri::command]
fn clear_transcript(state: tauri::State<AppState>) {
    state.transcript.lock().unwrap().clear();
}

#[tauri::command]
fn get_app_settings(state: tauri::State<AppState>) -> AppSettings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
fn set_app_settings(
    state: tauri::State<AppState>,
    app_handle: tauri::AppHandle,
    settings: AppSettings,
) -> Result<(), String> {
    *state.settings.lock().unwrap() = settings.clone();
    save_settings(&app_handle, &settings)?;
    let _ = app_handle.emit("settings:changed", settings);
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .setup(|app| {
            let handle = app.handle().clone();
            let settings = load_settings(&handle);
            let db = profiles::init_db(&handle)
                .map_err(|e| format!("初始化模型数据库失败: {}", e))?;
            let state = app.state::<AppState>();
            *state.settings.lock().unwrap() = settings;
            *state.db.lock().unwrap() = Some(db);
            start_auto_save_loop(handle);
            Ok(())
        })
        .manage(AppState {
            recording: Mutex::new(None),
            recordings_dir: Mutex::new(None),
            asr_config: Mutex::new(AsrConfig {
                backend: AsrBackend::MlxQwen3,
                api_key: None,
                api_base: None,
                whisper_cpp_path: None,
                whisper_model_path: None,
                model_name: None,
                language: Some("zh".to_string()),
            }),
            transcript: Mutex::new(Vec::new()),
            settings: Mutex::new(AppSettings::default()),
            last_auto_save_hash: Mutex::new(None),
            db: Mutex::new(None),
        })
        .invoke_handler(tauri::generate_handler![
            list_devices,
            has_blackhole,
            open_audio_midi_setup,
            get_asr_config,
            set_asr_config,
            get_asr_backend_status,
            get_asr_profiles,
            add_asr_profile,
            update_asr_profile,
            delete_asr_profile,
            warmup_mlx_model,
            start_recording,
            stop_recording,
            transcribe_file_cmd,
            download_audio_from_url,
            get_transcript,
            clear_transcript,
            get_app_settings,
            set_app_settings
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
