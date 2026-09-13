import Foundation

/// 自动保存：对齐 Rust `format_auto_save_text` + `do_auto_save` + `start_auto_save_loop`。
///
/// 转写记录本身在两个版本里都不入库（Rust 只有内存态 `Mutex<Vec<TranscriptSegment>>`），
/// 这个每 N 秒覆盖写的 `hark-auto-save.{txt,md}` 才是唯一的持久产物。
enum AutoSaveText {
    static func render(_ segments: [Segment], format: String) -> String {
        if format == "md" {
            // md 分支不 trim 段落文本，与 Rust 一致。
            var out = "# Hark 自动保存\n\n"
            for seg in segments {
                out += "## 段落 \(seg.index + 1)\n\n\(seg.text)\n\n"
            }
            return out
        }
        return segments.map { $0.text.trimmedForStore }.joined(separator: "\n\n")
    }
}

@MainActor
final class AutoSaveLoop {
    private var task: Task<Void, Never>?
    private var lastWrittenText: String?
    private let dir: URL

    init(dir: URL = HarkPaths.autoSave) {
        self.dir = dir
    }

    /// 间隔热更新：每轮重新读取，0 表示关闭但仍以 1 秒轮询（Rust 行为）。
    func start(intervalProvider: @escaping @MainActor () -> (interval: UInt64, format: String),
               segmentsProvider: @escaping @MainActor () -> [Segment]) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let (interval, format) = intervalProvider()
                if interval == 0 {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                try? await Task.sleep(for: .seconds(TimeInterval(interval)))
                guard !Task.isCancelled else { break }
                self?.save(segments: segmentsProvider(), format: format)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// 空转写不写文件；内容未变化不重复写（Rust 用 DefaultHasher，这里直接比字符串，
    /// 哈希本就只活在内存里，跨进程无兼容问题）。
    @discardableResult
    func save(segments: [Segment], format: String) -> URL? {
        guard !segments.isEmpty else { return nil }
        let text = AutoSaveText.render(segments, format: format)
        guard text != lastWrittenText else { return nil }
        HarkPaths.ensure(dir)
        let url = dir.appendingPathComponent("hark-auto-save.\(format == "md" ? "md" : "txt")")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        lastWrittenText = text
        return url
    }
}
