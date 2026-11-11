import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model = AppModel.shared

    var body: some View {
        Group {
            if model.folder == nil { EmptyState(model: model) } else { FileList(model: model) }
        }
        .frame(minWidth: 820, minHeight: 540)
        // Liquid Glass: the controls live in system bars above and below the list, which scrolls beneath them.
        .safeAreaBar(edge: .top, spacing: 0) { TopBar(model: model) }
        .safeAreaBar(edge: .bottom, spacing: 0) { Footer(model: model) }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            return model.handleDrop(u)
        } isTargeted: { model.dropTargeted = $0 }
    }
}

private struct TopBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if let note = model.modelNote { ModelBanner(message: note, blocking: model.modelBlocked) }
            if model.folder != nil { Header(model: model) }
        }
        .background(.regularMaterial)      // keeps scrolled rows from showing through behind the controls
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            Text("Drop a folder to rename its files")
                .font(.title2.weight(.semibold))
            Text("Agnomen reads each file on this Mac and suggests a name that says what it’s about, using Apple’s on-device model, or Private Cloud Compute if you choose it. You review every name before anything changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Choose Folder…") { model.chooseFolder() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            ModePicker(model: model)
                .padding(.top, 4)
            PrivacyLabel(model: model, long: true).padding(.top, 2)
            if let b = model.banner { Text(b).font(.caption).foregroundStyle(.orange) }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Header (folder + options)

private struct Header: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.folder?.lastPathComponent ?? "").font(.headline)
                    Text(model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ModePicker(model: model)
                        Button("Choose Another…") { model.chooseFolder() }
                            .buttonStyle(.glass)
                            .disabled(model.busy)
                    }
                }
            }
            HStack(spacing: 10) {
                Picker("Style", selection: $model.style) {
                    ForEach(NameStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                Picker("Format", selection: $model.templateChoice) {
                    ForEach(NameTemplate.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                if model.templateChoice == .custom {
                    TextField("{date} {title}", text: $model.customTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .help("Tokens: {title} {date} {created} {year} {original}")
                }
                TextField("Optional hint, e.g. “these are tax documents”", text: $model.hint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.startAnalysis() }
                    .disabled(model.busy)
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Menu {
                            Toggle("Include subfolders", isOn: $model.includeSubfolders).disabled(model.busy)
                            Toggle("Use current file name as a hint", isOn: $model.useExistingName)
                            Toggle("Save description as Finder comment", isOn: $model.saveComment)
                        } label: {
                            Label("Options", systemImage: "slider.horizontal.3")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.glass)
                        .fixedSize()
                        Button { model.startAnalysis() } label: {
                            Label("Re-analyze", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .disabled(model.busy || model.items.isEmpty)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - List

private struct FileList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.banner ?? "No files found in this folder.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.items) { item in
                    RowView(item: item, model: model)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }
}

private struct RowView: View {
    let item: RenameItem
    @ObservedObject var model: AppModel

    private var nameBinding: Binding<String> {
        Binding(get: { model.displayBase(item) }, set: { model.setManual(item.id, $0) })
    }
    private var selectedBinding: Binding<Bool> {
        Binding(get: { item.selected && item.willRename }, set: { model.setSelected(item.id, $0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Rename \(item.originalName)", isOn: selectedBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!item.willRename)
                .padding(.top, 6)
            Image(nsImage: model.icon(for: item.url)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.originalName)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary)
                    TextField(placeholder, text: nameBinding)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .disabled(item.state == .renamed || item.state == .analyzing || item.state == .queued)
                }
                detail
            }
            Spacer(minLength: 8)
            if !item.ext.isEmpty {
                Text("." + item.ext)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("The file type is never changed")
                    .padding(.top, 4)
            }
            status.frame(width: 78, alignment: .trailing).padding(.top, 4)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Try Another Name") { model.retry(item.id) }.disabled(model.busy || item.state == .renamed)
            Button("Reveal in Finder") { model.reveal(item.id) }
        }
    }

    private var placeholder: String {
        switch item.state {
        case .queued, .analyzing: return "Reading file…"
        default: return "Type a name…"
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .skipped(let why):
            Text(why).font(.caption).foregroundStyle(.orange).lineLimit(2)
        case .failed(let why):
            Text(why).font(.caption).foregroundStyle(.red).lineLimit(2)
        default:
            if item.state == .ready && item.candidates.count > 1 && item.manual == nil { candidateChips }
            if let manual = item.manual, let base = item.targetBase,
               NameFormatter.key(NameFormatter.sanitizeManual(manual)) != NameFormatter.key(base) {
                Text("Will be saved as “\(item.target ?? base)” to avoid a name clash")
                    .font(.caption).foregroundStyle(.orange)
            } else if let s = item.summary, item.manual == nil {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if item.state == .ready, !item.notes.isEmpty {
                Text(item.notes.joined(separator: " ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    /// "Both" mode: show each model's name; click to use that one.
    private var candidateChips: some View {
        let names = item.candidates.map { NameFormatter.format($0.rawName, style: model.style, date: nil) ?? "" }
        let agree = Set(names.map(NameFormatter.key)).count == 1
        return HStack(spacing: 6) {
            if agree {
                Label("On-device and Cloud agree", systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
            } else {
                ForEach(Array(item.candidates.enumerated()), id: \.offset) { i, c in
                    let on = item.choice == c.backend
                    Button { model.choose(item.id, c.backend) } label: {
                        Label(names[i], systemImage: c.backend.symbol).font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1))
                    .help("Use the \(c.backend.label) suggestion")
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.tertiary)
        case .analyzing: ProgressView().controlSize(.small)
        case .ready:
            if item.willRename { EmptyView() } else { Text("No change").font(.caption).foregroundStyle(.secondary) }
        case .renamed: Label("Renamed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Footer

private struct Footer: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                PrivacyLabel(model: model, long: false)
                progress
                Spacer()
                if let b = model.banner, model.folder != nil, !model.items.isEmpty {
                    Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Menu {
                    Button("Export Plan as CSV…") { model.exportPlan() }.disabled(model.items.isEmpty)
                    Divider()
                    Button("Select All") { model.selectAll(true) }
                    Button("Select None") { model.selectAll(false) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.glass)
                .fixedSize()
                Button(model.undoCount > 0 ? "Undo Last Rename (\(model.undoCount))" : "Undo Last Rename") { model.undoLastBatch() }
                    .buttonStyle(.glass)
                    .disabled(model.undoCount == 0 || model.busy)
                if model.analyzing {
                    Button("Stop") { model.stop() }.buttonStyle(.glass)
                }
                Button(renameTitle) { model.applySelected() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(model.pendingRenames == 0 || model.busy)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var renameTitle: String {
        let n = model.pendingRenames
        return n == 0 ? "Rename" : "Rename \(n) File\(n == 1 ? "" : "s")"
    }

    @ViewBuilder private var progress: some View {
        if case .analyzing(let done, let total) = model.phase {
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 90)
                Text("Reading \(min(done + 1, total)) of \(total)").font(.caption).foregroundStyle(.secondary)
            }
        } else if !model.items.isEmpty {
            Text("\(model.proposedRenames) of \(model.items.count) files have a new name")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Model choice + privacy indicator

private struct ModePicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Picker("Model", selection: Binding(get: { model.mode }, set: { model.requestMode($0) })) {
            ForEach(ModelMode.allCases) { m in
                Label(m.label, systemImage: symbol(m)).tag(m)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(model.busy)
        .help("On-device keeps everything on this Mac. Private Cloud Compute sends each file’s extracted text to Apple. Both runs the two side by side so you can pick per file.")
    }
    private func symbol(_ m: ModelMode) -> String {
        switch m {
        case .onDevice: return "laptopcomputer"
        case .cloud: return "icloud"
        case .both: return "square.on.square"
        }
    }
}

/// Says plainly whether file text leaves the Mac in the current mode, and why that's true.
private struct PrivacyLabel: View {
    @ObservedObject var model: AppModel
    let long: Bool
    var body: some View {
        if model.mode.usesCloud {
            Label(long ? "Cloud mode: the extracted text of each file is sent to Apple Private Cloud Compute."
                       : "Text sent to Private Cloud Compute",
                  systemImage: "icloud")
                .font(.caption).foregroundStyle(.orange)
                .help("Only the text Agnomen extracts is sent, never the files themselves. Switch to On-device only to keep everything local.")
        } else if !Sandbox.canUseNetwork {
            Label(long ? "On-device only. This build is sandboxed with no network access, so nothing can leave this Mac."
                       : "On-device · offline",
                  systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
                .help("macOS blocks this build from any network access.")
        } else {
            Label(long ? "On-device only. Nothing is sent anywhere in this mode."
                       : "On-device · nothing sent",
                  systemImage: "laptopcomputer")
                .font(.caption).foregroundStyle(.secondary)
                .help("This build is allowed to use the network (for Private Cloud Compute) but doesn’t in On-device mode.")
        }
    }
}

// MARK: - Model-unavailable / quota banner

private struct ModelBanner: View {
    let message: String
    let blocking: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: blocking ? "exclamationmark.triangle.fill" : "info.circle.fill").foregroundStyle(.orange)
            Text(message).font(.callout)
            Spacer()
            if blocking {
                Button("Open System Settings") {
                    if let u = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(u) }
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}
