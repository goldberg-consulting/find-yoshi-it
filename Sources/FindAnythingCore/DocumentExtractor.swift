import AppKit
import Darwin
import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads supported documents locally, returning bounded passages with source coordinates.
/// Originals are never modified. Cancellation propagates; coverage failures become explicit results.
public struct DocumentExtractor: Sendable {
    /// Changes whenever extraction or passage coordinates require a fresh index.
    public static let version = "1.0"

    /// Extensions whose content can be read by the built-in local extractors.
    public static let supportedExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "csv", "tsv", "html", "htm", "rtf",
        "pdf", "docx", "xlsx", "pptx", "png", "jpg", "jpeg", "tiff", "tif", "heic", "webp", "bmp",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "py", "js", "jsx", "ts", "tsx",
        "json", "jsonl", "yaml", "yml", "xml", "toml", "ini", "cfg", "conf", "sh", "zsh", "bash",
        "rs", "go", "java", "kt", "rb", "php", "sql", "css", "scss", "log", "tex", "rst"
    ]

    /// Creates an extractor with conservative per-document resource limits.
    public init() {}

    /// Extracts content and precise locations, optionally recognizing scanned pages and images.
    /// Files exceeding resource limits are reported as failed or partial, never as fully indexed.
    public func extract(url: URL, performOCR: Bool) throws -> ExtractionResult {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) || Self.extensionlessNames.contains(url.lastPathComponent.lowercased()) else {
            return ExtractionResult(passages: [], status: .unsupported, detail: "Content extraction is not available for this format.")
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw ReadFailure.invalid("The source is not a regular file.") }
            guard let size = values.fileSize, size <= Limits.fileBytes else {
                throw ReadFailure.limit("File exceeds the 64 MiB extraction limit.")
            }
            switch ext {
            case "pdf": return try extractPDF(url, performOCR: performOCR)
            case "png", "jpg", "jpeg", "tiff", "tif", "heic", "webp", "bmp":
                return try extractImage(url, performOCR: performOCR)
            case "docx", "xlsx", "pptx": return try extractOffice(url, kind: ext, size: size)
            default:
                let data = try boundedRead(url, limit: Limits.textBytes)
                let text: String
                if ext == "rtf" {
                    // RTF import is local. HTML deliberately uses our own reader to avoid remote resources.
                    text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
                } else {
                    text = try decodeText(data)
                }
                try Task.checkCancellation()
                if ext == "csv" || ext == "tsv" {
                    return try extractDelimited(text, delimiter: ext == "tsv" ? "\t" : ",", name: ext.uppercased())
                }
                let isHTML = ext == "html" || ext == "htm"
                let readable = isHTML ? try htmlText(text) : text
                var builder = PassageBuilder()
                try builder.appendLines(readable, markdown: ["md", "markdown", "mdown"].contains(ext), sourceLines: !isHTML && ext != "rtf")
                return builder.result()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch ReadFailure.locked(let message) {
            return ExtractionResult(passages: [], status: .locked, detail: message)
        } catch {
            let nsError = error as NSError
            let denied = nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileReadNoPermission.rawValue
            return ExtractionResult(passages: [], status: denied ? .denied : .failed, detail: error.localizedDescription)
        }
    }

    private static let extensionlessNames: Set<String> = ["readme", "license", "makefile", "dockerfile", "gemfile", ".gitignore"]
}

private enum Limits {
    static let fileBytes = 64 * 1_024 * 1_024
    static let textBytes = 8 * 1_024 * 1_024
    static let xmlTotalBytes = 32 * 1_024 * 1_024
    static let textCharacters = 4_000_000
    static let passages = 4_096
    static let passageCharacters = 1_000
    static let pages = 1_000
    static let ocrPages = 100
    static let imageDimension = 2_400
    static let archiveEntries = 20_000
    static let cells = 100_000
}

private enum ReadFailure: LocalizedError {
    case invalid(String), limit(String), locked(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message), .limit(let message), .locked(let message): return message
        }
    }
}

private func boundedRead(_ url: URL, limit: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var result = Data()
    while true {
        try Task.checkCancellation()
        guard let chunk = try handle.read(upToCount: min(65_536, limit - result.count + 1)), !chunk.isEmpty else { return result }
        result.append(chunk)
        guard result.count <= limit else { throw ReadFailure.limit("Text or XML exceeds the 8 MiB extraction limit.") }
    }
}

