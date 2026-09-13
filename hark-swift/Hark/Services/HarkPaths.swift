import Foundation

/// 与 Tauri 版路径解析对齐的落盘位置。
///
/// macOS 上 Tauri 的 `app_data_dir()` 与 `app_config_dir()` 都落在
/// `~/Library/Application Support/<identifier>`，`audio_dir()` 是 `~/Music`（不拼 identifier，
/// Rust 侧再自己 `.join("hark-asr")`）。标识符沿用 `com.sihai.harkasr`，
/// 因此 SwiftUI 版与 Tauri 版读写的是同一份 profiles.db 和 settings.json。
enum HarkPaths {
    static let identifier = "com.sihai.harkasr"

    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// app_data_dir == app_config_dir
    static let appData = appSupport.appendingPathComponent(identifier, isDirectory: true)

    static var profilesDB: URL { appData.appendingPathComponent("profiles.db") }
    static var settingsFile: URL { appData.appendingPathComponent("settings.json") }

    /// audio_dir()/hark-asr —— 录音、TTS 合成、下载、自动保存的公共根目录。
    static let music = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("hark-asr", isDirectory: true)

    static var recordings: URL { music }
    static var tts: URL { music.appendingPathComponent("tts", isDirectory: true) }
    static var downloads: URL { music.appendingPathComponent("downloads", isDirectory: true) }
    static var autoSave: URL { music.appendingPathComponent("auto-save", isDirectory: true) }

    /// 建目录并返回自身，等价于 Rust 的 create_dir_all(...).ok()。
    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
