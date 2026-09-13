import Foundation

/// 对齐 Rust `url_audio.rs`：yt-dlp 抽音频，优先用项目 pylibs 里的 yt_dlp 模块。
enum YtDlpRunner {
    case pylibsModule(python: String, pylibs: URL)
    case systemBinary(path: String)
}

struct YtDlpInvocation {
    let executable: String
    let arguments: [String]
    /// nil 表示沿用父进程环境。
    let environment: [String: String]?
}

enum YtDlpError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

enum UrlAudioDownloader {
    static let systemBinaryCandidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]

    /// 与 Rust 的 find_yt_dlp 同样的三级探测：pylibs 模块 → PATH → 常见安装路径。
    static func findRunner(bridge: PythonBridge?) -> YtDlpRunner? {
        if let bridge, bridge.isPackageInstalled("yt_dlp"),
           let python = PythonBridge.findPython() {
            return .pylibsModule(python: python, pylibs: bridge.pylibsDir)
        }
        if let path = PythonBridge.which("yt-dlp") {
            return .systemBinary(path: path)
        }
        for candidate in systemBinaryCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return .systemBinary(path: candidate)
        }
        return nil
    }

    static func invocation(runner: YtDlpRunner, outputTemplate: String, url: String) throws -> YtDlpInvocation {
        let core = [
            "-x",
            "--audio-format", "wav",
            "--audio-quality", "0",
            "--no-playlist",
            "--no-simulate",
            "--print", "after_move:filepath",
            "-o", outputTemplate,
            url,
        ]
        switch runner {
        case .pylibsModule(let python, let pylibs):
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = pylibs.path
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONUNBUFFERED"] = "1"
            return YtDlpInvocation(
                executable: python,
                arguments: ["-s", "-m", "yt_dlp"] + core,
                environment: env
            )
        case .systemBinary(let path):
            return YtDlpInvocation(executable: path, arguments: core, environment: nil)
        }
    }

    /// 下载并抽出 wav，返回 yt-dlp 打印的最终文件路径。阻塞，请在后台线程调用。
    static func download(url: String, outputDir: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            throw YtDlpError.message("创建下载目录失败: \(error.localizedDescription)")
        }

        let bridge = try? PythonBridge()
        guard let runner = findRunner(bridge: bridge) else {
            throw YtDlpError.message(
                "未找到 yt-dlp。请在项目根目录运行：/opt/homebrew/bin/python3.12 -m pip install --target=pylibs yt-dlp"
            )
        }
        let template = outputDir
            .appendingPathComponent("download_%(id)s.%(ext)s")
            .path
        let cmd = try invocation(runner: runner, outputTemplate: template, url: url)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd.executable)
        process.arguments = cmd.arguments
        if let env = cmd.environment { process.environment = env }

        let stdout = Pipe()
        // 同 PythonBridge：yt-dlp 的下载进度走 stderr，可能超过管道缓冲。
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-ytdlp-\(UUID().uuidString).stderr")
        try Data().write(to: errURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = stdout
        process.standardError = errHandle

        defer {
            stdout.fileHandleForReading.closeFile()
            errHandle.closeFile()
            try? FileManager.default.removeItem(at: errURL)
        }

        do {
            try process.run()
        } catch {
            throw YtDlpError.message(
                "运行 yt-dlp 失败: \(error.localizedDescription)。请确认 yt-dlp 已正确安装。"
            )
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: (try? Data(contentsOf: errURL)) ?? Data(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw YtDlpError.message("下载音频失败: \(stderr)")
        }

        let stdoutText = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stdoutText.isEmpty else {
            throw YtDlpError.message("下载完成但未找到输出文件路径")
        }
        let fileURL = URL(fileURLWithPath: stdoutText)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw YtDlpError.message("下载的文件不存在: \(stdoutText)")
        }
        return fileURL
    }
}