private func decodeText(_ data: Data) throws -> String {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
    if let text = String(data: data, encoding: .utf8), !text.contains("\0") { return text }
    // A narrow fallback preserves ordinary legacy text without silently indexing binary files.
    guard !data.contains(0), let text = String(data: data, encoding: .windowsCP1252) else {
        throw ReadFailure.invalid("The document is not readable UTF-8, UTF-16, or Windows text.")
    }
    return text
}

private struct PassageBuilder {
    var passages: [Passage] = []
    var limited = false
    private var characters = 0
    var full: Bool { passages.count >= Limits.passages || characters >= Limits.textCharacters }

    mutating func append(_ text: String, location: String, page: Int? = nil, line: Int? = nil, sheet: String? = nil, cell: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var start = clean.startIndex
        while start < clean.endIndex {
            guard !full else { limited = true; return }
            let end = clean.index(start, offsetBy: min(Limits.passageCharacters, Limits.textCharacters - characters), limitedBy: clean.endIndex) ?? clean.endIndex
            let part = String(clean[start..<end])
            passages.append(Passage(text: part, location: location, page: page, line: line, sheet: sheet, cell: cell))
            characters += part.count
            start = end
        }
    }

    mutating func appendLines(_ text: String, markdown: Bool, sourceLines: Bool) throws {
        var updated = self
        var lineNumber = 0
        var firstLine = 1
        var buffer = ""
        var heading: String?
        var stoppedForCancellation = false
        func location(_ endLine: Int) -> String {
            let range = firstLine == endLine ? "Line \(firstLine)" : "Lines \(firstLine)-\(endLine)"
            let label = sourceLines ? range : "Extracted text · \(range.lowercased())"
            return heading.map { "\($0) · \(label.lowercased())" } ?? label
        }
        text.enumerateLines { lineText, stop in
            if Task.isCancelled { stoppedForCancellation = true; stop = true; return }
            lineNumber += 1
            let isHeading = markdown && lineText.hasPrefix("#")
            if !buffer.isEmpty && (buffer.count + lineText.count + 1 > Limits.passageCharacters || isHeading) {
                updated.append(buffer, location: location(lineNumber - 1), line: sourceLines ? firstLine : nil)
                buffer = ""
            }
            if isHeading { heading = String(lineText.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
            if buffer.isEmpty { firstLine = lineNumber }
            if lineText.count > Limits.passageCharacters {
                updated.append(lineText, location: location(lineNumber), line: sourceLines ? lineNumber : nil)
            } else {
                if !buffer.isEmpty { buffer += "\n" }
                buffer += lineText
            }
            if updated.full { updated.limited = true; stop = true }
        }
        if stoppedForCancellation { throw CancellationError() }
        if !buffer.isEmpty { updated.append(buffer, location: location(lineNumber), line: sourceLines ? firstLine : nil) }
        self = updated
    }

    func result(detail: String? = nil) -> ExtractionResult {
        ExtractionResult(passages: passages, status: limited ? .partial : .indexed,
                         detail: limited ? "Extraction reached its per-document limit; some content is not indexed." : detail)
    }
}

private extension DocumentExtractor {
    func extractPDF(_ url: URL, performOCR: Bool) throws -> ExtractionResult {
        guard let document = PDFDocument(url: url) else { throw ReadFailure.invalid("The PDF could not be read.") }
        guard !document.isLocked else { throw ReadFailure.locked("This PDF requires a password.") }
        guard document.pageCount > 0 else { throw ReadFailure.invalid("The PDF contains no readable pages.") }
        var builder = PassageBuilder()
        var missingPages = 0
        var ocrCount = 0
        var unreadablePages = 0
        for index in 0..<min(document.pageCount, Limits.pages) {
            try Task.checkCancellation()
            guard !builder.full else { builder.limited = true; break }
            do {
                try autoreleasepool {
                    guard let page = document.page(at: index) else { unreadablePages += 1; return }
                    let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !text.isEmpty {
                        builder.append(text, location: "Page \(index + 1)", page: index + 1)
                    }
                    let needsRecognition = text.isEmpty || PDFImageDetector().containsImages(page)
                    if needsRecognition {
                        if performOCR && ocrCount < Limits.ocrPages {
                            ocrCount += 1
                            guard let image = renderPDFPage(page) else { unreadablePages += 1; return }
                            let recognized = try recognize(image)
                            // Keep embedded text authoritative and append newly recognized image text.
                            let additional = recognized.split(separator: "\n").filter { !text.contains($0) }.joined(separator: "\n")
                            builder.append(additional, location: "Page \(index + 1) · OCR", page: index + 1)
                        } else { missingPages += 1 }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { unreadablePages += 1 }
        }
        builder.limited = builder.limited || document.pageCount > Limits.pages || unreadablePages > 0 || (performOCR && missingPages > 0)
        if missingPages > 0 && !performOCR && !builder.limited {
            return ExtractionResult(passages: builder.passages, status: .needsOCR, detail: "\(missingPages) page(s) contain images or have no embedded text. Enable OCR to recognize scanned content.")
        }
        if unreadablePages > 0 {
            return ExtractionResult(passages: builder.passages, status: builder.passages.isEmpty ? .failed : .partial,
                                    detail: "\(unreadablePages) PDF page(s) could not be extracted or recognized.")
        }
        return builder.result(detail: builder.passages.isEmpty ? "No readable text was found in the PDF." : nil)
    }

    func extractImage(_ url: URL, performOCR: Bool) throws -> ExtractionResult {
        guard performOCR else { return ExtractionResult(passages: [], status: .needsOCR, detail: "Enable OCR to recognize text in this image.") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ReadFailure.invalid("The image could not be decoded.")
        }
        var builder = PassageBuilder()
        let frameCount = CGImageSourceGetCount(source)
        for index in 0..<min(frameCount, Limits.ocrPages) {
            try Task.checkCancellation()
            guard !builder.full else { builder.limited = true; break }
            try autoreleasepool {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                guard width > 0, height > 0, width * height <= 100_000_000 else {
                    throw ReadFailure.limit("Image dimensions exceed the 100 megapixel OCR limit.")
                }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                              kCGImageSourceThumbnailMaxPixelSize: Limits.imageDimension,
                                              kCGImageSourceShouldCacheImmediately: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    throw ReadFailure.invalid("The image preview could not be decoded.")
                }
                builder.append(try recognize(image), location: frameCount > 1 ? "Image \(index + 1) · OCR" : "Image · OCR", page: frameCount > 1 ? index + 1 : nil)
            }
        }
        builder.limited = builder.limited || frameCount > Limits.ocrPages
        return builder.result(detail: builder.passages.isEmpty ? "OCR found no readable text." : nil)
    }

    func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.preferBackgroundProcessing = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    func renderPDFPage(_ page: PDFPage) -> CGImage? {
        guard let reference = page.pageRef else { return nil }
        let bounds = reference.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(CGFloat(Limits.imageDimension) / max(bounds.width, bounds.height), 3)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        return context.makeImage()
    }
}

// Images can coexist with embedded headers or page numbers. Inspecting bounded PDF
// resources avoids treating those pages as fully searchable before their OCR pass.
private final class PDFImageDetector {
    private var foundImage = false
    private var visited = 0
    private var depth = 0
    private var uncertain = false

    func containsImages(_ page: PDFPage) -> Bool {
        guard let reference = page.pageRef else { return false }
        var dictionary: CGPDFDictionaryRef? = reference.dictionary
        for _ in 0..<8 {
            guard let current = dictionary else { break }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                inspectResources(resources)
                return foundImage || uncertain
            }
            var parent: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(current, "Parent", &parent)
            dictionary = parent
        }
        return false
    }

    private func inspectResources(_ resources: CGPDFDictionaryRef) {
        guard !foundImage else { return }
        guard depth < 8, visited < 10_000 else { uncertain = true; return }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return }
        depth += 1
        defer { depth -= 1 }
        CGPDFDictionaryApplyFunction(objects, { _, object, context in
            guard let context else { return }
            Unmanaged<PDFImageDetector>.fromOpaque(context).takeUnretainedValue().inspectObject(object)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func inspectObject(_ object: CGPDFObjectRef) {
        guard !foundImage else { return }
        guard visited < 10_000 else { uncertain = true; return }
        visited += 1
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
        if strcmp(subtype, "Image") == 0 { foundImage = true }
        else if strcmp(subtype, "Form") == 0 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources { inspectResources(resources) }
        }
    }
}

// Only central-directory entries with conservative sizes are ever passed to unzip.
// Output is streamed through a bounded pipe, with cancellation and a per-entry deadline.
private struct OfficeArchive {
    struct Entry { let name: String; let bytes: Int }
    let url: URL
    let entries: [String: Entry]
    private var expandedBytes = 0

    init(url: URL, size: Int) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 8) ?? Data()
        if prefix.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw ReadFailure.locked("This Office document is encrypted or uses a legacy container.") }
        guard size >= 22 else { throw ReadFailure.invalid("The Office archive is incomplete.") }
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: UInt64(size - tailSize))
        let tail = try handle.read(upToCount: tailSize) ?? Data()
        guard tail.count >= 22 else { throw ReadFailure.invalid("The Office archive is incomplete.") }
        let end = stride(from: tail.count - 22, through: 0, by: -1).first {
            tail.u32($0) == 0x06054B50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10) else { throw ReadFailure.invalid("The Office ZIP directory is invalid or spans multiple disks.") }
        let entryCount = Int(tail.u16(end + 10))
        let directorySize = Int(tail.u32(end + 12))
        let directoryOffset = Int(tail.u32(end + 16))
        guard entryCount <= Limits.archiveEntries, directorySize <= Limits.textBytes,
              directoryOffset + directorySize <= size - tailSize + end else {
            throw ReadFailure.limit("The Office archive directory exceeds extraction limits or uses ZIP64.")
        }
        try handle.seek(toOffset: UInt64(directoryOffset))
        let directory = try handle.read(upToCount: directorySize) ?? Data()
        var found: [String: Entry] = [:]
        var offset = 0
        for _ in 0..<entryCount {
            try Task.checkCancellation()
            guard offset + 46 <= directory.count, directory.u32(offset) == 0x02014B50 else {
                throw ReadFailure.invalid("The Office ZIP directory is corrupt.")
            }
            let flags = directory.u16(offset + 8)
            let nameLength = Int(directory.u16(offset + 28))
            let next = offset + 46 + nameLength + Int(directory.u16(offset + 30)) + Int(directory.u16(offset + 32))
            guard next <= directory.count,
                  let name = String(data: directory.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.split(separator: "/").contains(".."),
                  found[name] == nil else { throw ReadFailure.invalid("The Office archive contains invalid or duplicate entry names.") }
            guard flags & 1 == 0 else { throw ReadFailure.locked("This Office archive requires a password.") }
            found[name] = Entry(name: name, bytes: Int(directory.u32(offset + 24)))
            offset = next
        }
        self.entries = found
    }

    mutating func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ReadFailure.invalid("The Office archive is missing \(name).") }
        guard entry.bytes <= Limits.textBytes, expandedBytes + entry.bytes <= Limits.xmlTotalBytes else {
            throw ReadFailure.limit("Office XML exceeds the 8 MiB per-part or 32 MiB per-document limit.")
        }
        // unzip interprets entry names as patterns. Reject wildcard syntax before invoking it.
        guard !name.contains(where: { "*?[]".contains($0) }) else { throw ReadFailure.invalid("The Office archive has an unsupported entry name.") }
        expandedBytes += entry.bytes
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, name]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(15)
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ReadFailure.limit("Office decompression exceeded its 15-second per-part budget.") }
            var descriptor = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 && errno != EINTR { throw ReadFailure.invalid("Office decompression could not be read.") }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ReadFailure.invalid("Office decompression failed.")
            }
            guard output.count + count <= entry.bytes, output.count + count <= Limits.textBytes else {
                throw ReadFailure.limit("Office archive output exceeded its declared size.")
            }
            output.append(contentsOf: bytes.prefix(count))
        }
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ReadFailure.limit("Office decompression did not finish within its budget.") }
            _ = poll(nil, 0, 20)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.count == entry.bytes else { throw ReadFailure.invalid("The Office archive is corrupt or failed its checksum.") }
        return output
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

