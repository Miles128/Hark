use crate::asr::pylibs;
use std::path::PathBuf;
use std::process::Command;

/// 找到 yt-dlp 调用方式，优先用项目内 pylibs 的 yt_dlp 模块。
///
/// 返回 `(命令构造器工厂, 描述)`：第一个元素是一个接受 url/output_template
/// 的闭包，返回配置好参数的 `Command`。
enum YtDlpRunner {
    /// 项目 pylibs 中的 yt_dlp 模块：`python -m yt_dlp ...`
    PylibsModule,
    /// PATH 中的 yt-dlp 二进制（备用，便于 dev 时已 brew install 的场景）
    SystemBinary(String),
}

fn find_yt_dlp() -> Result<YtDlpRunner, String> {
    // 1. 优先用项目 pylibs 中的 yt_dlp 模块
    if pylibs::is_package_installed("yt_dlp") {
        return Ok(YtDlpRunner::PylibsModule);
    }

    // 2. PATH 中的 yt-dlp 二进制（系统已 brew install 等场景）
    if Command::new("yt-dlp").arg("--version").output().is_ok() {
        return Ok(YtDlpRunner::SystemBinary("yt-dlp".to_string()));
    }

    // 3. 常见安装路径
    let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"];
    for path in candidates {
        if std::path::Path::new(path).exists() {
            return Ok(YtDlpRunner::SystemBinary(path.to_string()));
        }
    }

    Err("未找到 yt-dlp。请在项目根目录运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs yt-dlp".to_string())
}

fn build_yt_dlp_cmd(runner: &YtDlpRunner, output_template: &str, url: &str) -> Result<Command, String> {
    let mut cmd = match runner {
        YtDlpRunner::PylibsModule => {
            // 通过 pylibs 共享工具找到的 python + PYTHONPATH
            let python = pylibs::find_system_python()
                .ok_or_else(|| "未找到系统 Python 3 解释器".to_string())?;
            let pylibs_dir = pylibs::pylibs_dir()
                .ok_or_else(|| "未找到项目 pylibs 目录".to_string())?;
            let mut c = Command::new(python);
            c.arg("-s").arg("-m").arg("yt_dlp");
            c.env("PYTHONPATH", pylibs_dir.to_string_lossy().to_string());
            c.env("PYTHONNOUSERSITE", "1");
            c.env("PYTHONUNBUFFERED", "1");
            c
        }
        YtDlpRunner::SystemBinary(bin) => Command::new(bin),
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

    Ok(cmd)
}

pub fn download_audio(url: &str, output_dir: &PathBuf) -> Result<PathBuf, String> {
    std::fs::create_dir_all(output_dir)
        .map_err(|e| format!("创建下载目录失败: {}", e))?;

    let runner = find_yt_dlp()?;
    let output_template = output_dir.join("download_%(id)s.%(ext)s");
    let template_str = output_template.to_string_lossy().to_string();

    let mut cmd = build_yt_dlp_cmd(&runner, &template_str, url)?;
    let status = cmd
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
