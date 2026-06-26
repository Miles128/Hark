use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleFormat, Stream, StreamConfig};
use hound::{WavSpec, WavWriter};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::BufWriter;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};

pub const BLACKHOLE_NAMES: &[&str] = &["blackhole", "soundflower", "loopback"];

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub enum AudioSource {
    #[serde(rename = "microphone")]
    Microphone,
    #[serde(rename = "system")]
    SystemAudio,
    #[serde(rename = "both")]
    Both,
}

#[derive(Debug, Clone, Serialize)]
pub struct AudioDeviceInfo {
    pub name: String,
    pub is_input: bool,
    pub index: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct VolumeEvent {
    pub db: f32,
    pub level: f32,
}

#[derive(Debug, Clone, Serialize)]
pub struct SliceEvent {
    pub path: String,
    pub index: u32,
}

pub fn list_audio_devices() -> Vec<AudioDeviceInfo> {
    let host = cpal::default_host();
    let mut devices = Vec::new();
    let mut index = 0;

    if let Ok(inputs) = host.input_devices() {
        for device in inputs {
            if let Ok(name) = device.name() {
                devices.push(AudioDeviceInfo {
                    name,
                    is_input: true,
                    index,
                });
                index += 1;
            }
        }
    }

    devices
}

pub fn has_blackhole() -> bool {
    find_blackhole_device(None).is_some()
}

pub fn find_blackhole_device(preferred: Option<&str>) -> Option<Device> {
    let host = cpal::default_host();

    if let Some(name) = preferred {
        if let Some(device) = find_device(name) {
            return Some(device);
        }
    }

    if let Ok(inputs) = host.input_devices() {
        for device in inputs {
            if let Ok(name) = device.name() {
                if BLACKHOLE_NAMES
                    .iter()
                    .any(|&b| name.to_lowercase().contains(b))
                {
                    return Some(device);
                }
            }
        }
    }
    None
}

pub fn find_microphone_device(preferred: Option<&str>) -> Option<Device> {
    let host = cpal::default_host();

    // 优先使用用户指定的设备
    if let Some(name) = preferred {
        if let Some(device) = find_device(name) {
            return Some(device);
        }
    }

    if let Ok(inputs) = host.input_devices() {
        for device in inputs {
            if let Ok(name) = device.name() {
                let lower = name.to_lowercase();
                if lower.contains("macbook")
                    || lower.contains("built-in")
                    || lower.contains("麦克风")
                    || lower.contains("microphone")
                {
                    return Some(device);
                }
            }
        }
    }
    // 兜底：返回默认输入设备
    host.default_input_device()
}

pub fn find_device(name_substring: &str) -> Option<Device> {
    let host = cpal::default_host();
    if let Ok(inputs) = host.input_devices() {
        for device in inputs {
            if let Ok(name) = device.name() {
                if name.to_lowercase().contains(&name_substring.to_lowercase()) {
                    return Some(device);
                }
            }
        }
    }
    None
}

pub struct RecordingHandle {
    stop_tx: mpsc::Sender<()>,
    result_rx: tokio::sync::oneshot::Receiver<Result<String, String>>,
}

impl RecordingHandle {
    pub fn stop(self) -> tokio::sync::oneshot::Receiver<Result<String, String>> {
        let _ = self.stop_tx.send(());
        self.result_rx
    }
}

pub fn start_recording(
    source: AudioSource,
    mic_device: Option<String>,
    system_device: Option<String>,
    live_transcribe: bool,
    output_dir: PathBuf,
    app_handle: AppHandle,
) -> Result<RecordingHandle, String> {
    let device_names = resolve_device_names(source, mic_device.as_deref(), system_device.as_deref())?;

    if device_names.is_empty() {
        return Err("没有可用的录音设备".to_string());
    }

    let (stop_tx, stop_rx) = mpsc::channel::<()>();
    let (result_tx, result_rx) = tokio::sync::oneshot::channel();

    std::thread::spawn(move || {
        let result = recording_thread(device_names, live_transcribe, output_dir, stop_rx, app_handle);
        let _ = result_tx.send(result);
    });

    Ok(RecordingHandle {
        stop_tx,
        result_rx,
    })
}

fn resolve_device_names(
    source: AudioSource,
    mic_device: Option<&str>,
    system_device: Option<&str>,
) -> Result<Vec<String>, String> {
    match source {
        AudioSource::Microphone => {
            let mic = find_microphone_device(mic_device)
                .ok_or_else(|| "找不到麦克风设备".to_string())?;
            Ok(vec![mic.name().map_err(|e| format!("获取设备名失败: {}", e))?])
        }
        AudioSource::SystemAudio => {
            let blackhole = find_blackhole_device(system_device)
                .ok_or_else(|| "找不到 BlackHole 设备，请安装 BlackHole 并设置为系统输出".to_string())?;
            Ok(vec![blackhole.name().map_err(|e| format!("获取设备名失败: {}", e))?])
        }
        AudioSource::Both => {
            let mic = find_microphone_device(mic_device)
                .ok_or_else(|| "找不到麦克风设备".to_string())?;
            let blackhole = find_blackhole_device(system_device)
                .ok_or_else(|| "找不到 BlackHole 设备，请安装 BlackHole 并设置为系统输出".to_string())?;
            Ok(vec![
                mic.name().map_err(|e| format!("获取设备名失败: {}", e))?,
                blackhole.name().map_err(|e| format!("获取设备名失败: {}", e))?,
            ])
        }
    }
}

fn recording_thread(
    device_names: Vec<String>,
    live_transcribe: bool,
    output_dir: PathBuf,
    stop_rx: mpsc::Receiver<()>,
    app_handle: AppHandle,
) -> Result<String, String> {
    std::fs::create_dir_all(&output_dir)
        .map_err(|e| format!("创建录音目录失败: {}", e))?;

    let mut streams: Vec<Stream> = Vec::new();
    let buffers: Vec<Arc<Mutex<Vec<f32>>>> = (0..device_names.len())
        .map(|_| Arc::new(Mutex::new(Vec::new())))
        .collect();

    // 统一使用第一个设备的采样率，避免多设备混音时采样率不一致
    let target_sample_rate = {
        let first = find_device(&device_names[0]).ok_or_else(|| "找不到首个音频设备".to_string())?;
        first
            .default_input_config()
            .map_err(|e| format!("获取设备配置失败: {}", e))?
            .sample_rate()
            .0
    };

    for (idx, name) in device_names.iter().enumerate() {
        let device = find_device(name)
            .ok_or_else(|| format!("找不到音频设备: {}", name))?;

        let default_config = device
            .default_input_config()
            .map_err(|e| format!("获取设备配置失败 {}: {}", name, e))?;

        let channels = default_config.channels() as usize;
        let sample_format = default_config.sample_format();
        let config = StreamConfig {
            channels: default_config.channels(),
            sample_rate: cpal::SampleRate(target_sample_rate),
            buffer_size: cpal::BufferSize::Default,
        };

        let buffer = buffers[idx].clone();

        let stream = match sample_format {
            SampleFormat::F32 => build_stream::<f32>(&device, &config, channels, buffer)?,
            SampleFormat::I16 => build_stream::<i16>(&device, &config, channels, buffer)?,
            SampleFormat::U16 => build_stream::<u16>(&device, &config, channels, buffer)?,
            _ => return Err(format!("不支持的采样格式: {:?}", sample_format)),
        };

        stream
            .play()
            .map_err(|e| format!("启动音频流失败: {}", e))?;
        streams.push(stream);
    }

    let mut slice_index: u32 = 0;
    let mut last_slice_time = SystemTime::now();
    let slice_duration = std::time::Duration::from_secs(5);
    let slice_samples = (target_sample_rate * slice_duration.as_secs() as u32) as usize;
    let volume_samples = (target_sample_rate / 10).max(1) as usize;

    loop {
        // 等待停止信号或切片时间到达
        let timeout = if live_transcribe {
            let elapsed = last_slice_time.elapsed().unwrap_or(slice_duration);
            let remaining = slice_duration.saturating_sub(elapsed);
            remaining
        } else {
            std::time::Duration::from_millis(100)
        };

        // 音量刷新间隔，独立于切片间隔，让电平显示更流畅
        let volume_interval = std::time::Duration::from_millis(50);
        let timeout = timeout.min(volume_interval);

        match stop_rx.recv_timeout(timeout) {
            Ok(()) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // 计算音量并 emit
                emit_volume(&buffers, volume_samples, &app_handle);

                // 检查是否需要切片
                if live_transcribe && last_slice_time.elapsed().unwrap_or(slice_duration) >= slice_duration {
                    save_slice(&buffers, &output_dir, target_sample_rate, slice_index, slice_samples, &app_handle);
                    slice_index += 1;
                    last_slice_time = SystemTime::now();
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // 停止音频流
    drop(streams);

    // 保存完整录音
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let filename = format!("recording_{}.wav", timestamp);
    let output_path = output_dir.join(&filename);

    let final_buffers: Vec<Vec<f32>> = buffers
        .iter()
        .map(|b| b.lock().unwrap().clone())
        .collect();

    if final_buffers.iter().all(|b| b.is_empty()) {
        return Err("没有录到任何音频".to_string());
    }

    let mixed = mix_buffers(&final_buffers);
    write_wav(&output_path, &mixed, target_sample_rate)?;

    Ok(output_path.to_string_lossy().to_string())
}

fn build_stream<T>(
    device: &Device,
    config: &StreamConfig,
    channels: usize,
    buffer: Arc<Mutex<Vec<f32>>>,
) -> Result<Stream, String>
where
    T: cpal::SizedSample + cpal::Sample,
    f32: cpal::FromSample<T>,
{
    let buffer_clone = buffer.clone();
    let stream = device
        .build_input_stream(
            config,
            move |data: &[T], _: &cpal::InputCallbackInfo| {
                let mut buf = buffer_clone.lock().unwrap();
                for chunk in data.chunks(channels.max(1)) {
                    if let Some(first) = chunk.first() {
                        buf.push(first.to_sample::<f32>());
                    }
                }
            },
            stream_error_callback,
            None,
        )
        .map_err(|e| format!("构建音频流失败: {}", e))?;
    Ok(stream)
}

fn stream_error_callback(err: cpal::StreamError) {
    eprintln!("音频流错误: {}", err);
}

fn emit_volume(buffers: &[Arc<Mutex<Vec<f32>>>], window_samples: usize, app_handle: &AppHandle) {
    let mut sum_squares: f64 = 0.0;
    let mut count: usize = 0;

    for buffer in buffers {
        let buf = buffer.lock().unwrap();
        let recent = buf.iter().rev().take(window_samples);
        for &sample in recent {
            sum_squares += (sample as f64) * (sample as f64);
            count += 1;
        }
    }

    if count == 0 {
        return;
    }

    let rms = (sum_squares / count as f64).sqrt() as f32;
    let db = 20.0 * rms.max(1e-10).log10();
    let level = rms.min(1.0).max(0.0);

    let _ = app_handle.emit("audio:volume", VolumeEvent { db, level });
}

fn save_slice(
    buffers: &[Arc<Mutex<Vec<f32>>>],
    output_dir: &Path,
    sample_rate: u32,
    index: u32,
    slice_samples: usize,
    app_handle: &AppHandle,
) {
    let slice_buffers: Vec<Vec<f32>> = buffers
        .iter()
        .map(|b| {
            let mut buf = b.lock().unwrap();
            let take = slice_samples.min(buf.len());
            buf.drain(..take).collect()
        })
        .collect();

    if slice_buffers.iter().all(|b| b.is_empty()) {
        return;
    }

    let mixed = mix_buffers(&slice_buffers);
    let filename = format!("slice_{:04}.wav", index);
    let path = output_dir.join(&filename);

    if write_wav(&path, &mixed, sample_rate).is_ok() {
        let _ = app_handle.emit(
            "audio:slice",
            SliceEvent {
                path: path.to_string_lossy().to_string(),
                index,
            },
        );
    }
}

fn mix_buffers(buffers: &[Vec<f32>]) -> Vec<f32> {
    let max_len = buffers.iter().map(|b| b.len()).max().unwrap_or(0);
    let count = buffers.len();
    let mut mixed = Vec::with_capacity(max_len);

    for i in 0..max_len {
        let sum: f32 = buffers
            .iter()
            .map(|b| b.get(i).copied().unwrap_or(0.0))
            .sum();
        mixed.push((sum / count as f32).clamp(-1.0, 1.0));
    }

    mixed
}

fn write_wav(path: &Path, samples: &[f32], sample_rate: u32) -> Result<(), String> {
    let spec = WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };

    let file = File::create(path).map_err(|e| format!("创建 WAV 文件失败: {}", e))?;
    let mut writer = WavWriter::new(BufWriter::new(file), spec)
        .map_err(|e| format!("创建 WAV writer 失败: {}", e))?;

    for &sample in samples {
        let int_sample = (sample * i16::MAX as f32) as i16;
        writer
            .write_sample(int_sample)
            .map_err(|e| format!("写入 WAV 失败: {}", e))?;
    }

    writer
        .finalize()
        .map_err(|e| format!("finalize WAV 失败: {}", e))?;
    Ok(())
}
