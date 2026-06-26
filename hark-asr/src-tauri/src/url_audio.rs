use std::path::PathBuf;
use std::process::Command;

fn find_yt_dlp() -> Result<String, String> {
    // 尝试直接用 yt-dlp 命令（如果在 PATH 里）
    if Command::new("yt-dlp")
        .arg("--version")
        .output()
        .is_ok()
    {
        return Ok("yt-dlp".to_string());
    }

    // 尝试常见安装路径
    let candidates = &[
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
    ];

    for path in candidates {
        if std::path::Path::new(path).exists() {
            return Ok(path.to_string());
        }
    }

    // 最后尝试通过 python3 -m yt_dlp 调用
    if Command::new("python3")
        .args(["-m", "yt_dlp", "--version"])
        .output()
        .is_ok()
    {
        return Ok("python3".to_string());
    }

    Err("未找到 yt-dlp。请运行: brew install yt-dlp".to_string())
}

fn build_yt_dlp_cmd(bin: &str, output_template: &str, url: &str) -> Command {
    let mut cmd = if bin == "python3" {
        let mut c = Command::new("python3");
        c.arg("-m").arg("yt_dlp");
        c
    } else {
        Command::new(bin)
    };

    cmd.args([
        "-x",
        "--audio-format",
        "wav",
        "--audio-quality",
        "0",
        "--no-playlist",
        "--no-simulate",
        "--print",
        "after_move:filepath",
        "-o",
        output_template,
        url,
    ]);

    cmd
}

pub fn download_audio(url: &str, output_dir: &PathBuf) -> Result<PathBuf, String> {
    std::fs::create_dir_all(output_dir)
        .map_err(|e| format!("创建下载目录失败: {}", e))?;

    let yt_dlp_bin = find_yt_dlp()?;
    let output_template = output_dir.join("download_%(id)s.%(ext)s");
    let template_str = output_template.to_string_lossy().to_string();

    let status = build_yt_dlp_cmd(&yt_dlp_bin, &template_str, url)
        .output()
        .map_err(|e| format!("运行 yt-dlp 失败: {}。请确认 yt-dlp 已正确安装。", e))?;

    if !status.status.success() {
        let stderr = String::from_utf8_lossy(&status.stderr);
        return Err(format!("下载音频失败: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&status.stdout).trim().to_string();

    if stdout.is_empty() {
        return Err("下载完成但未找到输出文件路径".to_string());
    }

    let filepath = PathBuf::from(&stdout);

    if !filepath.exists() {
        return Err(format!("下载的文件不存在: {}", stdout));
    }

    Ok(filepath)
}
