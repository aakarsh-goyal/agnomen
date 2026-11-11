import Foundation

enum SelfTest {
    static var failures = 0

    static func check(_ cond: Bool, _ what: String) {
        if !cond { failures += 1; print("  FAIL: \(what)") }
    }
    static func eq(_ a: String?, _ b: String?, _ what: String) {
        if a != b { failures += 1; print("  FAIL: \(what)\n    got:      \(a ?? "nil")\n    expected: \(b ?? "nil")") }
    }

    static func run() -> Int32 {
        let d = Date(timeIntervalSince1970: 1_741_910_400) // 2025-03-14 UTC (local day may differ by TZ; only used with explicit check below)

        // Style handling: models answer in all sorts of shapes.
        eq(NameFormatter.format("invoice_acme_corp_2025", style: .spaces, date: nil), "Invoice Acme Corp 2025", "snake → Title Case")
        eq(NameFormatter.format("invoice-acme-corp-2025", style: .spaces, date: nil), "Invoice Acme Corp 2025", "kebab → Title Case")
        eq(NameFormatter.format("Invoice from ACME Corp for the iPhone order.pdf", style: .spaces, date: nil), "Invoice From ACME Corp for the iPhone Order", "strips ext, keeps acronyms, minor words")
        eq(NameFormatter.format("  \"Lecture Notes: Fourier Transform / Week 3\"  ", style: .kebab, date: nil), "lecture-notes-fourier-transform-week-3", "illegal chars + kebab")
        eq(NameFormatter.format("Quarterly Report v2.5 Final", style: .snake, date: nil), "quarterly_report_v2.5_final", "snake keeps dotted versions")
        eq(NameFormatter.format("Résumé of José Núñez", style: .kebab, date: nil), "résumé-of-josé-núñez", "unicode letters survive")
        eq(NameFormatter.format("Boarding Pass PRIYA SHARMA ACME 22 DEC 2025", style: .spaces, date: nil), "Boarding Pass Priya Sharma ACME 22 DEC 2025", "SHOUTING words lowered, acronyms kept")
        eq(NameFormatter.format("Lease M. Patel S. Rao", style: .spaces, date: nil), "Lease M. Patel S. Rao", "initials keep their dot")
        eq(NameFormatter.format("Lease M. Patel S. Rao", style: .kebab, date: nil), "lease-m-patel-s-rao", "initials slugged")
        eq(NameFormatter.format("---", style: .spaces, date: nil), nil, "punctuation only → nil")
        eq(NameFormatter.format("", style: .spaces, date: nil), nil, "empty → nil")
        check(NameFormatter.format("x", style: .spaces, date: d)!.hasPrefix("2025-03-1"), "date prefix")
        let long = Array(repeating: "wordy", count: 40).joined(separator: " ")
        check((NameFormatter.format(long, style: .spaces, date: nil)?.count ?? 999) <= 80, "length cap")
        eq(NameFormatter.sanitizeManual("  .hidden/name:x  "), "hidden name x", "manual sanitize")

        // Templates
        let mod = Date(timeIntervalSince1970: 1_741_910_400 + 43_200)   // mid-day, so the local date is stable
        let day = NameFormatter.dateString(mod)
        eq(NameFormatter.compose(template: "{date} {title}", raw: "Tax Return", style: .spaces, modified: mod, created: nil, originalBase: "scan01"), "\(day) Tax Return", "template date+title")
        eq(NameFormatter.compose(template: "{date} {title}", raw: "Tax Return", style: .kebab, modified: mod, created: nil, originalBase: "scan01"), "\(day)-tax-return", "template kebab separator")
        eq(NameFormatter.compose(template: "{title} ({original})", raw: "Tax Return", style: .spaces, modified: mod, created: nil, originalBase: "scan 01"), "Tax Return (scan 01)", "template original")
        eq(NameFormatter.compose(template: "{title} ({original})", raw: "Tax Return", style: .spaces, modified: mod, created: nil, originalBase: "!!!"), "Tax Return", "empty token leaves no ()")
        eq(NameFormatter.compose(template: "{created} {title}", raw: "Tax Return", style: .snake, modified: mod, created: nil, originalBase: "x"), "tax_return", "missing date leaves no dangling separator")
        eq(NameFormatter.compose(template: "Scans", raw: "Tax Return", style: .spaces, modified: mod, created: nil, originalBase: "x"), "Scans Tax Return", "pattern without {title} gets one")
        eq(NameFormatter.compose(template: "{year} - {title}", raw: "Tax Return", style: .spaces, modified: mod, created: nil, originalBase: "x"), "\(String(day.prefix(4))) - Tax Return", "template year")

        // Extensions
        let a = NameFormatter.splitExtension("backup.tar.gz"); eq(a.ext, "tar.gz", "tar.gz ext"); eq(a.base, "backup", "tar.gz base")
        let b = NameFormatter.splitExtension("Makefile"); eq(b.ext, "", "no ext")
        let c = NameFormatter.splitExtension("notes.v2.txt"); eq(c.ext, "txt", "last ext only"); eq(c.base, "notes.v2", "dotted base")

        // Collisions: against existing files and among proposals; own name is never a clash.
        let dir = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        func item(_ n: String, raw: String) -> RenameItem {
            let (_, ext) = NameFormatter.splitExtension(n)
            var i = RenameItem(url: dir.appendingPathComponent(n), ext: ext, dir: dir, originalName: n)
            i.raw = raw; i.state = .ready
            return i
        }
        var items = [item("a.pdf", raw: "Tax Return 2024"), item("b.pdf", raw: "Tax Return 2024"),
                     item("c.pdf", raw: "tax return 2024"), item("Existing Name.txt", raw: "existing name"),
                     item("d.txt", raw: "Existing Name")]
        let names: [String: Set<String>] = [dir.path: Set(["a.pdf", "b.pdf", "c.pdf", "Existing Name.txt", "d.txt"].map(NameFormatter.key))]
        Planner.assignTargets(&items, dirNames: names, style: .spaces)
        eq(items[0].target, "Tax Return 2024.pdf", "first keeps name")
        eq(items[1].target, "Tax Return 2024 2.pdf", "second gets 2")
        eq(items[2].target, "Tax Return 2024 3.pdf", "third gets 3 (case-insensitive)")
        eq(items[3].target, "Existing Name.txt", "already named → unchanged")
        check(!items[3].willRename, "unchanged isn't a rename")
        eq(items[4].target, "Existing Name 2.txt", "clash with existing file")

        // Same base, different extension doesn't clash.
        var mixed = [item("a.pdf", raw: "Report"), item("b.txt", raw: "Report")]
        Planner.assignTargets(&mixed, dirNames: [dir.path: Set(["a.pdf", "b.txt"].map(NameFormatter.key))], style: .kebab)
        eq(mixed[0].target, "report.pdf", "kebab pdf"); eq(mixed[1].target, "report.txt", "kebab txt")

        print(failures == 0 ? "selftest: all checks passed" : "selftest: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
