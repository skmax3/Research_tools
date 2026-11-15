import Foundation

/// テキストの変換（Web 版 clipboard/ の「整える」「表 →」と同じもの）
enum TextTransform: String, CaseIterable, Identifiable {
    case joinLines, toHalf, kanaFull, trimSpaces, markdown, latex, csv, tsv
    var id: String { rawValue }

    var title: String {
        switch self {
        case .joinLines: return "改行を整理（PDF のコピー）"
        case .toHalf: return "英数を半角に"
        case .kanaFull: return "半角カナを全角に"
        case .trimSpaces: return "余分な空白・空行を削除"
        case .markdown: return "表 → Markdown"
        case .latex: return "表 → LaTeX"
        case .csv: return "表 → CSV"
        case .tsv: return "表 → タブ区切り（Excel 用）"
        }
    }

    /// 表（Excel のコピーや CSV）向けの変換か
    var isTable: Bool {
        switch self {
        case .markdown, .latex, .csv, .tsv: return true
        default: return false
        }
    }

    func apply(_ s: String) -> String {
        switch self {
        case .joinLines: return Transforms.joinLines(s)
        case .toHalf: return Transforms.toHalf(s)
        case .kanaFull: return Transforms.kanaFull(s)
        case .trimSpaces: return Transforms.trimSpaces(s)
        case .markdown: return Transforms.toMarkdown(s)
        case .latex: return Transforms.toLatex(s)
        case .csv: return Transforms.toCSV(s)
        case .tsv: return Transforms.toTSV(s)
        }
    }
}

enum Transforms {
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func trimTrailing(_ s: String, _ set: Set<Character>) -> String {
        var t = Substring(s)
        while let last = t.last, set.contains(last) { t.removeLast() }
        return String(t)
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    private static func isLower(_ c: Character) -> Bool { c >= "a" && c <= "z" }

    /// PDF からのコピーで入る行内の改行を削除。空行（段落の区切り）と「。」などの文末の改行は残す
    static func joinLines(_ input: String) -> String {
        var paragraphs: [[String]] = []
        var cur: [String] = []
        for raw in normalize(input).components(separatedBy: "\n") {
            let line = trimTrailing(raw, [" ", "\t"])
            if line.isEmpty {
                if !cur.isEmpty { paragraphs.append(cur); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { paragraphs.append(cur) }
        return paragraphs.map(joinParagraph).joined(separator: "\n\n")
    }

    private static func joinParagraph(_ lines: [String]) -> String {
        var out = lines[0]
        for b in lines.dropFirst() {
            guard let a = out.last, let bf = b.first else { continue }
            let beforeA = out.dropLast().last
            if a == "-", let p = beforeA, isLower(p), isLower(bf) {
                out.removeLast()  // 行末のハイフンで分かれた英単語をつなぐ
                out += b
            } else if "。．！？!?:：".contains(a) {
                out += "\n" + b
            } else {
                out += (isCJK(a) || isCJK(bf) ? "" : " ") + b
            }
        }
        return out
    }

    /// 全角英数・記号 → 半角（「」、。などの日本語の約物はそのまま）
    static func toHalf(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if (0xFF01...0xFF5E).contains(u.value), let h = Unicode.Scalar(u.value - 0xFEE0) {
                out.append(h)
            } else if u.value == 0x3000 {
                out.append(" ")
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// 半角カナ → 全角カナ（濁点もまとめる）
    static func kanaFull(_ s: String) -> String {
        var out = ""
        var run = String.UnicodeScalarView()
        func flush() {
            if !run.isEmpty {
                out += String(run).precomposedStringWithCompatibilityMapping
                run = String.UnicodeScalarView()
            }
        }
        for u in s.unicodeScalars {
            if (0xFF61...0xFF9F).contains(u.value) {
                run.append(u)
            } else {
                flush()
                out.unicodeScalars.append(u)
            }
        }
        flush()
        return out
    }

    static func trimSpaces(_ s: String) -> String {
        normalize(s).components(separatedBy: "\n")
            .map { trimTrailing($0, [" ", "\t", "\u{3000}"]) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 表

    /// Excel / Numbers のコピー（タブ区切り、"..." で改行を含むセル）を表として読む。タブが無ければ CSV とみなす
    static func parseTable(_ input: String) -> [[String]] {
        var s = normalize(input)
        while s.hasSuffix("\n") { s.removeLast() }
        let d: Character = s.contains("\t") ? "\t" : ","
        let chars = Array(s)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { quoted = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" && cell.isEmpty {
                quoted = true
            } else if c == d {
                row.append(cell); cell = ""
            } else if c == "\n" {
                row.append(cell); rows.append(row); row = []; cell = ""
            } else {
                cell.append(c)
            }
            i += 1
        }
        row.append(cell)
        rows.append(row)
        let n = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: n - $0.count) }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func isNumber(_ v: String) -> Bool {
        let pattern = #"^\s*[-+−]?(\d{1,3}(,\d{3})+|\d*)(\.\d+)?([eE][-+]?\d+)?\s*%?\s*$"#
        return v.range(of: pattern, options: .regularExpression) != nil
            && v.range(of: #"\d"#, options: .regularExpression) != nil
    }

    /// 数値だけの列（右寄せにする）
    static func numberColumns(_ rows: [[String]]) -> [Bool] {
        guard let head = rows.first else { return [] }
        let body = rows.dropFirst()
        return head.indices.map { j in
            !body.isEmpty
                && body.allSatisfy { trim($0[j]).isEmpty || isNumber($0[j]) }
                && body.contains { !trim($0[j]).isEmpty }
        }
    }

    static func toMarkdown(_ s: String) -> String {
        let rows = parseTable(s), nc = numberColumns(rows)
        func line(_ r: [String]) -> String {
            "| " + r.map { trim($0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")) }
                .joined(separator: " | ") + " |"
        }
        let sep = "|" + nc.map { $0 ? " ---: " : " --- " }.joined(separator: "|") + "|"
        return ([line(rows[0]), sep] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    static func toLatex(_ s: String) -> String {
        let rows = parseTable(s), nc = numberColumns(rows)
        func esc(_ v: String) -> String {
            var out = ""
            for c in trim(v) {
                switch c {
                case "\\": out += "\\textbackslash{}"
                case "&", "%", "$", "#", "_", "{", "}": out += "\\" + String(c)
                case "~": out += "\\textasciitilde{}"
                case "^": out += "\\textasciicircum{}"
                case "\n": out += " "
                default: out.append(c)
                }
            }
            return out
        }
        func line(_ r: [String]) -> String { "  " + r.map(esc).joined(separator: " & ") + " \\\\" }
        var out = ["\\begin{tabular}{" + nc.map { $0 ? "r" : "l" }.joined() + "}", "  \\hline", line(rows[0]), "  \\hline"]
        out += rows.dropFirst().map(line)
        out += ["  \\hline", "\\end{tabular}"]
        return out.joined(separator: "\n")
    }

    static func toCSV(_ s: String) -> String {
        parseTable(s).map { r in
            r.map { v in
                v.contains("\"") || v.contains(",") || v.contains("\n")
                    ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    static func toTSV(_ s: String) -> String {
        parseTable(s).map { r in
            r.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
