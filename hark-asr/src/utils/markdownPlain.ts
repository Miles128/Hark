/**
 * Markdown → 朗读文本：不念格式符号，按结构插入停顿。
 *
 * 停顿约定（两端 TTS 都认标点）：
 * - 标题后：较长停顿（……）
 * - 段落 / 分隔线：句号停顿（。）
 * - 列表项之间：分号停顿（；）
 * - 行内强调等：只保留文字，不加额外停顿
 */

const LONG = "……";
const MED = "。";
const SHORT = "；";

function stripInline(s: string): string {
  let t = s;
  t = t.replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1");
  t = t.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1");
  t = t.replace(/\[([^\]]+)\]\[[^\]]*\]/g, "$1");
  t = t.replace(/\[\^[^\]]+\]/g, "");
  t = t.replace(/(\*\*|__)(.*?)\1/g, "$2");
  t = t.replace(/(\*|_)(.*?)\1/g, "$2");
  t = t.replace(/~~(.*?)~~/g, "$1");
  t = t.replace(/`([^`]+)`/g, "$1");
  t = t.replace(/<\/?[a-zA-Z][^>]*>/g, "");
  return t.replace(/[ \t]{2,}/g, " ").trim();
}

function endsWithPause(s: string): boolean {
  return /[。！？!?…；;，,：:]$/.test(s.trim());
}

function joinPause(parts: string[]): string {
  return parts
    .map((p) => p.trim())
    .filter(Boolean)
    .join("")
    .replace(/。{2,}/g, "。")
    .replace(/；{2,}/g, "；")
    .replace(/，{2,}/g, "，")
    .replace(/(……)+/g, "……")
    .replace(/\s+/g, " ")
    .trim();
}

/** 将 Markdown（或纯文本）转为适合朗读的正文，按格式给停顿。 */
export function markdownToSpeech(input: string): string {
  let raw = input.replace(/\r\n/g, "\n");
  raw = raw.replace(/^---\n[\s\S]*?\n---\n?/, "");
  raw = raw.replace(/<!--[\s\S]*?-->/g, "");

  const parts: string[] = [];
  const lines = raw.split("\n");
  let i = 0;
  let inFence = false;

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // fenced code：跳过内容，给一次中等停顿
    if (/^```|^~~~/.test(trimmed)) {
      if (!inFence) {
        inFence = true;
      } else {
        inFence = false;
        parts.push(MED);
      }
      i += 1;
      continue;
    }
    if (inFence) {
      i += 1;
      continue;
    }

    // blank line → 段落停顿
    if (!trimmed) {
      if (parts.length && !endsWithPause(parts[parts.length - 1] ?? "")) {
        parts.push(MED);
      }
      i += 1;
      continue;
    }

    // horizontal rule
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      parts.push(LONG);
      i += 1;
      continue;
    }

    // heading
    const heading = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      const level = heading[1].length;
      const text = stripInline(heading[2]);
      if (text) {
        parts.push(text);
        parts.push(level <= 2 ? LONG : MED);
      }
      i += 1;
      continue;
    }

    // blockquote
    if (/^>\s?/.test(trimmed)) {
      const text = stripInline(trimmed.replace(/^(>\s?)+/, ""));
      if (text) {
        parts.push(text);
        if (!endsWithPause(text)) parts.push(MED);
      }
      i += 1;
      continue;
    }

    // table separator — skip
    if (/^\|?[\t ]*:?-{3,}:?[\t ]*(\|[\t ]*:?-{3,}:?[\t ]*)+\|?\s*$/.test(trimmed)) {
      i += 1;
      continue;
    }

    // table row
    if (/^\|.+\|/.test(trimmed)) {
      const cells = trimmed
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|")
        .map((c) => stripInline(c))
        .filter(Boolean);
      if (cells.length) {
        parts.push(cells.join("，"));
        parts.push(SHORT);
      }
      i += 1;
      continue;
    }

    // list / task
    const list = trimmed.match(/^([-*+]|\d+\.)\s+(?:\[[ xX]\]\s+)?(.*)$/);
    if (list) {
      const text = stripInline(list[2]);
      if (text) {
        parts.push(text);
        parts.push(endsWithPause(text) ? "" : SHORT);
      }
      i += 1;
      continue;
    }

    // reference / footnote definition — skip
    if (/^\[([^\]]+)\]:\s+\S+/.test(trimmed) || /^\[\^[^\]]+\]:/.test(trimmed)) {
      i += 1;
      continue;
    }

    // normal paragraph line
    const text = stripInline(trimmed);
    if (text) {
      parts.push(text);
      // 若下一行是空行或结构块，稍后空白处理会加句号；同行续写加空格
      const next = lines[i + 1]?.trim() ?? "";
      if (!next) {
        if (!endsWithPause(text)) parts.push(MED);
      } else if (/^(#{1,6}\s|([-*+]|\d+\.)\s|>|```|~~~|(-{3,}|\*{3,}|_{3,})$)/.test(next)) {
        if (!endsWithPause(text)) parts.push(MED);
      } else {
        parts.push(" ");
      }
    }
    i += 1;
  }

  return joinPause(parts);
}
