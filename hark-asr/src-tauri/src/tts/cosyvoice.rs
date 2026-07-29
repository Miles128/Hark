//! 阿里云 DashScope CosyVoice TTS。

use super::TtsVoice;
use crate::asr::pylibs;

/// CosyVoice 常用音色（v1 / v2 常用 id）。
const VOICES: &[(&str, &str, &str, &str)] = &[
    ("longxiaochun", "龙小淳（女声·知性）", "zh-CN", "Female"),
    ("longxiaoxia", "龙小夏（女声·温柔）", "zh-CN", "Female"),
    ("longxiaocheng", "龙小诚（男声·沉稳）", "zh-CN", "Male"),
    ("longxiaobai", "龙小白（女声·活泼）", "zh-CN", "Female"),
    ("longyuan", "龙媛（女声·温暖）", "zh-CN", "Female"),
    ("longhua", "龙华（女声·甜美女声）", "zh-CN", "Female"),
    ("longshu", "龙书（男声·磁性）", "zh-CN", "Male"),
    ("loongstella", "Stella（女声·英文）", "en-US", "Female"),
    ("loongbella", "Bella（女声·英文）", "en-US", "Female"),
];

pub fn is_installed() -> bool {
    pylibs::is_package_installed("dashscope")
}

pub fn install_hint() -> String {
    "pip install --target=pylibs dashscope".to_string()
}

pub fn list_voices() -> Vec<TtsVoice> {
    VOICES
        .iter()
        .map(|(id, name, locale, gender)| TtsVoice {
            id: id.to_string(),
            name: name.to_string(),
            locale: locale.to_string(),
            gender: gender.to_string(),
        })
        .collect()
}

pub async fn synthesize(
    text: &str,
    api_key: &str,
    voice: &str,
    speech_rate: f64,
    output_path: &str,
) -> Result<(), String> {
    let text = text.to_string();
    let api_key = api_key.to_string();
    let voice = voice.to_string();
    let output_path = output_path.to_string();
    tokio::task::spawn_blocking(move || {
        synthesize_blocking(&text, &api_key, &voice, speech_rate, &output_path)
    })
    .await
    .map_err(|e| format!("合成任务被中断: {:?}", e))?
}

fn synthesize_blocking(
    text: &str,
    api_key: &str,
    voice: &str,
    speech_rate: f64,
    output_path: &str,
) -> Result<(), String> {
    if !is_installed() {
        return Err(format!("未安装 dashscope。请运行：\n  {}", install_hint()));
    }

    let rate = speech_rate.clamp(0.5, 2.0);

    let script = format!(
        r#"
import dashscope
from dashscope.audio.tts_v2 import SpeechSynthesizer

dashscope.api_key = {api_key}
text = {text}
voice = {voice}
output_path = {output}
speech_rate = {rate}

synthesizer = SpeechSynthesizer(model="cosyvoice-v1", voice=voice, speech_rate=speech_rate)
audio = synthesizer.call(text)
if audio is None:
    raise RuntimeError("CosyVoice 返回空音频，请检查 API Key / 音色 / 额度")

data = audio if isinstance(audio, (bytes, bytearray)) else bytes(audio)
with open(output_path, "wb") as f:
    f.write(data)
print(output_path)
"#,
        api_key = python_str(api_key),
        text = python_str(text),
        voice = python_str(voice),
        output = python_str(output_path),
        rate = rate,
    );

    pylibs::run_python(&script, &[]).map(|_| ())
}

fn python_str(s: &str) -> String {
    format!("{:?}", s)
}
