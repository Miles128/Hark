//! 项目内 Python 依赖（pylibs）共享工具。
//!
//! 所有 ASR 相关 Python 包通过 `pip install --target=pylibs` 安装到
//! 项目根目录的 `pylibs/`，运行时通过 `PYTHONPATH` 注入，不依赖虚拟环境。

use std::path::PathBuf;

/// 定位项目根目录（包含 `pylibs/` 和 `src-tauri/` 的目录）。
///
/// 查找顺序：
/// 1. 当前工作目录（`npm run tauri dev` 的 cwd）
/// 2. 相对于当前可执行文件上溯（dev: `target/debug/hark-asr` -> `../../..`）
/// 3. macOS 打包后：exe 同级 `../Resources`
pub fn find_project_root() -> Option<PathBuf> {
    // 1. cwd
    if let Ok(cwd) = std::env::current_dir() {
        if is_project_root(&cwd) {
            return Some(cwd);
        }
        // 兼容 cargo test 场景：cwd 在 src-tauri/ 时上溯一层到 hark-asr/
        if cwd.file_name().and_then(|n| n.to_str()) == Some("src-tauri") {
            if let Some(parent) = cwd.parent() {
                if is_project_root(parent) {
                    return Some(parent.to_path_buf());
                }
            }
        }
    }

    // 2. 相对于 exe：dev 时为 target/debug/hark-asr -> ../../../hark-asr
    if let Ok(exe) = std::env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            // dev：target/debug -> 上溯三级到 hark-asr/
            let candidate = exe_dir.join("../../..");
            if let Ok(c) = candidate.canonicalize() {
                if is_project_root(&c) {
                    return Some(c);
                }
            }
            // 退路：原始路径也试一下（符号链接场景）
            if is_project_root(&candidate) {
                return Some(candidate);
            }

            // 3. macOS 打包后：bin 在 .app/Contents/MacOS/，Resources 在 .app/Contents/Resources/
            let candidate = exe_dir.join("../Resources");
            if is_project_root(&candidate) {
                return Some(candidate);
            }
        }
    }

    None
}

fn is_project_root(p: &std::path::Path) -> bool {
    // 同时存在 src-tauri 标志这是 hark-asr 项目根目录
    p.join("src-tauri").is_dir()
}

/// 返回项目 `pylibs/` 目录绝对路径。
pub fn pylibs_dir() -> Option<PathBuf> {
    find_project_root().map(|root| root.join("pylibs"))
}

/// 找一个可用的系统 Python 3 解释器。
///
/// 优先选择 homebrew 的 python3.12（最稳定，pylibs 即为此版本所装）。
/// 回退到 PATH 中的 python3。
pub fn find_system_python() -> Option<String> {
    let candidates: [&str; 5] = [
        "/opt/homebrew/bin/python3.12",
        "/usr/local/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/usr/local/bin/python3.11",
        "python3",
    ];
    for &c in &candidates {
        if let Ok(output) = std::process::Command::new(c).arg("--version").output() {
            if output.status.success() {
                return Some(c.to_string());
            }
        }
    }
    None
}

/// 检查 pylibs 中是否已安装某包（通过目录是否存在判断）。
pub fn is_package_installed(package_dir: &str) -> bool {
    pylibs_dir()
        .map(|p| p.join(package_dir).is_dir())
        .unwrap_or(false)
}

/// 用 `PYTHONPATH=pylibs` 运行 Python 脚本，返回 stdout（已 trim）。
///
/// 同时设置 `PYTHONNOUSERSITE=1` 禁用 `~/Library/Python/.../site-packages`，
/// 避免用户级包与 pylibs 冲突；系统 site-packages 仍保留（提供 numpy 等基础依赖）。
pub fn run_python(script: &str, extra_env: &[(&str, &str)]) -> Result<String, String> {
    run_python_with_stderr(script, extra_env).map(|(stdout, _)| stdout)
}

/// 同上，但同时返回 stderr（用于调试）。
pub fn run_python_with_stderr(
    script: &str,
    extra_env: &[(&str, &str)],
) -> Result<(String, String), String> {
    let python = find_system_python().ok_or_else(|| {
        "未找到系统 Python 3。请安装 homebrew python3.12：brew install python@3.12".to_string()
    })?;
    let pylibs = pylibs_dir().ok_or_else(|| {
        "未找到项目 pylibs 目录。请在 hark-asr/ 下运行：\n  /opt/homebrew/bin/python3.12 -m pip install --target=pylibs mlx-qwen3-asr \"mlx-audio[stt]\" yt-dlp"
            .to_string()
    })?;
    let pylibs_str = pylibs.to_string_lossy().to_string();

    let mut cmd = std::process::Command::new(&python);
    cmd.args(["-s", "-c", script]);
    cmd.env("PYTHONPATH", &pylibs_str);
    cmd.env("PYTHONNOUSERSITE", "1");
    // 让 stdout/stderr 不缓冲，便于实时观察
    cmd.env("PYTHONUNBUFFERED", "1");

    for (k, v) in extra_env {
        cmd.env(k, v);
    }

    let output = cmd.output().map_err(|e| format!("运行 Python 失败: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();

    if !output.status.success() {
        return Err(format!(
            "Python 执行失败（exit={}）:\n--- stdout ---\n{}\n--- stderr ---\n{}",
            output.status, stdout, stderr
        ));
    }

    Ok((stdout, stderr))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_system_python_returns_some() {
        // 测试环境必然有 python3
        assert!(find_system_python().is_some());
    }

    #[test]
    fn run_python_prints_ok() {
        let result = run_python("print('ok')", &[]);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "ok");
    }
}
