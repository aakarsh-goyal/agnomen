import Foundation

enum ItemState: Equatable {
    case queued, analyzing, ready
    case skipped(String)
    case failed(String)
    case renamed
}

struct RenameItem: Identifiable {
    let id = UUID()
    var url: URL
    let ext: String
    let dir: URL
    let originalName: String
    var modified: Date?
    var created: Date?

    var raw: String?            // chosen model's name (unformatted)
    var summary: String?
    var candidates: [Candidate] = []   // one per model that answered (two in "Both" mode)
    var choice: Backend?        // which candidate is in use
    var notes: [String] = []    // e.g. "Cloud: quota reached" when one model failed
    var manual: String?         // user-typed base name; overrides the model
    var state: ItemState = .queued
    var selected = true
    var target: String?         // final full file name after style + dedupe

    var currentName: String { url.lastPathComponent }
    var willRename: Bool { state == .ready && target != nil && target != currentName }
    var targetBase: String? {
        guard let t = target else { return nil }
        return ext.isEmpty ? t : String(t.dropLast(ext.count + 1))
    }
}

enum Scanner {
    struct Result {
        var items: [RenameItem]
        var dirNames: [String: Set<String>]   // dir path → keys of everything already in it
    }

    static func scan(_ folder: URL, recursive: Bool) -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey]
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { opts.insert(.skipsSubdirectoryDescendants) }
        var items: [RenameItem] = []
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: opts) {
            for case let url as URL in en {
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                let (_, ext) = NameFormatter.splitExtension(url.lastPathComponent)
                items.append(RenameItem(url: url, ext: ext, dir: url.deletingLastPathComponent(),
                                        originalName: url.lastPathComponent,
                                        modified: v.contentModificationDate, created: v.creationDate))
            }
        }
        items.sort {
            let a = $0.dir.path, b = $1.dir.path
            return a == b ? $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending
                          : a.localizedStandardCompare(b) == .orderedAscending
        }
        var names: [String: Set<String>] = [:]
        for it in items where names[it.dir.path] == nil {
            let list = (try? fm.contentsOfDirectory(atPath: it.dir.path)) ?? []
            names[it.dir.path] = Set(list.map(NameFormatter.key))
        }
        return Result(items: items, dirNames: names)
    }

    /// iCloud "dataless" placeholder (SF_DATALESS). Opening one makes macOS download
    /// it, which would break the offline promise, so these are never read.
    static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_flags & 0x4000_0000) != 0
    }
}

enum Planner {
    static func desiredBase(_ item: RenameItem, style: NameStyle, template: String) -> String? {
        if let m = item.manual {
            let c = NameFormatter.sanitizeManual(m)
            return c.isEmpty ? nil : c
        }
        guard let raw = item.raw else { return nil }
        let originalBase = NameFormatter.splitExtension(item.originalName).base
        return NameFormatter.compose(template: template, raw: raw, style: style, modified: item.modified,
                                     created: item.created, originalBase: originalBase)
    }

    /// Recompute every item's final name. Names that would clash with an existing
    /// file, or with another proposal in the same folder, get " 2", " 3"… appended.
    static func assignTargets(_ items: inout [RenameItem], dirNames: [String: Set<String>], style: NameStyle, template: String = "{title}") {
        var taken = dirNames
        for i in items.indices {
            items[i].target = nil
            guard items[i].state == .ready, let base = desiredBase(items[i], style: style, template: template) else { continue }
            let full = NameFormatter.fullName(base, items[i].ext)
            if NameFormatter.key(full) == NameFormatter.key(items[i].currentName) {
                items[i].target = items[i].currentName          // already named this
                continue
            }
            let path = items[i].dir.path
            let unique = NameFormatter.unique(base: base, ext: items[i].ext, style: style, taken: taken[path] ?? [])
            let final = NameFormatter.fullName(unique, items[i].ext)
            taken[path, default: []].insert(NameFormatter.key(final))
            items[i].target = final
        }
    }
}
