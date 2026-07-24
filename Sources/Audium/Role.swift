import Foundation

/// AI Chat "Role" (spec §8) — a selectable system-prompt preset loaded from a bundled skill
/// markdown file. Sourced from two curated third-party skill repos (see Skills/THIRD_PARTY_LICENSES.md);
/// both happen to share the same YAML-frontmatter shape (`name:` + single-line `description:`),
/// which is what makes one small parser workable across both sources without per-source cases.
/// `category` drives the picker's grouping (spec §8: "group BY CATEGORY") — autopunk's files
/// carry it in frontmatter; filmcraft.md doesn't (single standalone file, no taxonomy of its
/// own), so it falls back to its own "Filmcraft" category rather than an empty/misc bucket.
struct Role: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let category: String
    let subcategory: String?
    let systemPrompt: String
}

/// Scans the bundled `Skills/` directory for role markdown files (spec §8). Parses only the
/// frontmatter fields the picker needs (`name`, `description`, `category`) with line-based
/// matching rather than a full YAML parser — both source repos' files are confirmed single-line
/// for these fields, so nothing more is needed. `subcategory` is read from the file's folder
/// position under `Skills/autopunk/<category>/<subcategory>/`, matching how the files were
/// imported (mirrors the source repo's own structure — see THIRD_PARTY_LICENSES.md), rather
/// than re-parsed from frontmatter, since the folder layout is already the authoritative source
/// for it.
enum RoleLibrary {
    /// Loaded once at first access; the bundled files don't change at runtime.
    static let all: [Role] = loadAll()

    /// `all` grouped by category and sorted for display — category sections alphabetically,
    /// roles within each by name. Computed once alongside `all` rather than per-render in the
    /// picker view.
    static let grouped: [(category: String, roles: [Role])] = {
        Dictionary(grouping: all, by: \.category)
            .map { (category: $0.key, roles: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }()

    /// Same bundled-resource lookup as YouTubeDownloader.resourceBinPath: prefer the shipped
    /// .app's Contents/Resources/Skills (copied+signed by build.sh), fall back to the
    /// repo-relative copy so `swift run` finds roles during dev without a full .app build.
    private static func skillsDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Skills"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let devFallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/Audium
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Skills")
        return FileManager.default.fileExists(atPath: devFallback.path) ? devFallback : nil
    }

    private static func loadAll() -> [Role] {
        guard let dir = skillsDirectory(),
              let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return [] }

        var roles: [Role] = []
        for case let url as URL in enumerator where url.pathExtension == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let (slug, summary, frontmatterCategory) = parseFrontmatter(text)
            else { continue } // THIRD_PARTY_LICENSES.md has no frontmatter and is skipped here
            // id must be unique across all 395 files — a relative path (not just the bare
            // filename) since many skills across different categories otherwise share a slug-like
            // name; also doubles as a stable, human-readable persisted value for
            // ChatSettings.defaultRoleID.
            let relativeID = url.path.hasPrefix(dir.path) ? String(url.path.dropFirst(dir.path.count + 1)) : url.lastPathComponent
            roles.append(Role(
                id: relativeID,
                // Both source repos' frontmatter `name:` is the same kebab-case slug as the
                // filename ("name: coverage-report-writer"), not a separate human title — there's
                // no cleaner field to prefer, so the display name is derived by title-casing it.
                name: titleCase(slug),
                summary: summary,
                category: frontmatterCategory.map(titleCase) ?? "Filmcraft",
                subcategory: subcategoryFromPath(url, skillsDir: dir),
                systemPrompt: bodyAfterFrontmatter(text)
            ))
        }
        return roles.sorted { $0.name < $1.name }
    }

    /// Folder layout is `Skills/autopunk/<category>/<subcategory>/<slug>.md` (or, for the rare
    /// category with no subcategory split, `Skills/autopunk/<category>/<slug>.md`); anything
    /// outside `Skills/autopunk/` (i.e. filmcraft.md) has no subcategory.
    private static func subcategoryFromPath(_ url: URL, skillsDir: URL) -> String? {
        let components = url.deletingLastPathComponent().pathComponents
        guard let autopunkIndex = components.firstIndex(of: "autopunk") else { return nil }
        let depthUnderAutopunk = components.count - autopunkIndex - 1
        guard depthUnderAutopunk >= 2 else { return nil } // category dir only, no subcategory split
        return components.last.map(titleCase)
    }

    /// Whole-slug overrides for names generic title-casing gets wrong: "pre-production" keeps
    /// its industry-standard hyphen rather than becoming two separate words like
    /// "production-support" correctly does. Checked before word-by-word splitting.
    private static let phraseOverrides: [String: String] = [
        "pre-production": "Pre-Production",
    ]

    /// Per-word overrides for title-casing gets wrong as a whole word: "youtube" is a brand name
    /// (not "Youtube"). Acronyms are handled separately below.
    private static let wordOverrides: [String: String] = [
        "youtube": "YouTube",
    ]

    /// Known acronyms across both category slugs ("tv-documentary", "pr-communications") and
    /// skill-name slugs ("gdpr-note-writer", "cms-fields-writer") — uppercased outright rather
    /// than title-cased into "Tv"/"Gdpr". Small, curated list rather than a heuristic (e.g.
    /// "all-caps-if-short"), since that would also catch ordinary short words like "ai" in
    /// non-acronym contexts... which, as it happens, IS one of these (spec §8: AI Chat Roles).
    private static let acronyms: Set<String> = ["tv", "pr", "ai", "seo", "cms", "gdpr", "qa", "pdf", "faq"]

    /// "coverage-report-writer" -> "Coverage Report Writer", "tv-documentary" -> "TV
    /// Documentary" — shared by category, subcategory, and role-name display, since all three
    /// are hyphenated slugs from the same two source repos' conventions.
    private static func titleCase(_ slug: String) -> String {
        if let override = phraseOverrides[slug] { return override }
        return slug.split(separator: "-")
            .map { word in
                let lower = word.lowercased()
                if let override = wordOverrides[lower] { return override }
                return acronyms.contains(lower) ? lower.uppercased() : lower.capitalized
            }
            .joined(separator: " ")
    }

    private static func parseFrontmatter(_ text: String) -> (slug: String, summary: String, category: String?)? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var name: String?
        var summary: String?
        var category: String?
        for line in lines[1..<closingIndex] {
            if let value = fieldValue(line, key: "name") { name = value }
            if let value = fieldValue(line, key: "description") { summary = value }
            if let value = fieldValue(line, key: "category") { category = value }
        }
        guard let name, let summary else { return nil }
        return (name, summary, category)
    }

    private static func bodyAfterFrontmatter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(closingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fieldValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        var value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
