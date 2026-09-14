import AppKit
import CoreText
import ImageIO
import PDFKit
import XCTest
@testable import FindAnythingCore

final class ExtractionTests: XCTestCase {
    private var temporaryDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("extraction-tests-\(UUID().uuidString)", isDirectory: true) }

    func test_markdown_when_headingsChange_expects_originalLineCoordinates() throws {
        try withDirectory { directory in
            let url = try write("# Decisions\nWe rejected the old database.\n\n## Replacement\nUse SQLite for the catalog.\n", name: "decision.md", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.count, 2)
            XCTAssertEqual(result.passages[0].line, 1)
            XCTAssertTrue(result.passages[0].location.contains("Decisions"))
            XCTAssertEqual(result.passages[1].line, 4)
            XCTAssertTrue(result.passages[1].location.contains("lines 4-5"))
            XCTAssertTrue(result.passages[1].text.contains("SQLite"))
        }
    }

    func test_longLine_when_chunked_expects_boundedPassagesOnSameSourceLine() throws {
        try withDirectory { directory in
            let url = try write(String(repeating: "x", count: 2_500), name: "long.txt", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.passages.map(\.text.count), [1_000, 1_000, 500])
            XCTAssertEqual(result.passages.map(\.line), [1, 1, 1])
            XCTAssertEqual(result.status, .indexed)
        }
    }

    func test_csv_when_quotedFieldsSpanLines_expects_cellsAndPhysicalLines() throws {
        try withDirectory { directory in
            let csv = "name,notes\r\nAlpha,\"first line\r\nsecond, \"\"quoted\"\" line\"\r\nBeta,done\r\n"
            let url = try write(csv, name: "items.csv", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            let multiline = try XCTUnwrap(result.passages.first { $0.cell == "B2" })
            XCTAssertEqual(multiline.sheet, "CSV")
            XCTAssertEqual(multiline.line, 2)
            XCTAssertTrue(multiline.text.contains("second, \"quoted\" line"))
            XCTAssertEqual(result.passages.first { $0.cell == "A3" }?.line, 4)
            XCTAssertEqual(result.passages.count, 6)
            let duplicate = try write(csv, name: "other-name.csv", in: directory)
            let duplicateResult = try DocumentExtractor().extract(url: duplicate, performOCR: false)
            XCTAssertEqual(duplicateResult.passages, result.passages, "Content-deduplicated coordinates must not retain another file's name.")
        }
    }

    func test_csv_when_quoteIsUnterminated_expects_partialCoverage() throws {
        try withDirectory { directory in
            let url = try write("name,notes\nAlpha,\"unterminated", name: "broken.csv", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .partial)
            XCTAssertEqual(result.passages.count, 2)
            XCTAssertTrue(result.detail?.contains("not terminated") == true)
        }
    }

    func test_docx_when_runsAndParagraphsExist_expects_orderedParagraphs() throws {
        try withDirectory { directory in
            let xml = """
            <w:document xmlns:w="urn:word"><w:body>
            <w:p><w:r><w:t>Database </w:t></w:r><w:r><w:t>decision</w:t></w:r></w:p>
            <w:p/>
            <w:p><w:r><w:t>Use SQLite</w:t><w:tab/><w:t>for metadata.</w:t></w:r></w:p>
            </w:body></w:document>
            """
            let url = try archive([("word/document.xml", xml)], name: "decision.docx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.map(\.text), ["Database decision", "Use SQLite\tfor metadata."])
            XCTAssertEqual(result.passages.map(\.location), ["Paragraph 1", "Paragraph 3"])
        }
    }

    func test_docx_when_textBoxNestsParagraphs_expects_outerTextAndDocumentOrderPreserved() throws {
        try withDirectory { directory in
            let xml = "<document><p><r><t>Outer before </t><drawing><txbxContent><p><r><t>Inner text</t></r></p></txbxContent></drawing><t>outer after</t></r></p></document>"
            let url = try archive([("word/document.xml", xml), ("word/header1.xml", "<header><p><t>Decision header</t></p></header>")], name: "nested.docx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.map(\.text), ["Outer before outer after", "Inner text", "Decision header"])
            XCTAssertEqual(result.passages.map(\.location), ["Paragraph 1", "Paragraph 2", "header1 · paragraph 1"])
        }
    }

    func test_office_when_embeddedObjectExists_expects_explicitPartialCoverage() throws {
        try withDirectory { directory in
            let url = try archive([("word/document.xml", "<document><p><t>Readable body</t></p></document>"), ("word/embeddings/object.bin", "embedded object")], name: "object.docx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .partial)
            XCTAssertTrue(result.passages.first?.text.contains("Readable body") == true)
            XCTAssertTrue(result.detail?.contains("Embedded images and objects") == true)
        }
    }

    func test_xlsx_when_sharedStringsAndFormulasExist_expects_sheetCellCoordinates() throws {
        try withDirectory { directory in
            let url = try archive([
                ("xl/workbook.xml", "<workbook xmlns:r=\"urn:rels\"><sheets><sheet name=\"Budget &amp; Plan\" r:id=\"r1\"/></sheets></workbook>"),
                ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"r1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
                ("xl/sharedStrings.xml", "<sst><si><r><t>Database</t></r><r><t> migration</t></r></si></sst>"),
                ("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row r=\"2\"><c r=\"A2\" t=\"s\"><v>0</v></c><c r=\"B2\" t=\"inlineStr\"><is><t>Approved</t></is></c><c r=\"C2\"><f>SUM(D2:E2)</f><v>1200</v></c></row></sheetData></worksheet>")
            ], name: "budget.xlsx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.map(\.cell), ["A2", "B2", "C2"])
            XCTAssertTrue(result.passages.allSatisfy { $0.sheet == "Budget & Plan" })
            XCTAssertTrue(result.passages[0].text.contains("Database migration"))
            XCTAssertTrue(result.passages[2].text.contains("SUM(D2:E2)"))
            XCTAssertTrue(result.passages[2].text.contains("1200"))
        }
    }

    func test_pptx_when_relationshipOrderDiffersFromFilenames_expects_correctSlideNumbers() throws {
        try withDirectory { directory in
            let url = try archive([
                ("ppt/presentation.xml", "<p:presentation xmlns:p=\"urn:ppt\" xmlns:r=\"urn:rels\"><p:sldIdLst><p:sldId r:id=\"r2\"/><p:sldId r:id=\"r1\"/></p:sldIdLst></p:presentation>"),
                ("ppt/_rels/presentation.xml.rels", "<Relationships><Relationship Id=\"r1\" Target=\"slides/slide1.xml\"/><Relationship Id=\"r2\" Target=\"slides/slide2.xml\"/></Relationships>"),
                ("ppt/slides/slide1.xml", "<slide xmlns:a=\"urn:drawing\"><a:p><a:r><a:t>Second in presentation</a:t></a:r></a:p></slide>"),
                ("ppt/slides/slide2.xml", "<slide xmlns:a=\"urn:drawing\"><a:p><a:r><a:t>First in presentation</a:t></a:r></a:p></slide>")
            ], name: "slides.pptx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.map(\.text), ["First in presentation", "Second in presentation"])
            XCTAssertEqual(result.passages.map(\.page), [1, 2])
            XCTAssertEqual(result.passages.map(\.location), ["Slide 1", "Slide 2"])
        }
    }

    func test_html_when_remoteResourcesAndScriptsExist_expects_localReadableTextOnly() throws {
        try withDirectory { directory in
            let url = try write("<html><head><title>Hidden title</title><style>secret css</style></head><body><h1>Decision &amp; outcome</h1><script>secret code</script><img src='https://example.invalid/tracker'><p>Use &#83;QLite.</p></body></html>", name: "page.html", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            let text = result.passages.map(\.text).joined()
            XCTAssertEqual(result.status, .indexed)
            XCTAssertTrue(text.contains("Decision & outcome"))
            XCTAssertTrue(text.contains("SQLite"))
            XCTAssertFalse(text.contains("secret"))
            XCTAssertFalse(text.contains("tracker"))
            XCTAssertFalse(text.contains("Hidden title"))
            XCTAssertNil(result.passages.first?.line)
        }
    }

    func test_html_when_scriptContainsLessThan_expects_followingVisibleTextPreserved() throws {
        try withDirectory { directory in
            let url = try write("<script>if (a < b) foo();</script><!-- hidden > text --><p>Visible decision</p>", name: "script.html", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.map(\.text).joined(), "Visible decision")
        }
    }

    func test_rtf_when_formattedTextExists_expects_plainContent() throws {
        try withDirectory { directory in
            let url = try write("{\\rtf1\\ansi Database \\b decision\\b0 .}", name: "note.rtf", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertTrue(result.passages.first?.text.contains("Database decision") == true)
        }
    }

    func test_pdf_when_textPagesExist_expects_oneBasedPageLocations() throws {
        try withDirectory { directory in
            let url = try pdf(pages: ["First database decision", "Second SQLite rationale"], in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .indexed)
            XCTAssertEqual(result.passages.map(\.page), [1, 2])
            XCTAssertTrue(result.passages[1].text.contains("SQLite rationale"))
            XCTAssertEqual(result.passages[1].location, "Page 2")
        }
    }

    func test_pdf_when_pageHasNoTextAndOCRDisabled_expects_needsOCR() throws {
        try withDirectory { directory in
            let url = try pdf(pages: [""], in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .needsOCR)
            XCTAssertTrue(result.passages.isEmpty)
        }
    }

    func test_image_when_OCREnabled_expects_locallyRecognizedText() throws {
        try withDirectory { directory in
            let image = try recognitionImage()
            let url = directory.appendingPathComponent("scan.png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            XCTAssertEqual(try DocumentExtractor().extract(url: url, performOCR: false).status, .needsOCR)
            let result = try DocumentExtractor().extract(url: url, performOCR: true)
            XCTAssertEqual(result.status, .indexed, result.detail ?? "")
            XCTAssertTrue(result.passages.map(\.text).joined().contains("DATABASE DECISION"))
            XCTAssertEqual(result.passages.first?.location, "Image · OCR")
        }
    }

    func test_pdf_when_imageBodyHasEmbeddedHeader_expects_OCRFindsBodyAndKeepsPage() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("mixed.pdf")
            let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 50, y: 740)
            let header = NSAttributedString(string: "Embedded header", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(header), context)
            context.draw(try recognitionImage(), in: CGRect(x: 50, y: 300, width: 512, height: 128))
            context.endPDFPage()
            context.closePDF()
            let firstPass = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(firstPass.status, .needsOCR)
            XCTAssertTrue(firstPass.passages.first?.text.contains("Embedded header") == true)
            let result = try DocumentExtractor().extract(url: url, performOCR: true)
            XCTAssertEqual(result.status, .indexed, result.detail ?? "")
            XCTAssertTrue(result.passages.map(\.text).joined().contains("DATABASE DECISION"))
            XCTAssertTrue(result.passages.allSatisfy { $0.page == 1 })
        }
    }

    func test_pptx_when_slideRelationshipIsMissing_expects_laterSlideCoordinatesStayCorrect() throws {
        try withDirectory { directory in
            let url = try archive([
                ("ppt/presentation.xml", "<presentation xmlns:r=\"urn:rels\"><sldIdLst><sldId r:id=\"missing\"/><sldId r:id=\"r2\"/></sldIdLst></presentation>"),
                ("ppt/_rels/presentation.xml.rels", "<Relationships><Relationship Id=\"r2\" Target=\"slides/slide2.xml\"/></Relationships>"),
                ("ppt/slides/slide2.xml", "<slide><p><t>Still slide two</t></p></slide>")
            ], name: "partial.pptx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .partial)
            XCTAssertEqual(result.passages.first?.page, 2)
            XCTAssertEqual(result.passages.first?.location, "Slide 2")
        }
    }

    func test_pdf_when_passwordProtected_expects_locked() throws {
        try withDirectory { directory in
            let original = try pdf(pages: ["Private content"], in: directory)
            let document = try XCTUnwrap(PDFDocument(url: original))
            let locked = directory.appendingPathComponent("locked.pdf")
            XCTAssertTrue(document.write(to: locked, withOptions: [.ownerPasswordOption: "owner-secret", .userPasswordOption: "user-secret"]))
            let result = try DocumentExtractor().extract(url: locked, performOCR: false)
            XCTAssertEqual(result.status, .locked)
            XCTAssertTrue(result.passages.isEmpty)
        }
    }

    func test_oversizedFile_when_sparseTextExceedsLimit_expects_failedWithReason() throws {
        try withDirectory { directory in
            let url = try write("", name: "large.txt", in: directory)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 65 * 1_024 * 1_024)
            try handle.close()
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .failed)
            XCTAssertTrue(result.detail?.contains("64 MiB") == true)
        }
    }

    func test_officeXML_when_externalEntityDeclared_expects_failedWithoutExpansion() throws {
        try withDirectory { directory in
            let xml = "<!DOCTYPE doc [<!ENTITY file SYSTEM 'file:///etc/passwd'>]><doc><p><t>&file;</t></p></doc>"
            let url = try archive([("word/document.xml", xml)], name: "entity.docx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .failed)
            XCTAssertTrue(result.passages.isEmpty)
            XCTAssertTrue(result.detail?.contains("entities") == true)
        }
    }

    func test_officeArchive_when_corrupt_expects_failedCoverage() throws {
        try withDirectory { directory in
            let url = try write("This is not a ZIP file", name: "broken.docx", in: directory)
            let result = try DocumentExtractor().extract(url: url, performOCR: false)
            XCTAssertEqual(result.status, .failed)
            XCTAssertFalse(result.detail?.isEmpty ?? true)
        }
    }

    func test_extraction_when_taskAlreadyCancelled_expects_cancellationPropagates() async throws {
        let directory = temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write("Database decision", name: "note.txt", in: directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentExtractor().extract(url: url, performOCR: false)
        }
        do { _ = try await task.value; XCTFail("Expected CancellationError") }
        catch is CancellationError {}
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ text: String, name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func pdf(pages: [String], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("document.pdf")
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 50, y: 700)
            let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func recognitionImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_600, height: 400, bitsPerComponent: 8, bytesPerRow: 6_400,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 400))
        context.textPosition = CGPoint(x: 70, y: 180)
        let text = NSAttributedString(string: "LOCAL DATABASE DECISION", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 70, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return try XCTUnwrap(context.makeImage())
    }

    /// Builds ZIP_STORED fixtures directly so tests need no Python or external ZIP writer.
    private func archive(_ files: [(String, String)], name: String, in directory: URL) throws -> URL {
        var bytes = Data()
        var central = Data()
        for (path, content) in files {
            let pathData = Data(path.utf8)
            let payload = Data(content.utf8)
            let checksum = crc32(payload)
            let offset = bytes.count
            bytes.le32(0x04034B50); bytes.le16(20); bytes.le16(0); bytes.le16(0); bytes.le16(0); bytes.le16(0)
            bytes.le32(checksum); bytes.le32(UInt32(payload.count)); bytes.le32(UInt32(payload.count))
            bytes.le16(UInt16(pathData.count)); bytes.le16(0); bytes.append(pathData); bytes.append(payload)
            central.le32(0x02014B50); central.le16(20); central.le16(20); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(checksum); central.le32(UInt32(payload.count)); central.le32(UInt32(payload.count))
            central.le16(UInt16(pathData.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0); central.le32(UInt32(offset)); central.append(pathData)
        }
        let centralOffset = bytes.count
        bytes.append(central)
        bytes.le32(0x06054B50); bytes.le16(0); bytes.le16(0); bytes.le16(UInt16(files.count)); bytes.le16(UInt16(files.count))
        bytes.le32(UInt32(central.count)); bytes.le32(UInt32(centralOffset)); bytes.le16(0)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFFFFFF
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xEDB88320 : 0) }
        }
        return value ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func le32(_ value: UInt32) { le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16)) }
}
