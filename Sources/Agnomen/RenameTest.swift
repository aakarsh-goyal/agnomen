import Foundation

/// End-to-end check of the real AppModel apply/undo code against a scratch folder.
@MainActor
enum RenameTest {
    static var failures = 0
    static func check(_ c: Bool, _ what: String) { if !c { failures += 1; print("  FAIL: \(what)") } else { print("  ok: \(what)") } }

    static func names(_ dir: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") })
    }
    static func waitIdle(_ m: AppModel) async { while m.busy { try? await Task.sleep(for: .milliseconds(100)) } }

    static func run(_ dir: URL) async -> Int32 {
        let m = AppModel.shared
        m.requestMode(.onDevice)            // deterministic, no cloud
        let before = names(dir)
        print("scratch folder: \(dir.path) (\(before.count) entries)")

        // 1. Analyze + apply
        m.load(dir)
        try? await Task.sleep(for: .milliseconds(300))
        await waitIdle(m)
        let planned = m.items.filter { $0.willRename }
        check(planned.count > 5, "model proposed \(planned.count) renames")

        // Race: someone creates a file with the first target's name after analysis.
        let victim = planned[0]
        let blocker = dir.appendingPathComponent(victim.target!)
        try? "I must survive".write(to: blocker, atomically: true, encoding: .utf8)

        m.applySelected()
        let after = names(dir)
        check(m.items.first(where: { $0.id == victim.id })?.state != .renamed, "clash after analysis is refused, not overwritten")
        check((try? String(contentsOf: blocker, encoding: .utf8)) == "I must survive", "blocker file content intact")
        check(FileManager.default.fileExists(atPath: victim.url.path), "victim file still has its original name")
        let renamed = m.items.filter { $0.state == .renamed }
        check(renamed.count == planned.count - 1, "all other files renamed (\(renamed.count))")
        for r in renamed {
            check(FileManager.default.fileExists(atPath: r.url.path), "exists on disk: \(r.url.lastPathComponent)")
            check(!after.contains(r.originalName) || r.originalName == r.url.lastPathComponent, "old name gone: \(r.originalName)")
        }
        check(m.undoCount == renamed.count, "undo journal has \(renamed.count) moves")

        // 2. Undo
        m.undoLastBatch()
        try? FileManager.default.removeItem(at: blocker)
        let restored = names(dir)
        check(restored == before, "folder is exactly as before after undo")
        check(m.undoCount == 0, "undo journal emptied")
        check(m.items.filter { $0.willRename }.count == planned.count - 1 || m.items.filter { $0.willRename }.count >= planned.count - 1,
              "rows are back in a re-appliable state without re-reading files")

        print(failures == 0 ? "rename-test: all checks passed" : "rename-test: \(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
