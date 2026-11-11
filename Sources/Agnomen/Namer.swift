import Foundation
import FoundationModels

/// Guided-generation schema. `summary` comes first so the model states what the
/// file is before committing to a name.
@Generable
struct NameSuggestion {
    @Guide(description: "One short sentence: what this file is and what it is about.")
    var summary: String

    @Guide(description: "A specific, descriptive file name of at most 7 words: document type first, then the main subject, then one key detail. No file extension.")
    var name: String
}

/// Which model answered. `.cloud` is Apple Private Cloud Compute.
enum Backend: String, CaseIterable, Identifiable, Hashable {
    case onDevice, cloud
    var id: String { rawValue }
    var label: String { self == .onDevice ? "On-device" : "Cloud" }
    var symbol: String { self == .onDevice ? "laptopcomputer" : "icloud" }
}

enum ModelMode: String, CaseIterable, Identifiable {
    case onDevice, cloud, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .onDevice: return "On-device only"
        case .cloud: return "Private Cloud Compute only"
        case .both: return "Both: compare side by side"
        }
    }
    var backends: [Backend] {
        switch self {
        case .onDevice: return [.onDevice]
        case .cloud: return [.cloud]
        case .both: return [.onDevice, .cloud]
        }
    }
    var usesCloud: Bool { self != .onDevice }
    /// Files read and named at once. Measured on 66 screenshots: 1 file = 82.7 s, 2 = 74.6 s, 4 = 73.7 s,
    /// 8 = 72.8 s, and 16 stalled for over 8 minutes inside the model service. So the on-device model is a
    /// single shared resource: past ~4 in flight there is no speedup, only heat. 4 keeps OCR and parsing
    /// fully overlapped with model calls without approaching the cliff. Cloud calls are network-bound.
    var concurrency: Int { self == .onDevice ? 4 : 4 }
}

enum ModelStatus: Equatable {
    case ready
    case unavailable(String)
}

struct CloudQuotaReached: Error { var resetDate: Date? }
struct BackendFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Namer {
    static let cloudModel = PrivateCloudComputeLanguageModel()

