import Foundation

/// Markdown → 朗读文本：不念格式符号，按结构插入停顿（移植 markdownPlain.ts）。
/// 标题后较长停顿（……），段落/分隔线句号（。），列表项间分号（；）。
enum MarkdownPlain {
    private static let long = "……"
    private static let med = "。"
    private static let short = "；"

    private static let imageLink = /!\[([^\]]*)\]\([^)]+\)/
    private static let inlineLink = /\[([^\]]+)\]\([^)]+\)/
    private static let refLink = /\[([^\]]+)\]\[[^\]]*\]/
    private static let footnoteRef = /\[\^[^\]]+\]/
    private static let bold = /(\*\*|__)(.*?)\1/
    private static let italic = /(\*|_)(.*?)\1/
    private static let strike = /~~(.*?)~~/
    private static let code = /`([^`]+)`/
    private static let htmlTag = /<\/?[a-zA-Z][^>]*>/
    private static let multiSpace = /[ \t]{2,}/

    private static let pauseEnd = /[。！？!?…；;，,：:]$/
    private static let heading = /^(#{1,6})\s+(.*)$/
    private static let hr = /^(-{3,}|\*{3,}|_{3,})$/
    private static let blockquote = /^>\s?/
    private static let tableSeparator = /^\|?[\t ]*:?-{3,}:?[\t ]*(\|[\t ]*:?-{3,}:?[\t ]*)+\|?\s*$/
    private static let tableRow = /^\|.+\|/
    private static let listItem = /^([-*+]|\d+\.)\s+(?:\[[xX ]\]\s+)?(.*)$/
    private static let refDef = /^\[([^\]]+)\]:\s+\S+/
    private static let footnoteDef = /^\[\^[^\]]+\]:/
    private static let fence = /^(```|~~~)/
    private static let structural = /^(#{1,6}\s|([-*+]|\d+\.)\s|>|```|~~~|(-{3,}|\*{3,}|_{3,})$)/

    private static func stripInline(_ s: String) -> String {
        var t = s
        t = t.replacing(imageLink) { String($0.1) }
        t = t.replacing(inlineLink) { String($0.1) }
        t = t.replacing(refLink) { String($0.1) }
        t = t.replacing(footnoteRef, with: "")
        t = t.replacing(bold) { String($0.2) }
        t = t.replacing(italic) { String($0.2) }
        t = t.replacing(strike) { String($0.1) }
        t = t.replacing(code) { String($0.1) }
        t = t.replacing(htmlTag, with: "")
        return t.replacing(multiSpace, with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func endsWithPause(_ s: String) -> Bool {
        s.firstMatch(of: pauseEnd) != nil
    }

    private static func joinPause(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined()
            .replacing(/。{2,}/, with: "。")
            .replacing(/；{2,}/, with: "；")
            .replacing(/，{2,}/, with: "，")
            .replacing(/(……)+/, with: "……")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func toSpeech(_ input: String) -> String {
        var raw = input.replacingOccurrences(of: "\r\n", with: "\n")
        // YAML frontmatter
        if let range = raw.range(of: "^---\n[\\s\\S]*?\\n---\\n?", options: .regularExpression) {
            raw.replaceSubrange(range, with: "")
        }
        raw = raw.replacing(/<!--[\s\S]*?-->/, with: "")

        var parts: [String] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        var inFence = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.firstMatch(of: fence) != nil {
                if !inFence {
                    inFence = true
                } else {
                    inFence = false
                    parts.append(med)
                }
                i += 1
                continue
            }
            if inFence {
                i += 1
                continue
            }

            if trimmed.isEmpty {
                if let last = parts.last, !endsWithPause(last) {
                    parts.append(med)
                }
                i += 1
                continue
            }

            if trimmed.firstMatch(of: hr) != nil {
                parts.append(long)
                i += 1
                continue
            }

            if let h = trimmed.firstMatch(of: heading) {
                let level = h.1.count
                let text = stripInline(String(h.2))
                if !text.isEmpty {
                    parts.append(text)
                    parts.append(level <= 2 ? long : med)
                }
                i += 1
                continue
            }

            if trimmed.firstMatch(of: blockquote) != nil {
                let text = stripInline(trimmed.replacing(blockquoteStart, with: ""))
                if !text.isEmpty {
                    parts.append(text)
                    if !endsWithPause(text) { parts.append(med) }
                }
                i += 1
                continue
            }

            if trimmed.firstMatch(of: tableSeparator) != nil {
                i += 1
                continue
            }

            if trimmed.firstMatch(of: tableRow) != nil {
                var t = trimmed
                if t.hasPrefix("|") { t.removeFirst() }
                if t.hasSuffix("|") { t.removeLast() }
                let cells = t.split(separator: "|", omittingEmptySubsequences: true)
                    .map { stripInline(String($0)) }
                    .filter { !$0.isEmpty }
                if !cells.isEmpty {
                    parts.append(cells.joined(separator: "，"))
                    parts.append(short)
                }
                i += 1
                continue
            }

            if let list = trimmed.firstMatch(of: listItem) {
                let text = stripInline(String(list.2))
                if !text.isEmpty {
                    parts.append(text)
                    if !endsWithPause(text) { parts.append(short) }
                }
                i += 1
                continue
            }

            if trimmed.firstMatch(of: refDef) != nil || trimmed.firstMatch(of: footnoteDef) != nil {
                i += 1
                continue
            }

            let text = stripInline(trimmed)
            if !text.isEmpty {
                parts.append(text)
                let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
                if next.isEmpty {
                    if !endsWithPause(text) { parts.append(med) }
                } else if next.firstMatch(of: structural) != nil {
                    if !endsWithPause(text) { parts.append(med) }
                } else {
                    parts.append(" ")
                }
            }
            i += 1
        }

        return joinPause(parts)
    }
}

private let blockquoteStart = /^(>\s?)+/
