import Foundation
import AppKit
import Combine
import Security
import UniformTypeIdentifiers

/// What this build is actually allowed to do, read from its own code signature.
enum Sandbox {
    static func entitlement(_ key: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (v as? Bool) == true
    }
    static var isSandboxed: Bool { entitlement("com.apple.security.app-sandbox") }
    static var canUseNetwork: Bool { !isSandboxed || entitlement("com.apple.security.network.client") }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable { case idle, analyzing(done: Int, total: Int), applying }

    @Published var folder: URL?
    @Published var items: [RenameItem] = []
    @Published var phase: Phase = .idle
    @Published var banner: String?
    @Published var modelNote: String?          // availability / quota info for the selected mode
    @Published var modelBlocked = false        // no selected model can run right now
    @Published var undoCount = 0
    @Published var dropTargeted = false

    @Published private(set) var mode: ModelMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            refreshModelStatus()
            if !items.isEmpty && oldValue != mode { banner = "Model changed. Click Re-analyze to use it." }
        }
    }
    @Published var style: NameStyle { didSet { UserDefaults.standard.set(style.rawValue, forKey: "style"); recompute() } }
    @Published var templateChoice: NameTemplate { didSet { UserDefaults.standard.set(templateChoice.rawValue, forKey: "template"); recompute() } }
    @Published var customTemplate: String { didSet { UserDefaults.standard.set(customTemplate, forKey: "customTemplate"); recompute() } }
    /// Send the file's current name to the model as a hint. Off = judge purely by content.
    @Published var useExistingName: Bool { didSet { UserDefaults.standard.set(useExistingName, forKey: "useName") } }
    /// After renaming, also store the description as the Finder comment (Spotlight-searchable).
    @Published var saveComment: Bool { didSet { UserDefaults.standard.set(saveComment, forKey: "saveComment") } }
    var template: String { templateChoice.pattern ?? customTemplate }
    @Published var includeSubfolders: Bool {
        didSet { UserDefaults.standard.set(includeSubfolders, forKey: "subfolders"); if oldValue != includeSubfolders { rescan() } }
    }
    @Published var hint = ""

    private var dirNames: [String: Set<String>] = [:]
    private var analysisTask: Task<Void, Never>?
    private var iconCache: [String: NSImage] = [:]
    private var activeObserver: NSObjectProtocol?

    private init() {
        let d = UserDefaults.standard
        style = NameStyle(rawValue: d.string(forKey: "style") ?? "") ?? .spaces
        templateChoice = NameTemplate(rawValue: d.string(forKey: "template") ?? "") ?? .title
        customTemplate = d.string(forKey: "customTemplate") ?? "{date} {title}"
        useExistingName = d.object(forKey: "useName") as? Bool ?? true
        saveComment = d.bool(forKey: "saveComment")
        includeSubfolders = d.bool(forKey: "subfolders")
        // A cloud mode is only restored if the user previously agreed to it.
        let saved = ModelMode(rawValue: d.string(forKey: "mode") ?? "") ?? .onDevice
        mode = (saved.usesCloud && !d.bool(forKey: "cloudConsent")) ? .onDevice : saved
        undoCount = History.last?.moves.count ?? 0
        refreshModelStatus()
        // Event-driven refresh: re-check availability when the user comes back from System Settings.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModelStatus() }
        }
    }

    // MARK: Model choice

    /// Switching to a cloud mode needs the user's explicit, remembered consent, because the
    /// extracted text of their files then leaves the Mac.
    func requestMode(_ new: ModelMode) {
        if new.usesCloud && !UserDefaults.standard.bool(forKey: "cloudConsent") {
            let a = NSAlert()
            a.messageText = "Send file text to Apple Private Cloud Compute?"
            a.informativeText = """
            In this mode, the text Agnomen extracts from each file (up to about 6,000 characters per file, \
            including OCR text from images and scans) is sent to Apple’s Private Cloud Compute servers to generate names. \
            The files themselves are never uploaded.

            “On-device only” keeps everything on this Mac. You can switch back at any time.
            """
            a.addButton(withTitle: "Use Private Cloud Compute")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: "cloudConsent")
        }
        mode = new
    }

    /// Preview rendering only: show a mode without the consent dialog and without saving anything.
    func previewMode(_ m: ModelMode) { mode = m }

    func refreshModelStatus() {
        var notes: [String] = []
        var usable = 0
        for b in mode.backends {
            switch Namer.status(b) {
            case .ready: usable += 1
            case .unavailable(let why): notes.append(why)
            }
        }
        if mode.usesCloud, let q = Namer.cloudQuotaNote() { notes.append(q) }
        modelBlocked = usable == 0
        modelNote = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    // MARK: Derived

    var busy: Bool { phase != .idle }
    var analyzing: Bool { if case .analyzing = phase { return true } else { return false } }
    var pendingRenames: Int { items.filter { $0.selected && $0.willRename }.count }
    var proposedRenames: Int { items.filter { $0.willRename }.count }

    func icon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        if let i = iconCache[ext], !ext.isEmpty { return i }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 30, height: 30)
        if !ext.isEmpty { iconCache[ext] = i }
        return i
    }

    func displayBase(_ item: RenameItem) -> String {
        item.manual ?? item.targetBase ?? ""
    }

    // MARK: Folder loading

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Choose a folder. Agnomen will read each file on this Mac and suggest a descriptive name."
        if p.runModal() == .OK, let u = p.url { load(u) }
    }

    func handleDrop(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            banner = "Drop a folder, not a file."
            return false
        }
        load(url)
        return true
    }

    func load(_ url: URL) {
        analysisTask?.cancel()
        folder = url
        banner = nil
        rescan()
    }

    func rescan() {
        guard let folder else { return }
        analysisTask?.cancel()
        let r = Scanner.scan(folder, recursive: includeSubfolders)
        items = r.items
        dirNames = r.dirNames
        if items.isEmpty {
            phase = .idle
            banner = "No files found in this folder."
            return
        }
        startAnalysis()
    }

    // MARK: Analysis

    /// Reads and names files with a sliding window of `mode.concurrency` files in flight, so OCR and
    /// parsing for one file overlap with model calls for others. In "Both" mode each file's
    /// models also run side by side on the same extracted text.
    func startAnalysis(only ids: Set<UUID>? = nil, creative: Bool = false) {
        refreshModelStatus()
        guard !modelBlocked else { return }
        analysisTask?.cancel()
        let targets = items.filter { $0.state != .renamed && (ids == nil || ids!.contains($0.id)) }.map(\.id)
        guard !targets.isEmpty else { return }
        for id in targets {
            update(id) { $0.state = .queued; $0.raw = nil; $0.summary = nil; $0.candidates = []; $0.choice = nil; $0.notes = [] }
        }
        recompute()
        phase = .analyzing(done: 0, total: targets.count)
        let hint = self.hint
        let mode = self.mode
        let useName = self.useExistingName

        // Full speed: tell macOS this is user-initiated, latency-critical work so it neither naps the app when
        // it's in the background nor idle-sleeps the Mac mid-run. Thermals and swap are left to the OS.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Reading and naming files")

        analysisTask = Task(priority: .high) { [weak self] in
            guard let self else { return }
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var cloudBlocked = false
            var cloudBlockReason = "Private Cloud Compute quota reached."
            var cloudFailures = 0          // consecutive files where the cloud model errored
            var done = 0
            await withTaskGroup(of: (UUID, Pipeline.Outcome).self) { group in
                var next = 0, running = 0

                @MainActor func launch() {
                    while running < mode.concurrency, next < targets.count, !Task.isCancelled {
                        let id = targets[next]
                        next += 1
                        var backends = mode.backends
                        if cloudBlocked { backends.removeAll { $0 == .cloud } }
                        if backends.isEmpty {     // cloud-only and the quota is gone
                            self.update(id) { $0.state = .skipped(cloudBlockReason) }
                            done += 1
                            continue
                        }
                        guard let item = self.items.first(where: { $0.id == id }) else { continue }
                        self.update(id) { $0.state = .analyzing }
                        let url = item.url
                        running += 1
                        group.addTask(priority: .high) { (id, await Pipeline.analyze(url: url, hint: hint, backends: backends, creative: creative, useName: useName)) }
                    }
                }

                launch()
                while let (id, outcome) = await group.next() {
                    running -= 1
                    done += 1
                    self.update(id) { it in
                        switch outcome {
                        case .named(let o):
                            it.candidates = o.candidates
                            it.notes = o.notes
                            let pick = o.candidates.first(where: { $0.backend == .cloud }) ?? o.candidates[0]
                            it.choice = pick.backend
                            it.raw = pick.rawName
                            it.summary = pick.summary
                            it.state = .ready
                            if o.cloudQuotaHit != nil { cloudBlocked = true }
                            let cloudAnswered = o.candidates.contains { $0.backend == .cloud }
                            if mode.usesCloud { cloudFailures = cloudAnswered ? 0 : cloudFailures + 1 }
                        case .skipped(let why): it.state = .skipped(why)
                        case .failed(let why):
                            it.state = .failed(why)
                            if why.contains("Cloud:") { cloudFailures += 1 }
                        case .quotaReached: it.state = .skipped("Private Cloud Compute quota reached."); cloudBlocked = true
                        }
                    }
                    if !cloudBlocked, cloudFailures >= 3 {
                        // Cloud keeps erroring: stop spending time on it instead of failing every remaining file.
                        cloudBlocked = true
                        cloudBlockReason = "Private Cloud Compute isn’t responding."
                        self.banner = mode == .both ? "Private Cloud Compute isn’t responding. Remaining files use on-device only."
                                                    : "Private Cloud Compute isn’t responding. Switch to On-device to continue."
                    }
                    if cloudBlocked, self.banner == nil || !(self.banner ?? "").contains("quota") {
                        self.banner = mode == .both ? "Cloud quota reached. Remaining files use on-device only."
                                                    : "Cloud quota reached. Switch to On-device to continue."
                    }
                    self.recompute()
                    self.phase = .analyzing(done: done, total: targets.count)
                    launch()
                }
            }
            // Anything left over after Stop goes back to a neutral, retryable state.
            for i in self.items.indices where self.items[i].state == .queued || self.items[i].state == .analyzing {
                self.items[i].state = .skipped("Stopped before this file was read.")
            }
            self.phase = .idle
            self.analysisTask = nil
            self.refreshModelStatus()
            // Long runs happen in the background: say so when it's done (event-driven, no polling).
            if !NSApp.isActive && !Task.isCancelled { NSSound(named: NSSound.Name("Glass"))?.play() }
        }
    }

    func stop() { analysisTask?.cancel() }

    func retry(_ id: UUID) {
        update(id) { $0.manual = nil }
        startAnalysis(only: [id], creative: true)
    }

    // MARK: Editing

    private func update(_ id: UUID, _ change: (inout RenameItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    func recompute() {
        Planner.assignTargets(&items, dirNames: dirNames, style: style, template: template)
    }

    func setManual(_ id: UUID, _ text: String) {
        update(id) {
            $0.manual = text
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                $0.manual = nil
            } else if $0.state != .renamed {
                $0.state = .ready          // typing a name rescues skipped / failed rows
                $0.selected = true
            }
        }
        recompute()
    }

    /// Pick which model's suggestion to use for a row (only meaningful in "Both" mode).
    func choose(_ id: UUID, _ backend: Backend) {
        update(id) { it in
            guard let c = it.candidates.first(where: { $0.backend == backend }) else { return }
            it.choice = backend
            it.raw = c.rawName
            it.summary = c.summary
            it.manual = nil
        }
        recompute()
    }

    func setSelected(_ id: UUID, _ on: Bool) { update(id) { $0.selected = on } }

    /// Save the plan (original → new name, status, model, description) as CSV.
    func exportPlan() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "Agnomen plan.csv"
        guard p.runModal() == .OK, let u = p.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func status(_ s: ItemState) -> String {
            switch s {
            case .queued: return "queued"
            case .analyzing: return "reading"
            case .ready: return "ready"
            case .skipped(let w): return "skipped: \(w)"
            case .failed(let w): return "failed: \(w)"
            case .renamed: return "renamed"
            }
        }
        var rows = ["Original name,New name,Status,Model,Description"]
        for it in items {
            rows.append([it.originalName, it.target ?? "", status(it.state), it.choice?.label ?? "", it.summary ?? ""].map(q).joined(separator: ","))
        }
        do { try rows.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8); banner = "Exported \(items.count) rows." }
        catch { banner = "Couldn’t save the CSV: \(error.localizedDescription)" }
    }

    func selectAll(_ on: Bool) {
        for i in items.indices where items[i].willRename { items[i].selected = on }
    }

    func reveal(_ id: UUID) {
        if let it = items.first(where: { $0.id == id }) { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
    }

    // MARK: Apply / undo

    func applySelected() {
        guard !busy else { return }
        phase = .applying
        defer { phase = .idle }
        let fm = FileManager.default
        var moves: [RenameBatch.Move] = []
        var failures = 0
        for id in items.filter({ $0.selected && $0.willRename }).map(\.id) {
            guard let it = items.first(where: { $0.id == id }), let target = it.target else { continue }
            let dest = it.dir.appendingPathComponent(target)
            if fm.fileExists(atPath: dest.path) {
                update(id) { $0.state = .failed("A file named “\(target)” already exists.") }
                failures += 1
                continue
            }
            do {
                try fm.moveItem(at: it.url, to: dest)       // rename in place; never overwrites
                var wrote: String?
                if saveComment, let sum = it.summary, FinderComment.read(dest.path) == nil, FinderComment.write(sum, to: dest.path) { wrote = sum }
                moves.append(.init(from: it.url.path, to: dest.path, wroteComment: wrote))
                dirNames[it.dir.path]?.remove(NameFormatter.key(it.currentName))
                dirNames[it.dir.path, default: []].insert(NameFormatter.key(target))
                update(id) { $0.url = dest; $0.state = .renamed; $0.target = target }
            } catch {
                update(id) { $0.state = .failed(error.localizedDescription) }
                failures += 1
            }
        }
        recompute()
        if !moves.isEmpty, let folder {
            let bm = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            History.append(RenameBatch(folderName: folder.lastPathComponent, bookmark: bm, moves: moves))
            undoCount = moves.count
        }
        banner = failures == 0 ? "Renamed \(moves.count) file\(moves.count == 1 ? "" : "s"). You can undo this."
                               : "Renamed \(moves.count); \(failures) could not be renamed."
    }

    func undoLastBatch() {
        guard !busy, let r = History.undoLast() else { return }
        let n = r.restored.count
        banner = r.skipped == 0 ? "Restored \(n) original name\(n == 1 ? "" : "s")."
                                : "Restored \(n); \(r.skipped) skipped because they were moved or changed."
        undoCount = History.last?.moves.count ?? 0
        guard let folder else { return }
        // Put restored rows back in place, keeping the model's answers, so Undo doesn't re-read every file.
        var matched = 0
        for m in r.restored {
            if let i = items.firstIndex(where: { $0.url.path == m.to }) {
                items[i].url = URL(fileURLWithPath: m.from)
                items[i].state = .ready
                items[i].selected = true
                matched += 1
            }
        }
        if matched == r.restored.count {
            dirNames = Scanner.scan(folder, recursive: includeSubfolders).dirNames
            recompute()
        } else {
            rescan()                      // the undone batch wasn't from what's on screen
        }
    }
}
