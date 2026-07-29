//! Microsoft Edge TTS（edge-tts）。

use super::TtsVoice;
use crate::asr::pylibs;
use serde_json::Value;

pub fn is_installed() -> bool {
    pylibs::is_package_installed("edge_tts")
}

pub fn install_hint() -> String {
    "pip install --target=pylibs edge-tts".to_string()
}

pub async fn list_voices() -> Result<Vec<TtsVoice>, String> {
    tokio::task::spawn_blocking(list_voices_blocking)
        .await
        .map_err(|e| format!("列音色任务被中断: {:?}", e))?
}

fn list_voices_blocking() -> Result<Vec<TtsVoice>, String> {
    if !is_installed() {
        return Err(format!("未安装 edge-tts。请运行：\n  {}", install_hint()));
    }

    let script = r#"
import asyncio, json, edge_tts

async def main():
    voices = await edge_tts.list_voices()
    out = []
    for v in voices:
        out.append({
            "id": v.get("ShortName", ""),
            "name": v.get("FriendlyName") or v.get("ShortName", ""),
            "locale": v.get("Locale", ""),
            "gender": v.get("Gender", ""),
        })
    print(json.dumps(out, ensure_ascii=False))

asyncio.run(main())
"#;

    let stdout = pylibs::run_python(script, &[])?;
    let values: Vec<Value> =
        serde_json::from_str(&stdout).map_err(|e| format!("解析音色列表失败: {}", e))?;

    Ok(values
        .into_iter()
        .filter_map(|v| {
            let id = v.get("id")?.as_str()?.to_string();
            if id.is_empty() {
                return None;
            }
            Some(TtsVoice {
                name: v
                    .get("name")
                    .and_then(|x| x.as_str())
                    .unwrap_or(&id)
                    .to_string(),
                locale: v
                    .get("locale")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string(),
                gender: v
                    .get("gender")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .to_string(),
                id,
            })
        })
        .collect())
}

pub async fn synthesize(text: &str, voice: &str, rate: &str, output_path: &str) -> Result<(), String> {
    let text = text.to_string();
    let voice = voice.to_string();
    let rate = rate.to_string();
    let output_path = output_path.to_string();
    tokio::task::spawn_blocking(move || synthesize_blocking(&text, &voice, &rate, &output_path))
        .await
        .map_err(|e| format!("合成任务被中断: {:?}", e))?
}

fn synthesize_blocking(text: &str, voice: &str, rate: &str, output_path: &str) -> Result<(), String> {
    if !is_installed() {
        return Err(format!("未安装 edge-tts。请运行：\n  {}", install_hint()));
    }

    let script = format!(
        r#"
import asyncio, edge_tts

text = {text}
voice = {voice}
rate = {rate}
output_path = {output}

async def main():
    communicate = edge_tts.Communicate(text, voice, rate=rate)
    await communicate.save(output_path)
    print(output_path)

asyncio.run(main())
"#,
        text = python_str(text),
        voice = python_str(voice),
        rate = python_str(rate),
        output = python_str(output_path),
    );

    pylibs::run_python(&script, &[]).map(|_| ())
}

fn python_str(s: &str) -> String {
    format!("{:?}", s)
}
