import Foundation

/// Minimal hand-rolled `.docx` (OOXML) writer shared by `Exporter`'s transcript export and
/// `PaperEditView`'s Paper Edit export (spec §8/§9). No third-party dependency: a real check for a
/// maintained Swift docx/OOXML library came up empty (`SwiftDocX`/`ooxml-swift`, the only two
/// candidates found, are both brand-new 2026 single-commit repos with ~0-25 stars and no real
/// maintenance history — not something to trust for "must open cleanly in Word" correctness). A
/// `.docx` is just a ZIP of a handful of well-documented, format-stable XML files, so this hand-
/// rolls exactly the three parts a docx needs (verified against two independent real sources, see
/// docs/spec.md): `[Content_Types].xml`, `_rels/.rels`, `word/document.xml` — no `styles.xml`
/// needed since every run sets its own font/size/bold/italic/color directly rather than relying on
/// an inherited "Normal" style. The ZIP container itself is built by shelling out to the system's
/// `/usr/bin/zip` (stock on every Mac, not bundled) rather than hand-rolling ZIP's binary format —
/// same reasoning as bundling `ffmpeg`/`yt-dlp`/`whisper-cli`: reuse a real, correct implementation
/// of the hard binary-format part instead of risking a "looks right as raw bytes but corrupt"
/// writer for something this project has no way to fully re-validate itself.
///
/// **Font is `Helvetica`, not `Calibri`** — found via a real bug, not a stylistic choice. An
/// earlier pass used `Calibri` (Word's modern default) and every `<w:b/>` bold run silently
/// rendered as regular weight in both `textutil`-converted RTF/HTML *and* real Pages, even though
/// the OOXML was verified byte-correct (`<w:b/>` genuinely present). Root cause: this machine's
/// `~/Library/Fonts` has only `Calibri.ttf` (Regular) and `Calibri Bold Italic.ttf` — no plain
/// "Calibri Bold" or "Calibri Italic" face exists as its own font file, and the renderer silently
/// drops a style trait it has no matching font file for rather than synthesizing it. Since
/// Calibri is a Microsoft font with no guarantee of being installed at all (let alone completely)
/// on any given Mac, and this project ships to real users' machines it doesn't control the font
/// library of, `Helvetica` was substituted and the exact same test re-verified correct (`Helvetica`,
/// `Helvetica-Bold`, `Helvetica-Oblique` all confirmed present as real distinct font files here,
/// and every trait combination rendered correctly afterward) — a core Apple system font guaranteed
/// present since classic Mac OS, eliminating this whole class of "looks right in the XML, wrong on
/// screen" failure. See docs/spec.md §9 for the full repro and the working/broken RTF diffs.
enum DocxExporter {
    /// One run of text within a paragraph. Sizes are in half-points (OOXML convention) — 22 = 11pt.
    struct Run {
        var text: String
        var bold: Bool = false
        var italic: Bool = false
        var color: String? = nil // hex RRGGBB, nil = inherit default (black)
        var sizeHalfPoints: Int = 22
    }

    struct Paragraph {
        var runs: [Run]
        /// Twentieths of a point (OOXML's `w:spacing` unit) — 200 = 10pt gap after the paragraph.
        var spacingAfterTwips: Int

        init(_ runs: [Run], spacingAfterTwips: Int = 200) {
            self.runs = runs
            self.spacingAfterTwips = spacingAfterTwips
        }
    }

    enum DocxError: Error, LocalizedError {
        case zipFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let status): return "/usr/bin/zip exited with status \(status)"
            }
        }
    }

    /// Builds the package in a scratch directory in the exact layout required, then zips it —
    /// `/usr/bin/zip -X` (strip macOS extended attributes, so no AppleDouble junk ends up inside
    /// the archive) with an explicit file list so entry order matches the conventional
    /// `[Content_Types].xml` → `_rels` → `word` layout real docx files use.
    static func write(paragraphs: [Paragraph], to url: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try contentTypesXML.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        let relsDir = tempDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try packageRelsXML.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        let wordDir = tempDir.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try documentXML(paragraphs).write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tempDir
        process.arguments = ["-X", "-q", "-r", url.path, "[Content_Types].xml", "_rels", "word"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocxError.zipFailed(process.terminationStatus)
        }
    }

    // MARK: - Package parts
    // Verified against two independent real sources (docs/spec.md §9): insidewml.com's "What's in
    // an Empty Word Document?" (confirmed this exact minimal 3-file structure opens in both Word
    // and LibreOffice Writer) and eduard93/docx's format writeup (confirmed the conventional
    // `word/document.xml` path — not the root-level `document.xml` the first source used — is what
    // real-world docx files and other readers, incl. Pages/Google Docs, expect).

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let packageRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static func documentXML(_ paragraphs: [Paragraph]) -> String {
        let body = paragraphs.map(paragraphXML).joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """
    }

    private static func paragraphXML(_ paragraph: Paragraph) -> String {
        let runsXML = paragraph.runs.map(runXML).joined()
        return "<w:p><w:pPr><w:spacing w:after=\"\(paragraph.spacingAfterTwips)\"/></w:pPr>\(runsXML)</w:p>"
    }

    /// Splits on embedded newlines into `<w:br/>`-separated `<w:t>` children within one run,
    /// rather than leaving a raw `\n` inside `<w:t>` (WordprocessingML doesn't treat that as a
    /// line break — it'd render as collapsed whitespace).
    private static func runXML(_ run: Run) -> String {
        var props = "<w:rFonts w:ascii=\"Helvetica\" w:hAnsi=\"Helvetica\"/><w:sz w:val=\"\(run.sizeHalfPoints)\"/>"
        if run.bold { props += "<w:b/>" }
        if run.italic { props += "<w:i/>" }
        if let color = run.color { props += "<w:color w:val=\"\(color)\"/>" }
        let content = run.text.components(separatedBy: "\n")
            .map { "<w:t xml:space=\"preserve\">\(xmlEscape($0))</w:t>" }
            .joined(separator: "<w:br/>")
        return "<w:r><w:rPr>\(props)</w:rPr>\(content)</w:r>"
    }

    private static func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
