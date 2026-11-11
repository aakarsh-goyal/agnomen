import SwiftUI
import AppKit

/// Offscreen render of the real window (AppKit-backed controls included) for visual checks.
@MainActor
enum PreviewRenderer {
    static func render(to path: String, folder: String?) {
        _ = NSApplication.shared
        let model = AppModel.shared
        if CommandLine.arguments.contains("--demo-both") { model.previewMode(.both) }
        if let folder {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            if CommandLine.arguments.contains("--live") {
                model.load(url)                               // real model, real pipeline
                while model.items.isEmpty || model.busy { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            } else {
                model.folder = url
                model.items = Scanner.scan(url, recursive: false).items
                demoFill(model)
            }
        }
        let size = NSSize(width: 940, height: 660)
        let host = NSHostingView(rootView: ContentView())
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.appearance = NSAppearance(named: args_dark() ? .darkAqua : .aqua)
        win.orderBack(nil)
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }

    private static func args_dark() -> Bool { CommandLine.arguments.contains("--dark") }

    /// Canned model output so the layout can be judged without waiting on the model.
    private static func demoFill(_ model: AppModel) {
        let samples: [(String, String)] = [
            ("Invoice Acme Corp Laptop Order March 2025", "Invoice from Acme Corp for three laptops, totalling $4,200."),
            ("Q3 Product Roadmap Planning Meeting Notes", "Meeting notes about the Q3 product roadmap."),
            ("Boarding Pass Delhi To Mumbai", "Airline boarding pass screenshot."),
            ("Monthly Household Budget 2025", "Spreadsheet of household income and expenses."),
        ]
        for i in model.items.indices {
            let s = samples[i % samples.count]
            model.items[i].raw = s.0
            model.items[i].summary = s.1
            model.items[i].state = .ready
            if CommandLine.arguments.contains("--demo-both") {
                // Show what "Both" mode looks like: agreeing rows and rows where the models differ.
                let other = i % 3 == 0 ? s.0 : s.0.split(separator: " ").dropLast().joined(separator: " ") + " Summary"
                model.items[i].candidates = [Candidate(backend: .onDevice, summary: s.1, rawName: other),
                                             Candidate(backend: .cloud, summary: s.1, rawName: s.0)]
                model.items[i].choice = .cloud
            }
        }
        if model.items.count > 2 { model.items[model.items.count - 1].state = .skipped("Nothing readable to base a name on. You can type one.") }
        if model.items.count > 3 { model.items[1].state = .analyzing }
        model.recompute()
    }
}
