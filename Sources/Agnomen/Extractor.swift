import Foundation
import AppKit
import PDFKit
import Vision
import AVFoundation
import UniformTypeIdentifiers
import Compression

/// What we managed to read out of a file, entirely on this Mac.
struct Extracted {
    var kind: String        // human description, e.g. "PDF document"
    var text: String        // cleaned, length-capped content handed to the model
    var method: String      // how it was read: "pdf text", "ocr", "docx", …; "locked"; "none"
    var hasContent: Bool { text.count >= 12 }
}

enum Extractor {
    /// Vision's request queue deadlocks when many threads call it at once (observed with 10 concurrent
    /// requests: every worker parked in VNControlledCapacityTasksQueue forever). Cap simultaneous requests.
    private static let visionGate = DispatchSemaphore(value: 3)

    /// Run synchronous, possibly blocking work (PDFKit, Vision, file parsing) on a GCD thread. Swift's
    /// cooperative pool has one thread per core and doesn't grow when a thread blocks, so blocking there
    /// can starve everything else, including other files' model calls.
    private static func offPool<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
        }
    }

    /// ~1.5–2k tokens: plenty to identify a document, leaves room in the 8k window.
    static let maxChars = 6000

    static func extract(_ url: URL) async -> Extracted {
        let vals = try? url.resourceValues(forKeys: [.contentTypeKey, .localizedTypeDescriptionKey])
        let ext = url.pathExtension.lowercased()
        let type = vals?.contentType ?? UTType(filenameExtension: ext)
        let kind = vals?.localizedTypeDescription ?? type?.localizedDescription ?? "File"

        var text = ""
        var method = "none"

        if ext == "svg" || ext == "html" || ext == "htm" || ext == "xhtml" {
            text = await offPool { html(url) }; method = "html"
        } else if let type, type.conforms(to: .pdf) {
            (text, method) = await offPool { pdf(url) }
        } else if let type, type.conforms(to: .image) {
            (text, method) = await offPool { image(url) }
        } else if ["docx", "docm", "pptx", "pptm", "xlsx", "xlsm"].contains(ext) {
            text = await offPool { ooxml(url, ext: ext) }; method = ext
        } else if ["rtf", "rtfd", "doc", "odt", "wordml"].contains(ext) {
            text = await offPool { richText(url) }; method = "rich text"
        } else if let type, type.conforms(to: .audiovisualContent) {
            text = await media(url); method = "metadata"
        } else {
            // Plain text, source code, JSON, CSV, Markdown, logs and anything else that sniffs as text.
            text = await offPool { plain(url) }; method = text.isEmpty ? "none" : "text"
        }
        return Extracted(kind: kind, text: cap(tidy(text)), method: text.isEmpty && method != "locked" ? "none" : method)
    }

    // MARK: Plain text

    static func plain(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        guard var data = try? h.read(upToCount: 96 * 1024), !data.isEmpty else { return "" }
        if data.prefix(4096).contains(0) { return "" }              // binary
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        for _ in 0..<4 {                                            // a read can cut a UTF-8 sequence in half
            if let s = String(data: data, encoding: .utf8) { return s }
            data.removeLast()
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: HTML / SVG

    static func html(_ url: URL) -> String {
        var s = plain(url)
        guard !s.isEmpty else { return "" }
        var title = ""
        if let r = s.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) {
            title = String(s[r]).replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
        }
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        return (title.isEmpty ? "" : "Page title: \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n") + s
    }

    // MARK: PDF (text layer first, OCR for scans)

    static func pdf(_ url: URL) -> (String, String) {
        guard let doc = PDFDocument(url: url) else { return ("", "none") }
        if doc.isLocked { return ("", "locked") }
        var out = ""
        for i in 0..<min(doc.pageCount, 12) {
            if let s = doc.page(at: i)?.string { out += s + "\n" }
            if out.utf8.count > maxChars * 3 { break }
        }
        var title = ""
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           t.count > 3, !t.lowercased().hasPrefix("microsoft word") {
            title = "Document title: \(t)\n"
        }
        let clean = tidy(out)
        if clean.count >= 80 { return (title + clean, "pdf text") }

        // Scanned / image-only PDF: OCR the first two pages.
        var ocrText = ""
        for i in 0..<min(doc.pageCount, 2) {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard box.width > 0, box.height > 0 else { continue }
            let scale = 2000 / max(box.width, box.height)
            let img = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { ocrText += ocr(cg) + "\n" }
        }
        let combined = tidy(title + clean + "\n" + ocrText)
        return (combined, ocrText.isEmpty ? "pdf (no text)" : "pdf + ocr")
    }

    // MARK: Images (OCR + on-device classification)

    static func image(_ url: URL) -> (String, String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ("", "none") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return ("", "none") }
        let labels = classify(cg)
        let text = ocr(cg)
        var out = ""
        if !labels.isEmpty { out += "Visual content (on-device classifier): \(labels.joined(separator: ", "))\n" }
        if !tidy(text).isEmpty { out += "Text found in the image:\n\(text)" }
        return (out, "ocr + labels")
    }

    static func ocr(_ cg: CGImage) -> String {
        visionGate.wait(); defer { visionGate.signal() }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func classify(_ cg: CGImage) -> [String] {
        visionGate.wait(); defer { visionGate.signal() }
        let req = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        return (req.results ?? [])
            .filter { $0.confidence >= 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(6)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    // MARK: Office Open XML (docx / pptx / xlsx)

    static func ooxml(_ url: URL, ext: String) -> String {
        guard let zip = ZipArchive(url: url) else { return "" }
        var out = ""
        if let core = zip.read("docProps/core.xml") {
            let c = XMLTextCollector(textTags: ["dc:title", "dc:subject"], breakTags: ["dc:title", "dc:subject"], limit: 600)
            c.run(core)
            let t = tidy(c.out)
            if !t.isEmpty { out += "Document properties: \(t)\n" }
        }
        switch ext {
        case "docx", "docm":
            if let d = zip.read("word/document.xml") {
                let c = XMLTextCollector(textTags: ["w:t"], breakTags: ["w:p", "w:br"], limit: maxChars * 3)
                c.run(d); out += c.out
            }
        case "pptx", "pptm":
            let slides = zip.names
                .compactMap { n -> (Int, String)? in
                    guard n.hasPrefix("ppt/slides/slide"), n.hasSuffix(".xml"),
                          let num = Int(n.dropFirst("ppt/slides/slide".count).dropLast(4)) else { return nil }
                    return (num, n)
                }
                .sorted { $0.0 < $1.0 }
            for (num, name) in slides.prefix(12) {
                guard let d = zip.read(name) else { continue }
                let c = XMLTextCollector(textTags: ["a:t"], breakTags: ["a:p"], limit: 2000)
                c.run(d)
                out += "Slide \(num):\n\(c.out)\n"
                if out.utf8.count > maxChars * 3 { break }
            }
        default: // xlsx / xlsm
            if let wb = zip.read("xl/workbook.xml") {
                let c = XMLTextCollector(textTags: [], breakTags: [], attrTags: ["sheet": "name"], limit: 800)
                c.run(wb)
                if !c.out.isEmpty { out += "Sheet names:\n\(c.out)\n" }
            }
            if let ss = zip.read("xl/sharedStrings.xml") {
                let c = XMLTextCollector(textTags: ["t"], breakTags: ["si"], limit: maxChars * 3)
                c.run(ss); out += "Cell text:\n\(c.out)"
            }
        }
        return out
    }

    // MARK: Rich text / legacy Word

    static func richText(_ url: URL) -> String {
        guard let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return "" }
        return a.string
    }

    // MARK: Audio / video metadata

    static func media(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        var lines: [String] = []
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey?.rawValue,
                      ["title", "artist", "albumName", "creator", "subject", "description", "type"].contains(key),
                      let v = try? await item.load(.stringValue), !v.isEmpty else { continue }
                lines.append("\(key == "albumName" ? "Album" : key.capitalized): \(v)")
            }
        }
        if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 {
            let s = Int(d.seconds)
            lines.append("Duration: \(s / 60):" + String(format: "%02d", s % 60))
        }
        // Duration alone says nothing about content, so don't count it as readable.
        return lines.contains(where: { !$0.hasPrefix("Duration") }) ? lines.joined(separator: "\n") : ""
    }

    // MARK: Text hygiene

    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cap(_ s: String) -> String { String(s.prefix(maxChars)) }
}