    static func status(_ backend: Backend = .onDevice) -> ModelStatus {
        switch backend {
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This Mac doesn't support Apple Intelligence, so the on-device model can't run.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri.")
                case .modelNotReady:
                    return .unavailable("The on-device model isn't ready yet. macOS is still preparing it; try again shortly.")
                @unknown default:
                    return .unavailable("The on-device model is unavailable.")
                }
            }
        case .cloud:
            switch cloudModel.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This Mac can't use Private Cloud Compute.")
                case .systemNotReady: return .unavailable("Private Cloud Compute isn't ready. Check your network connection and try again.")
                @unknown default: return .unavailable("Private Cloud Compute is unavailable.")
                }
            }
        }
    }

    /// nil when there's headroom; otherwise a user-facing line about the cloud quota.
    static func cloudQuotaNote() -> String? {
        let q = cloudModel.quotaUsage
        switch q.status {
        case .limitReached:
            let when = q.resetDate.map { " It resets \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            return "Private Cloud Compute quota reached.\(when)"
        case .belowLimit(let b):
            return b.isApproachingLimit ? "Private Cloud Compute quota is nearly used up." : nil
        @unknown default:
            return nil
        }
    }

    static func instructions(hint: String) -> String {
        var s = """
        You rename files. You are given a file's current name, its type and text extracted from it. \
        Write a short file name that tells a person at a glance what the file is about.

        Rules:
        - Lead with the kind of document (invoice, resume, lecture notes, boarding pass, lease, meeting notes, screenshot…), \
        then the most specific subject, then one or two distinguishing details found in the content: company, person, project, topic, place, month or year.
        - Prefer the main topic over listing every name or number in the file. Keep it short and natural.
        - For spreadsheets and data files, say what the data is about; do not pick out individual values.
        - Never put the file format (PDF, HTML, DOCX, image…) in the name; the extension already says it.
        - Examples of the style: "Invoice Brightline Plumbing Water Heater Repair June 2024", "Boarding Pass Lisbon to Madrid May 2023", \
        "Meeting Notes Website Redesign Kickoff", "Screenshot Wi-Fi Settings Window". \
        Never reuse an example's words unless the file is actually about them.
        - Use only facts that appear in the content or current name. Never invent names, numbers or dates.
        - Never output generic names such as "document", "file", "image" or "untitled" on their own.
        - The current file name may be uninformative (IMG_1234, Untitled, scan0042) or may contain useful hints. Use your judgement.
        - Write the name in the same language as the content.
        - Do not include the file extension.
        """
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { s += "\n\nBackground from the user about these files: \(String(h.prefix(300)))" }
        return s
    }

    static func prompt(currentName: String?, kind: String, text: String) -> String {
        var p = currentName.map { "Current file name: \($0)\n" } ?? ""
        p += "File type: \(kind)\n"
        if text.isEmpty {
            p += "\nNo content could be read from this file."
        } else {
            p += "\nContent extracted on this Mac (may be partial):\n\"\"\"\n\(text)\n\"\"\"\n"
        }
        p += "\nGive the summary and the file name."
        return p
    }

    /// Ask one model. Shrinks the content if it overflows the context window and, on-device,
    /// falls back to the permissive-transformations guardrail if the default one objects to a
    /// (user-owned) document's content.
    static func suggest(backend: Backend, currentName: String?, extracted: Extracted, hint: String, creative: Bool) async throws -> NameSuggestion {
        var limit = extracted.text.count
        var guardrails = SystemLanguageModel.Guardrails.default
        var lastError: Error?
        for _ in 0..<4 {
            do {
                let session: LanguageModelSession
                switch backend {
                case .onDevice:
                    session = LanguageModelSession(model: SystemLanguageModel(guardrails: guardrails), instructions: instructions(hint: hint))
                case .cloud:
                    session = LanguageModelSession(model: cloudModel, instructions: instructions(hint: hint))
                }
                let p = prompt(currentName: currentName, kind: extracted.kind, text: String(extracted.text.prefix(limit)))
                let options = creative
                    ? GenerationOptions(temperature: 0.9, maximumResponseTokens: 160)
                    : GenerationOptions(sampling: .greedy, maximumResponseTokens: 160)
                var result = try await session.respond(to: p, generating: NameSuggestion.self, options: options).content
                if NameFormatter.words(from: result.name).count > 9 {
                    // Over-long: ask once more for something tighter, in the same session.
                    let again = try await session.respond(
                        to: "That name is too long. Give a shorter one of at most 6 words with the same document type and main subject.",
                        generating: NameSuggestion.self, options: options).content
                    if NameFormatter.words(from: again.name).count < NameFormatter.words(from: result.name).count { result = again }
                }
                return result
            } catch let e as LanguageModelError {
                lastError = e
                switch e {
                case .contextSizeExceeded: limit = max(400, limit / 2)
                case .guardrailViolation where backend == .onDevice: guardrails = .permissiveContentTransformations
                default:
                    if backend == .cloud && !(e.isGuardrailOrRefusal) {
                        throw BackendFailure(message: "Private Cloud Compute couldn’t complete the request.")
                    }
                    throw e
                }
            } catch let e as PrivateCloudComputeLanguageModel.Error {
                switch e {
                case .quotaLimitReached(let q): throw CloudQuotaReached(resetDate: q.resetDate)
                case .networkFailure: throw BackendFailure(message: "Couldn't reach Private Cloud Compute (network).")
                case .serviceUnavailable: throw BackendFailure(message: "Private Cloud Compute is temporarily unavailable.")
                @unknown default: throw BackendFailure(message: e.localizedDescription)
                }
            }
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }
}

struct Candidate: Equatable {
    var backend: Backend
    var summary: String
    var rawName: String
}

/// Read → ask → result, shared by the app and the `--dry-run` command line mode.
enum Pipeline {
    struct Output {
        var candidates: [Candidate]     // one per model that answered, in backend order
        var chars: Int
        var method: String
        var notes: [String]             // e.g. "Cloud: quota reached", shown when one model failed
        var cloudQuotaHit: CloudQuotaReached?
    }
    enum Outcome {
        case named(Output)
        case skipped(String)
        case failed(String)
        case quotaReached(Date?)
    }

    static func analyze(url: URL, hint: String, backends: [Backend] = [.onDevice], creative: Bool = false, useName: Bool = true) async -> Outcome {
        if Scanner.isDataless(url) {
            return .skipped("Stored in iCloud and not downloaded. Reading it would need the network.")
        }
        var usable: [Backend] = []
        var notes: [String] = []
        for b in backends {
            switch Namer.status(b) {
            case .ready: usable.append(b)
            case .unavailable(let why): notes.append("\(b.label): \(why)")
            }
        }
        if usable.isEmpty { return .failed(notes.joined(separator: " ")) }

        let ex = await Extractor.extract(url)        // OCR / parsing: runs once, shared by every model
        if ex.method == "locked" { return .skipped("Password-protected PDF.") }
        if !ex.hasContent { return .skipped("Nothing readable to base a name on. You can type one.") }

        // Every selected model works on the same extracted text at the same time.
        let name: String? = useName ? url.lastPathComponent : nil
        let results: [(Backend, Result<NameSuggestion, Error>)] = await withTaskGroup(of: (Backend, Result<NameSuggestion, Error>).self) { group in
            for b in usable {
                group.addTask {
                    do { return (b, .success(try await Namer.suggest(backend: b, currentName: name, extracted: ex, hint: hint, creative: creative))) }
                    catch { return (b, .failure(error)) }
                }
            }
            var out: [(Backend, Result<NameSuggestion, Error>)] = []
            for await r in group { out.append(r) }
            return out
        }

        var candidates: [Candidate] = []
        var quota: CloudQuotaReached?
        var declined = 0
        for b in usable {
            guard let (_, r) = results.first(where: { $0.0 == b }) else { continue }
            switch r {
            case .success(let s):
                if NameFormatter.format(s.name, style: .spaces, date: nil) != nil {
                    candidates.append(Candidate(backend: b, summary: s.summary, rawName: s.name))
                } else { notes.append("\(b.label): gave no usable name.") }
            case .failure(let e):
                if let q = e as? CloudQuotaReached { quota = q; notes.append("Cloud: quota reached.") }
                else if let m = e as? LanguageModelError {
                    switch m {
                    case .guardrailViolation, .refusal: declined += 1; notes.append("\(b.label): declined to read this file.")
                    case .unsupportedLanguageOrLocale: declined += 1; notes.append("\(b.label): unsupported language.")
                    default: notes.append("\(b.label): \(m.localizedDescription)")
                    }
                } else { notes.append("\(b.label): \(e.localizedDescription)") }
            }
        }
        if candidates.isEmpty {
            if let q = quota, declined == 0, usable == [.cloud] { return .quotaReached(q.resetDate) }
            if declined > 0 && declined == usable.count { return .skipped("The model declined to read this file.") }
            return .failed(notes.joined(separator: " "))
        }
        return .named(Output(candidates: candidates, chars: ex.text.count, method: ex.method, notes: notes, cloudQuotaHit: quota))
    }
}

private extension LanguageModelError {
    var isGuardrailOrRefusal: Bool {
        switch self {
        case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale: return true
        default: return false
        }
    }
}
