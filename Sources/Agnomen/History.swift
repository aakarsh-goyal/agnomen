import Foundation

/// Every applied rename batch is journaled so it can be undone, even after a relaunch.
/// The folder is stored as a security-scoped bookmark because the sandbox forgets
/// folder access between launches.
struct RenameBatch: Codable, Identifiable {
    struct Move: Codable { var from: String; var to: String; var wroteComment: String? }
    var id = UUID()
    var date = Date()
    var folderName: String
    var bookmark: Data?
    var moves: [Move]
}

enum History {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agnomen", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.json")
    }

    static func load() -> [RenameBatch] {
        guard let d = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([RenameBatch].self, from: d)) ?? []
    }

    private static func save(_ batches: [RenameBatch]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Array(batches.suffix(25))) { try? d.write(to: fileURL, options: .atomic) }
    }

    static func append(_ b: RenameBatch) { save(load() + [b]) }
    static var last: RenameBatch? { load().last }

    struct UndoResult { var restored: [RenameBatch.Move] = []; var skipped = 0 }

    /// Reverse the most recent batch. Never overwrites: a file is only moved back
    /// if its renamed copy still exists and the old name is free.
    static func undoLast() -> UndoResult? {
        var all = load()
        guard let batch = all.last else { return nil }
        var result = UndoResult()
        var scoped: URL?
        if let bm = batch.bookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               u.startAccessingSecurityScopedResource() {
                scoped = u
            }
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        let fm = FileManager.default
        for m in batch.moves.reversed() {
            if fm.fileExists(atPath: m.to), !fm.fileExists(atPath: m.from),
               (try? fm.moveItem(atPath: m.to, toPath: m.from)) != nil {
                if let c = m.wroteComment, FinderComment.read(m.from) == c { FinderComment.remove(m.from) }
                result.restored.append(m)
            } else {
                result.skipped += 1
            }
        }
        all.removeLast()
        save(all)
        return result
    }
}