/// A bounded streaming XML reader. DTDs and external entities are never accepted.
private final class XMLWalker: NSObject, XMLParserDelegate {
    var start: ((XMLWalker, String, [String: String]) -> Void)?
    var text: ((XMLWalker, String) -> Void)?
    var end: ((XMLWalker, String) -> Void)?
    var stopped = false
    private var cancelled = false
    private var characters = 0
    private var events = 0

    func parse(_ data: Data) throws {
        let safetyText = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        guard !safetyText.contains("<!DOCTYPE"), !safetyText.contains("<!ENTITY") else {
            throw ReadFailure.invalid("Office XML with document types or entities is not supported.")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let success = parser.parse()
        if cancelled { throw CancellationError() }
        guard success || stopped else { throw ReadFailure.invalid("Office XML is malformed: \(parser.parserError?.localizedDescription ?? "unknown parse error")") }
    }

    private func proceed(_ parser: XMLParser) -> Bool {
        events += 1
        if Task.isCancelled { cancelled = true; parser.abortParsing(); return false }
        if stopped || events > 1_000_000 || characters > Limits.textCharacters {
            stopped = true; parser.abortParsing(); return false
        }
        return true
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard proceed(parser) else { return }
        start?(self, elementName.split(separator: ":").last.map(String.init) ?? elementName, attributeDict)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characters += string.count
        guard proceed(parser) else { return }
        text?(self, string)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard proceed(parser) else { return }
        end?(self, elementName.split(separator: ":").last.map(String.init) ?? elementName)
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

private extension DocumentExtractor {
    func extractOffice(_ url: URL, kind: String, size: Int) throws -> ExtractionResult {
        var archive = try OfficeArchive(url: url, size: size)
        var builder = PassageBuilder()
        do {
            switch kind {
            case "docx":
                let data = try archive.read("word/document.xml")
                let blocks = try officeParagraphs(data)
                for (index, block) in blocks.values.enumerated() {
                    try Task.checkCancellation()
                    builder.append(block, location: "Paragraph \(index + 1)")
                    if builder.full { builder.limited = true; break }
                }
                builder.limited = builder.limited || blocks.limited
                let extraParts = archive.entries.keys.filter { path in
                    guard path.hasPrefix("word/"), path.hasSuffix(".xml"), path.split(separator: "/").count == 2 else { return false }
                    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    return ["footnotes", "endnotes", "comments"].contains(name) || name.hasPrefix("header") || name.hasPrefix("footer")
                }.sorted()
                for path in extraParts.prefix(Limits.pages) {
                    try Task.checkCancellation()
                    guard !builder.full else { builder.limited = true; break }
                    let label = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    let extra = try officeParagraphs(archive.read(path))
                    for (index, block) in extra.values.enumerated() {
                        builder.append(block, location: "\(label) · paragraph \(index + 1)")
                        if builder.full { builder.limited = true; break }
                    }
                    builder.limited = builder.limited || extra.limited
                }
                builder.limited = builder.limited || extraParts.count > Limits.pages
            case "pptx":
                // Slide numbers come from the presentation relationship order, not ZIP entry order.
                let rels = try relationships(archive.read("ppt/_rels/presentation.xml.rels"), base: "ppt")
                let walker = XMLWalker()
                var slidePaths: [String?] = []
                var missingSlides = false
                walker.start = { _, name, attributes in
                    guard name == "sldId" else { return }
                    let path = attributes["r:id"].flatMap { rels[$0] }
                    slidePaths.append(path)
                    if path == nil { missingSlides = true }
                }
                try walker.parse(archive.read("ppt/presentation.xml"))
                guard slidePaths.contains(where: { $0 != nil }) else { throw ReadFailure.invalid("The presentation contains no readable slides.") }
                for (index, path) in slidePaths.prefix(Limits.pages).enumerated() {
                    try Task.checkCancellation()
                    guard let path else { continue }
                    let blocks = try officeParagraphs(archive.read(path))
                    builder.append(blocks.values.joined(separator: "\n"), location: "Slide \(index + 1)", page: index + 1)
                    builder.limited = builder.limited || blocks.limited
                    if builder.full { builder.limited = true; break }
                    let slideURL = URL(fileURLWithPath: "/" + path)
                    let parent = String(slideURL.deletingLastPathComponent().path.dropFirst())
                    let relationshipsPath = parent + "/_rels/" + slideURL.lastPathComponent + ".rels"
                    if archive.entries[relationshipsPath] != nil {
                        let links = try relationships(archive.read(relationshipsPath), base: parent)
                        for notePath in Set(links.values.filter { $0.hasPrefix("ppt/notesSlides/") && $0.hasSuffix(".xml") }).sorted() {
                            let notes = try officeParagraphs(archive.read(notePath))
                            builder.append(notes.values.joined(separator: "\n"), location: "Slide \(index + 1) · speaker notes", page: index + 1)
                            builder.limited = builder.limited || notes.limited
                        }
                    }
                }
                builder.limited = builder.limited || walker.stopped || missingSlides || slidePaths.count > Limits.pages
            case "xlsx":
                try extractWorkbook(archive: &archive, builder: &builder)
            default: break
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if builder.passages.isEmpty { throw error }
            return ExtractionResult(passages: builder.passages, status: .partial, detail: "Some Office content could not be extracted: \(error.localizedDescription)")
        }
        if archive.entries.keys.contains(where: { $0.contains("/media/") || $0.contains("/embeddings/") }) {
            return ExtractionResult(passages: builder.passages, status: .partial,
                                    detail: "Office text was extracted. Embedded images and objects are not extracted or OCR'd." + (builder.limited ? " A document extraction limit was also reached." : ""))
        }
        return builder.result(detail: kind == "xlsx" ? "Spreadsheet formulas use saved values; formulas are not recalculated." : nil)
    }

    func officeParagraphs(_ data: Data) throws -> (values: [String], limited: Bool) {
        let walker = XMLWalker()
        var values: [String] = []
        var paragraphStack: [Int] = []
        var inText = false
        walker.start = { walker, name, _ in
            if name == "p" {
                guard values.count < 100_000 else { walker.stopped = true; return }
                paragraphStack.append(values.count)
                values.append("")
            }
            if name == "t" { inText = true }
            if let index = paragraphStack.last {
                if name == "tab" { values[index] += "\t" }
                if name == "br" { values[index] += "\n" }
            }
        }
        walker.text = { _, text in if inText, let index = paragraphStack.last { values[index] += text } }
        walker.end = { _, name in
            if name == "t" { inText = false }
            if name == "p" { _ = paragraphStack.popLast() }
        }
        try walker.parse(data)
        return (values, walker.stopped)
    }

    func relationships(_ data: Data, base: String) throws -> [String: String] {
        let walker = XMLWalker()
        var paths: [String: String] = [:]
        walker.start = { _, name, attributes in
            guard name == "Relationship", attributes["TargetMode"] != "External",
                  let id = attributes["Id"], let target = attributes["Target"], !target.contains(":") else { return }
            let candidate = target.hasPrefix("/") ? String(target.dropFirst()) : base + "/" + target
            var parts: [String] = []
            for component in candidate.split(separator: "/") {
                if component == ".." { if !parts.isEmpty { parts.removeLast() } }
                else if component != "." { parts.append(String(component)) }
            }
            paths[id] = parts.joined(separator: "/")
        }
        try walker.parse(data)
        guard !walker.stopped else { throw ReadFailure.limit("Office relationships exceed the XML parsing limit.") }
        return paths
    }

    func extractWorkbook(archive: inout OfficeArchive, builder: inout PassageBuilder) throws {
        let rels = try relationships(archive.read("xl/_rels/workbook.xml.rels"), base: "xl")
        let workbook = XMLWalker()
        var sheets: [(name: String, path: String)] = []
        var missingSheets = false
        workbook.start = { _, element, attributes in
            guard element == "sheet" else { return }
            if let name = attributes["name"], let id = attributes["r:id"], let path = rels[id] { sheets.append((name, path)) }
            else { missingSheets = true }
        }
        try workbook.parse(archive.read("xl/workbook.xml"))
        guard !sheets.isEmpty else { throw ReadFailure.invalid("The workbook contains no readable sheets.") }
        var shared: [String] = []
        if archive.entries["xl/sharedStrings.xml"] != nil {
            let strings = XMLWalker()
            var value = ""
            var inText = false
            strings.start = { _, name, _ in
                if name == "si" { value = "" }
                if name == "t" { inText = true }
            }
            strings.text = { _, text in if inText { value += text } }
            strings.end = { walker, name in
                if name == "t" { inText = false }
                if name == "si" {
                    shared.append(value)
                    if shared.count >= Limits.cells { walker.stopped = true }
                }
            }
            try strings.parse(archive.read("xl/sharedStrings.xml"))
            // Partial string tables cannot safely resolve subsequent cell references.
            guard !strings.stopped else { throw ReadFailure.limit("The workbook shared-string table exceeds extraction limits.") }
        }
        for sheet in sheets.prefix(Limits.pages) {
            try Task.checkCancellation()
            let parsed = try sheetCells(archive.read(sheet.path), shared: shared)
            for cell in parsed.values {
                builder.append("\(cell.reference): \(cell.text)", location: "\(sheet.name) · \(cell.reference)", sheet: sheet.name, cell: cell.reference)
                if builder.full { builder.limited = true; break }
            }
            builder.limited = builder.limited || parsed.limited
            if builder.full { break }
        }
        builder.limited = builder.limited || workbook.stopped || missingSheets || sheets.count > Limits.pages
    }

    func sheetCells(_ data: Data, shared: [String]) throws -> (values: [(reference: String, text: String)], limited: Bool) {
        let walker = XMLWalker()
        var cells: [(reference: String, text: String)] = []
        var reference = ""
        var type = ""
        var value = ""
        var formula = ""
        var current = ""
        var invalidReference = false
        walker.start = { _, name, attributes in
            if name == "c" { reference = attributes["r"] ?? ""; type = attributes["t"] ?? ""; value = ""; formula = "" }
            if ["v", "t", "f"].contains(name) { current = name }
        }
        walker.text = { _, text in
            if current == "f" { formula += text }
            else if current == "v" || current == "t" { value += text }
        }
        walker.end = { walker, name in
            if name == current { current = "" }
            guard name == "c" else { return }
            var resolved = value
            if type == "s" {
                if let index = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), shared.indices.contains(index) { resolved = shared[index] }
                else { invalidReference = true; return }
            } else if type == "b" { resolved = value == "1" ? "TRUE" : "FALSE" }
            if !formula.isEmpty { resolved = "=\(formula)" + (resolved.isEmpty ? "" : " [saved value: \(resolved)]") }
            guard !resolved.isEmpty else { return }
            guard validCellReference(reference) else { invalidReference = true; return }
            cells.append((reference, resolved))
            if cells.count >= Limits.cells { walker.stopped = true }
        }
        try walker.parse(data)
        return (cells, walker.stopped || invalidReference)
    }

    func validCellReference(_ value: String) -> Bool {
        let letters = value.prefix(while: { $0.isASCII && $0 >= "A" && $0 <= "Z" })
        let digits = value.dropFirst(letters.count)
        guard (1...3).contains(letters.count), !digits.isEmpty, digits.count <= 7,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), let row = Int(digits), (1...1_048_576).contains(row) else { return false }
        let column = letters.utf8.reduce(0) { $0 * 26 + Int($1) - 64 }
        return column <= 16_384
    }
}

private extension DocumentExtractor {
    func extractDelimited(_ text: String, delimiter: Character, name: String) throws -> ExtractionResult {
        var builder = PassageBuilder()
        var field = ""
        var fieldCharacters = 0
        var row: [String] = []
        var quoted = false
        var closedQuote = false
        var index = text.startIndex
        var rowNumber = 1
        var physicalLine = 1
        var rowStartLine = 1
        var visited = 0
        func finishRow() {
            row.append(field)
            for (column, value) in row.enumerated() where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cell = spreadsheetColumn(column + 1) + String(rowNumber)
                builder.append("\(cell): \(value)", location: "\(name) · \(cell) · line \(rowStartLine)", line: rowStartLine, sheet: name, cell: cell)
                if builder.full { builder.limited = true; break }
            }
            row.removeAll(keepingCapacity: true); field = ""; fieldCharacters = 0; closedQuote = false; rowNumber += 1
        }
        while index < text.endIndex {
            visited += 1
            if visited % 4_096 == 0 { try Task.checkCancellation() }
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex && text[next] == "\"" { field.append("\""); fieldCharacters += 1; index = text.index(after: next); continue }
                    quoted = false; closedQuote = true
                } else { field.append(character); fieldCharacters += 1 }
            } else if character == "\"" && field.isEmpty && !closedQuote {
                quoted = true
            } else if character == delimiter {
                row.append(field); field = ""; fieldCharacters = 0; closedQuote = false
                if row.count > 16_384 { throw ReadFailure.limit("The delimited document exceeds 16,384 columns.") }
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                finishRow()
                if builder.full { builder.limited = true; break }
            } else if closedQuote && !character.isWhitespace {
                throw ReadFailure.invalid("The delimited document contains characters after a closing quote.")
            } else if !closedQuote { field.append(character); fieldCharacters += 1 }
            if character == "\n" || character == "\r\n" || character == "\r" {
                physicalLine += 1
                if !quoted { rowStartLine = physicalLine }
            }
            if fieldCharacters > Limits.textCharacters { throw ReadFailure.limit("A delimited field exceeds the extraction character limit.") }
            index = next
        }
        guard !quoted else {
            if !builder.passages.isEmpty { return ExtractionResult(passages: builder.passages, status: .partial, detail: "A quoted field was not terminated; later rows were not indexed.") }
            throw ReadFailure.invalid("The delimited document has an unterminated quoted field.")
        }
        if !builder.full && (!field.isEmpty || !row.isEmpty || closedQuote) { finishRow() }
        return builder.result()
    }

    func spreadsheetColumn(_ number: Int) -> String {
        var number = number
        var result = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            if let scalar = UnicodeScalar(65 + remainder) { result = String(Character(scalar)) + result }
            number = (number - 1) / 26
        }
        return result
    }

    func htmlText(_ html: String) throws -> String {
        var result = ""
        var index = html.startIndex
        var hiddenTag: String?
        var visited = 0
        let blocks: Set<String> = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer"]
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "\u{2013}", "mdash": "\u{2014}", "copy": "©"]
        while index < html.endIndex {
            visited += 1
            if visited % 4_096 == 0 { try Task.checkCancellation() }
            if html[index] == "<" {
                if html[index...].hasPrefix("<!--") {
                    guard let end = html.range(of: "-->", range: html.index(index, offsetBy: 4)..<html.endIndex) else { break }
                    index = end.upperBound
                    continue
                }
                let after = html.index(after: index)
                var end = after
                var quote: Character?
                while end < html.endIndex {
                    let character = html[end]
                    if let active = quote { if character == active { quote = nil } }
                    else if character == "\"" || character == "'" { quote = character }
                    else if character == ">" { break }
                    end = html.index(after: end)
                    visited += 1
                    if visited % 4_096 == 0 { try Task.checkCancellation() }
                }
                guard end < html.endIndex else { break }
                let tag = html[after..<end].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let closing = tag.hasPrefix("/")
                let name = String(tag.drop(while: { $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }))
                if ["script", "style", "noscript", "template", "head"].contains(name) {
                    if !closing && ["script", "style"].contains(name) {
                        let bodyStart = html.index(after: end)
                        guard let closingTag = html.range(of: "</" + name, options: .caseInsensitive, range: bodyStart..<html.endIndex),
                              let closingEnd = html[closingTag.upperBound...].firstIndex(of: ">") else { break }
                        index = html.index(after: closingEnd)
                        continue
                    }
                    if closing && hiddenTag == name { hiddenTag = nil }
                    else if !closing && hiddenTag == nil { hiddenTag = name }
                }
                if hiddenTag == nil && blocks.contains(name) { result += "\n" }
                index = html.index(after: end)
                continue
            }
            if hiddenTag == nil {
                if html[index] == "&" {
                    let after = html.index(after: index)
                    let limit = html.index(after, offsetBy: 12, limitedBy: html.endIndex) ?? html.endIndex
                    if let end = html[after..<limit].firstIndex(of: ";") {
                        let token = String(html[after..<end])
                        var decoded = entities[token]
                        if token.hasPrefix("#") {
                            let hexadecimal = token.lowercased().hasPrefix("#x")
                            let digits = token.dropFirst(hexadecimal ? 2 : 1)
                            if let number = UInt32(digits, radix: hexadecimal ? 16 : 10), let scalar = UnicodeScalar(number) { decoded = String(scalar) }
                        }
                        if let decoded { result += decoded; index = html.index(after: end); continue }
                    }
                }
                result.append(html[index])
            }
            index = html.index(after: index)
        }
        return result
    }
}