// MARK: - Minimal ZIP reader (stored + deflate), enough for Office files

struct ZipArchive {
    private struct Entry { var method: UInt16; var compSize: Int; var size: Int; var offset: Int }
    private let data: Data
    private var entries: [String: Entry] = [:]
    var names: [String] { Array(entries.keys) }

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 22 else { return nil }
        data = d
        // End-of-central-directory record: scan backwards for PK\5\6.
        var eocd = -1
        var i = d.count - 22
        let stop = max(0, d.count - 22 - 65535)
        while i >= stop {
            if d[i] == 0x50, d[i + 1] == 0x4B, d[i + 2] == 0x05, d[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(p) == 0x02014B50 else { break }
            let nameLen = Int(u16(p + 28)), extraLen = Int(u16(p + 30)), commentLen = Int(u16(p + 32))
            guard p + 46 + nameLen <= d.count else { break }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(method: u16(p + 10), compSize: Int(u32(p + 20)), size: Int(u32(p + 24)), offset: Int(u32(p + 42)))
            p += 46 + nameLen + extraLen + commentLen
        }
        if entries.isEmpty { return nil }
    }

    func read(_ name: String, limit: Int = 24_000_000) -> Data? {
        guard let e = entries[name], e.size <= limit, e.offset + 30 <= data.count, u32(e.offset) == 0x04034B50 else { return nil }
        let start = e.offset + 30 + Int(u16(e.offset + 26)) + Int(u16(e.offset + 28))
        guard start >= 0, start + e.compSize <= data.count else { return nil }
        let comp = data.subdata(in: start..<(start + e.compSize))
        switch e.method {
        case 0: return comp
        case 8:
            guard e.size > 0 else { return Data() }
            var out = Data(count: e.size)
            let n = out.withUnsafeMutableBytes { dp -> Int in
                comp.withUnsafeBytes { sp -> Int in
                    guard let d = dp.bindMemory(to: UInt8.self).baseAddress,
                          let s = sp.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, e.size, s, comp.count, nil, COMPRESSION_ZLIB)
                }
            }
            return n > 0 ? out.prefix(n) : nil
        default: return nil
        }
    }

    private func u16(_ o: Int) -> UInt16 { UInt16(data[o]) | UInt16(data[o + 1]) << 8 }
    private func u32(_ o: Int) -> UInt32 {
        UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
    }
}

/// Pulls text (and chosen attributes) out of XML, with line breaks at given elements.
final class XMLTextCollector: NSObject, XMLParserDelegate {
    let textTags: Set<String>, breakTags: Set<String>, attrTags: [String: String]
    let limit: Int
    var out = ""
    private var depth = 0
    private weak var parser: XMLParser?

    init(textTags: Set<String>, breakTags: Set<String>, attrTags: [String: String] = [:], limit: Int) {
        self.textTags = textTags; self.breakTags = breakTags; self.attrTags = attrTags; self.limit = limit
    }

    func run(_ data: Data) {
        let p = XMLParser(data: data)
        p.delegate = self
        parser = p
        p.parse()
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        if textTags.contains(el) { depth += 1 }
        if let attr = attrTags[el], let v = a[attr] { out += v + "\n" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if depth > 0 { out += s } }
    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        if textTags.contains(el) { depth = max(0, depth - 1); if breakTags.isEmpty || !breakTags.contains(el) { out += " " } }
        if breakTags.contains(el) { out += "\n" }
        if out.utf8.count > limit { p.abortParsing() }
    }
}
