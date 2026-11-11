import Foundation

/// How the final file name is written. Applied after the model answers, so
/// switching style never needs another model run.
enum NameStyle: String, CaseIterable, Identifiable {
    case spaces, kebab, snake
    var id: String { rawValue }
    var label: String {
        switch self {
        case .spaces: return "Title Case"
        case .kebab: return "kebab-case"
        case .snake: return "snake_case"
        }
    }
    var separator: String {
        switch self {
        case .spaces: return " "
        case .kebab: return "-"
        case .snake: return "_"
        }
    }
}

/// Pure string logic: turn whatever the model said into a safe, tidy file name.
enum NameFormatter {
    static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "via", "with", "vs",
    ]

    private static let knownExtension = try! NSRegularExpression(
        pattern: #"\.(pdf|docx?|xlsx?|pptx?|txt|md|rtf|csv|json|html?|png|jpe?g|gif|heic|tiff?|mp3|m4a|mp4|mov|zip|key|pages|numbers)$"#,
        options: .caseInsensitive)

    private static let illegal: CharacterSet = {
        var set = CharacterSet(charactersIn: "/\\:*?\"<>|")
        set.formUnion(.controlCharacters)
        set.formUnion(.newlines)
        return set
    }()

    /// Split a model answer into clean words regardless of whether it answered in
    /// "Title Case", snake_case or kebab-case.
    static func words(from raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`“”‘’")))
        let range = NSRange(s.startIndex..., in: s)
        if let m = knownExtension.firstMatch(in: s, range: range), let r = Range(m.range, in: s) {
            s.removeSubrange(r)
        }
        s = s.unicodeScalars.map { illegal.contains($0) ? " " : String($0) }.joined()
        let hasSpaceOrUnderscore = s.contains(" ") || s.contains("_")
        let seps = hasSpaceOrUnderscore ? CharacterSet(charactersIn: " _") : CharacterSet(charactersIn: "-")
        let trimSet = CharacterSet(charactersIn: ".-,;:!")
        return s.components(separatedBy: seps)
            .map { w -> String in
                // "M." is an initial, not trailing punctuation; the dot is dropped later per style.
                (w.count == 2 && w.last == "." && w.first!.isUppercase) ? w : w.trimmingCharacters(in: trimSet)
            }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    static func titleCase(_ w: String, first: Bool) -> String {
        // OCR of capitalised documents yields SHOUTED names; 5+ letters is a word, shorter is likely an acronym.
        if w.count >= 5, w.allSatisfy({ !$0.isLetter || $0.isUppercase }), w.contains(where: { $0.isLetter }) {
            return w.prefix(1) + w.dropFirst().lowercased()
        }
        if w.contains(where: { $0.isUppercase }) { return w }          // Acme, iPhone, ACME, M.: leave alone
        if !first && minorWords.contains(w) { return w }
        guard let f = w.first else { return w }
        return f.uppercased() + w.dropFirst()
    }

    static func slug(_ w: String) -> String {
        let chars = Array(w.lowercased())
        var out = ""
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber { out.append(c) }
            else if c == ".", i > 0, i + 1 < chars.count, chars[i - 1].isNumber, chars[i + 1].isNumber { out.append(c) }
        }
        return out
    }

    static func dateString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Final base name (no extension) for a model answer, or nil if nothing usable.
    static func format(_ raw: String, style: NameStyle, date: Date?, maxLen: Int = 80) -> String? {
        var ws = words(from: raw)
        switch style {
        case .spaces: ws = ws.enumerated().map { titleCase($1, first: $0 == 0) }
        case .kebab, .snake: ws = ws.map(slug).filter { !$0.isEmpty }
        }
        guard !ws.isEmpty else { return nil }
        ws = Array(ws.prefix(9))
        var kept: [String] = []
        var len = 0
        for w in ws {
            let add = w.count + (kept.isEmpty ? 0 : 1)
            if len + add > maxLen && !kept.isEmpty { break }
            kept.append(w)
            len += add
        }
        var s = kept.joined(separator: style.separator)
        if let date { s = dateString(date) + style.separator + s }
        return s
    }

    /// Light cleanup for a name the user typed themselves: no restyling.
    static func sanitizeManual(_ raw: String) -> String {
        var s = raw.unicodeScalars.map { illegal.contains($0) ? " " : String($0) }.joined()
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst() }          // a leading dot would hide the file
        return String(s.prefix(200)).trimmingCharacters(in: .whitespaces)
    }

    /// Case/Unicode-insensitive comparison key, matching how APFS treats names.
    static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    static func fullName(_ base: String, _ ext: String) -> String { ext.isEmpty ? base : base + "." + ext }

    /// Append " 2", " 3"… (per style) until the name is free. `taken` holds keys.
    static func unique(base: String, ext: String, style: NameStyle, taken: Set<String>) -> String {
        if !taken.contains(key(fullName(base, ext))) { return base }
        var n = 2
        while taken.contains(key(fullName(base + style.separator + String(n), ext))) { n += 1 }
        return base + style.separator + String(n)
    }

    /// "report.tar.gz" → ("report", "tar.gz")
    static func splitExtension(_ name: String) -> (base: String, ext: String) {
        let ns = name as NSString
        var ext = ns.pathExtension
        var base = ns.deletingPathExtension
        if ["gz", "bz2", "xz", "zst"].contains(ext.lowercased()), base.lowercased().hasSuffix(".tar") {
            ext = "tar." + ext
            base = String(base.dropLast(4))
        }
        return (base, ext)
    }
}

/// Name patterns. Tokens: {title} the model's name, {date} date modified, {created} date created,
/// {year} year modified, {original} the file's previous name.
enum NameTemplate: String, CaseIterable, Identifiable {
    case title, dateTitle, titleDate, yearTitle, original, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Title only"
        case .dateTitle: return "Date + Title"
        case .titleDate: return "Title + Date"
        case .yearTitle: return "Year + Title"
        case .original: return "Title + old name"
        case .custom: return "Custom pattern…"
        }
    }
    var pattern: String? {
        switch self {
        case .title: return "{title}"
        case .dateTitle: return "{date} {title}"
        case .titleDate: return "{title} {date}"
        case .yearTitle: return "{year} {title}"
        case .original: return "{title} ({original})"
        case .custom: return nil
        }
    }
}

extension NameFormatter {
    /// Build the final base name from a pattern. Literal spaces in the pattern take the style's separator,
    /// empty tokens leave no dangling separators, and a pattern without {title} gets one appended.
    static func compose(template: String, raw: String, style: NameStyle, modified: Date?, created: Date?,
                        originalBase: String, maxLen: Int = 80) -> String? {
        guard let title = format(raw, style: style, date: nil, maxLen: maxLen) else { return nil }
        func styled(_ s: String) -> String {
            let ws = words(from: s)
            return style == .spaces ? ws.joined(separator: " ")
                                    : ws.map(slug).filter { !$0.isEmpty }.joined(separator: style.separator)
        }
        var pattern = template.trimmingCharacters(in: .whitespaces)
        if !pattern.contains("{title}") { pattern += " {title}" }
        let cal = Calendar(identifier: .gregorian)
        let tokens: [(String, String)] = [
            ("{title}", title),
            ("{date}", modified.map(dateString) ?? ""),
            ("{created}", created.map(dateString) ?? ""),
            ("{year}", modified.map { String(cal.component(.year, from: $0)) } ?? ""),
            ("{original}", styled(originalBase)),
        ]
        var out = pattern
        for (k, v) in tokens { out = out.replacingOccurrences(of: k, with: v) }
        if style != .spaces { out = out.replacingOccurrences(of: " ", with: style.separator) }
        out = sanitizeManual(out)
        out = out.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
                 .replacingOccurrences(of: "_{2,}", with: "_", options: .regularExpression)
                 .replacingOccurrences(of: "\\(\\s*\\)", with: "", options: .regularExpression)   // "()" left by an empty token
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        return out.isEmpty ? nil : out
    }
}
