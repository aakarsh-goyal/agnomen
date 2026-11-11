import Foundation
import AppKit
import FoundationModels

// Command-line modes exist so the pipeline can be exercised headlessly:
//   Agnomen --dry-run <folder> [--mode onDevice|cloud|both] [--style spaces|kebab|snake] [--template "{date} {title}"] [--no-name] [--hint "…"] [--subfolders]
//   Agnomen --pcc-probe              check Private Cloud Compute availability/quota, entitlements, and make one tiny synthetic call
//   Agnomen --extract <file>        print what the model would be shown
//   Agnomen --selftest              unit checks for naming/collision/zip logic
//   Agnomen --rename-test <folder> real apply → verify → undo → verify round trip on a scratch folder
//   Agnomen --net-probe <port>      try a TCP connect to 127.0.0.1:<port>; proves whether the sandbox blocks networking
//   Agnomen --render-preview <out.png> [<folder>]   offscreen PNG of the window
// With no flags it launches the normal app.

let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

func runCLI(_ body: @escaping () async -> Int32) {
    Task.detached {
        let code = await body()
        exit(code)
    }
    dispatchMain()
}

if let folder = value(after: "--dry-run") {
    runCLI {
        let style = NameStyle(rawValue: value(after: "--style") ?? "") ?? .spaces
        let template = value(after: "--template") ?? "{title}"
        let useName = !args.contains("--no-name")
        let hint = value(after: "--hint") ?? ""
        let mode = ModelMode(rawValue: value(after: "--mode") ?? "") ?? .onDevice
        let backends = mode.backends
        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        print("Mode: \(mode.label)")
        for b in backends { print("  \(b.label): \(Namer.status(b))") }
        var scan = Scanner.scan(url, recursive: args.contains("--subfolders"))
        print("Files: \(scan.items.count)\n")
        if args.contains("--timing") {
            // Diagnostic (aggregate numbers only): time to read a file vs. the whole file (read + model).
            var exts: [Double] = [], tots: [Double] = []
            for it in scan.items {
                let a = Date(); _ = await Extractor.extract(it.url); let e = Date().timeIntervalSince(a)
                let b = Date(); let o = await Pipeline.analyze(url: it.url, hint: hint, backends: backends, useName: useName); let t = Date().timeIntervalSince(b)
                if case .named = o { exts.append(e); tots.append(t) }
            }
            func avg(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(a.count, 1)) }
            print(String(format: "files named: %d | avg read %.0f ms | avg total %.0f ms | read share %.0f%%", tots.count, avg(exts) * 1000, avg(tots) * 1000, avg(exts) / avg(tots) * 100))
            return 0
        }
        if let wStr = value(after: "--two-phase"), let width = Int(wStr) {
            // Diagnostic: read EVERY file first (all cores), then run only the model. Compare with --parallel.
            let t0 = Date()
            var extracted: [Int: Extracted] = [:]
            await withTaskGroup(of: (Int, Extracted).self) { group in
                var next = 0
                func add() { if next < scan.items.count { let i = next, u = scan.items[next].url; next += 1; group.addTask { (i, await Extractor.extract(u)) } } }
                for _ in 0..<ProcessInfo.processInfo.activeProcessorCount { add() }
                while let (i, e) = await group.next() { extracted[i] = e; add() }
            }
            let t1 = Date()
            let todo = scan.items.indices.filter { extracted[$0]?.hasContent == true }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    if next < todo.count {
                        let i = todo[next], e = extracted[i]!, n = scan.items[i].originalName; next += 1
                        group.addTask { _ = try? await Namer.suggest(backend: .onDevice, currentName: n, extracted: e, hint: hint, creative: false) }
                    }
                }
                for _ in 0..<width { add() }
                while await group.next() != nil { add() }
            }
            let t2 = Date()
            print(String(format: "two-phase (model width %d): read all %.1f s + model %.1f s = %.1f s total (%d files)", width, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1), t2.timeIntervalSince(t0), todo.count))
            return 0
        }
        if let nStr = value(after: "--parallel"), let width = Int(nStr) {
            // Diagnostic: wall-clock for the whole folder with `width` files in flight.
            let t0 = Date()
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() { if next < scan.items.count { let u = scan.items[next].url; next += 1; group.addTask { _ = await Pipeline.analyze(url: u, hint: hint, backends: backends, useName: useName) } } }
                for _ in 0..<width { add() }
                while await group.next() != nil { add() }
            }
            print(String(format: "mode=%@ parallel=%d: %d files in %.1f s", mode.rawValue, width, scan.items.count, Date().timeIntervalSince(t0)))
            return 0
        }
        for i in scan.items.indices {
            let t0 = Date()
            let it = scan.items[i]
            let outcome = await Pipeline.analyze(url: it.url, hint: hint, backends: backends, useName: useName)
            var info = ""
            switch outcome {
            case .named(let o):
                let pick = o.candidates.first(where: { $0.backend == .cloud }) ?? o.candidates[0]
                scan.items[i].raw = pick.rawName; scan.items[i].summary = pick.summary; scan.items[i].state = .ready
                scan.items[i].candidates = o.candidates
                info = "[\(o.method), \(o.chars) chars]" + (o.notes.isEmpty ? "" : " notes: \(o.notes.joined(separator: " "))")
            case .skipped(let why): scan.items[i].state = .skipped(why); info = "SKIPPED: \(why)"
            case .failed(let why): scan.items[i].state = .failed(why); info = "FAILED: \(why)"
            case .quotaReached(let d): scan.items[i].state = .skipped("quota"); info = "CLOUD QUOTA REACHED \(d.map { "\($0)" } ?? "")"
            }
            let secs = String(format: "%.1fs", Date().timeIntervalSince(t0))
            print("• \(it.originalName)\n    \(info) \(secs)")
            for c in scan.items[i].candidates { print("    \(pad(c.backend.label, 10)) \(c.rawName)") }
        }
        Planner.assignTargets(&scan.items, dirNames: scan.dirNames, style: style, template: template)
        print("\n=== Proposed renames (\(style.label), template: \(template)) ===")
        for it in scan.items {
            print("\(pad(it.originalName, 38)) → \(it.target ?? "(no change)")")
        }
        return 0
    }
} else if let file = value(after: "--extract") {
    runCLI {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let ex = await Extractor.extract(url)
        print("kind: \(ex.kind)\nmethod: \(ex.method)\nchars: \(ex.text.count)\n---\n\(ex.text)")
        return 0
    }
} else if let port = value(after: "--net-probe").flatMap({ UInt16($0) }) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if rc == 0 { print("NETWORK: connection succeeded (not sandboxed)") }
    else { print("NETWORK: BLOCKED — \(String(cString: strerror(errno)))") }
    exit(rc == 0 ? 0 : 1)
} else if let folder = value(after: "--rename-test") {
    Task { @MainActor in
        let code = await RenameTest.run(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true))
        exit(code)
    }
    dispatchMain()
} else if args.contains("--pcc-probe") {
    runCLI {
        print("sandboxed: \(Sandbox.isSandboxed) | network entitlement: \(Sandbox.entitlement("com.apple.security.network.client")) | can use network: \(Sandbox.canUseNetwork)")
        print("on-device: \(Namer.status(.onDevice))")
        print("cloud:     \(Namer.status(.cloud))")
        print("quota:     \(Namer.cloudQuotaNote() ?? "headroom")")
        if let n = try? await Namer.cloudModel.contextSize { print("cloud contextSize: \(n)") }
        // One tiny call with made-up text; nothing from the user's files.
        let ex = Extracted(kind: "Plain text document", text: "Invoice #1042 from Brightline Plumbing, water heater repair, June 2024, total $380.", method: "text")
        let t = Date()
        do {
            let r = try await Namer.suggest(backend: .cloud, currentName: "scan.txt", extracted: ex, hint: "", creative: false)
            print(String(format: "cloud call OK in %.1f s: %@", Date().timeIntervalSince(t), r.name))
        } catch { print("cloud guided call FAILED: \(String(describing: error).prefix(120))") }
        // Same call without guided generation, to tell "PCC is unreachable" from "PCC rejects the schema".
        do {
            let s = LanguageModelSession(model: Namer.cloudModel, instructions: "Reply with one short word.")
            let r = try await s.respond(to: "Say hello.")
            print("cloud plain-text call OK: \(r.content.prefix(40))")
        } catch { print("cloud plain call FAILED: \(String(describing: error).prefix(120))") }
        return 0
    }
} else if args.contains("--selftest") {
    runCLI { SelfTest.run() }
} else if let out = value(after: "--render-preview") {
    MainActor.assumeIsolated {
        let folder = args.count > 3 ? args[3] : nil
        PreviewRenderer.render(to: out, folder: folder)
    }
} else {
    AgnomenApp.main()
}
