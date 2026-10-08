import Foundation

struct EffectiveContextSource: Identifiable, Hashable {
    enum Scope: String, Hashable {
        case global = "Global"
        case repository = "Repository"
        case folder = "Folder"
    }

    let url: URL
    let scope: Scope
    let order: Int
    let relativeDirectory: String
    let estimatedTokens: Int
    let content: String
    var id: URL { url }
    var displayDirectory: String { relativeDirectory == "." ? "repository root" : relativeDirectory }
    var locationLabel: String {
        scope == .repository ? "Repository root" : "\(scope.rawValue) · \(displayDirectory)"
    }
}

struct ContextDiagnostic: Identifiable, Hashable {
    enum Severity: String, Hashable {
        case info = "Info"
        case warning = "Warning"
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
}

struct EffectiveContextReport: Equatable {
    let sources: [EffectiveContextSource]
    let diagnostics: [ContextDiagnostic]

    var estimatedTokens: Int { sources.reduce(0) { $0 + $1.estimatedTokens } }
    var referencedSkillNames: Set<String> {
        Set(sources.flatMap { CodexContextResolver.referencedSkillNames(in: $0.content) })
    }

    var compiledPrompt: String {
        compiledPrompt(replacing: nil, with: nil)
    }

    func compiledPrompt(replacing sourceURL: URL?, with replacement: String?) -> String {
        sources.map { source in
            let directory = source.displayDirectory
            let content = source.url == sourceURL ? (replacement ?? source.content) : source.content
            return """
            # AGENTS.md instructions for \(directory)
            <INSTRUCTIONS>
            \(content)
            </INSTRUCTIONS>
            """
        }.joined(separator: "\n\n")
    }

    func estimatedTokens(replacing sourceURL: URL, with replacement: String) -> Int {
        sources.reduce(0) { total, source in
            total + (source.url == sourceURL
                ? ContextAssessment.evaluate(replacement).estimatedTokens
                : source.estimatedTokens)
        }
    }
}

enum CodexContextResolver {
    static func resolve(
        home: URL,
        projectRoot: URL,
        workingDirectory: URL,
        availableSkillNames: Set<String> = [],
        fileManager: FileManager = .default
    ) -> EffectiveContextReport {
        let root = projectRoot.standardizedFileURL
        let cwd = workingDirectory.standardizedFileURL
        guard cwd.path == root.path || cwd.path.hasPrefix(root.path + "/") else {
            return EffectiveContextReport(
                sources: [],
                diagnostics: [ContextDiagnostic(
                    id: "outside-project",
                    severity: .warning,
                    title: "Working folder is outside the repository",
                    detail: "Choose a folder inside \(root.path)."
                )]
            )
        }

        var entries: [(url: URL, scope: EffectiveContextSource.Scope, directory: String)] = []
        let globalDirectory = home.appending(path: ".codex")
        if let global = preferredInstruction(in: globalDirectory, fileManager: fileManager) {
            entries.append((global, .global, "~/.codex"))
        }

        for directory in directories(from: root, through: cwd) {
            guard let file = preferredInstruction(in: directory, fileManager: fileManager) else { continue }
            let relative = directory.path == root.path ? "." : String(directory.path.dropFirst(root.path.count + 1))
            entries.append((file, directory.path == root.path ? .repository : .folder, relative))
        }

        let sources = entries.enumerated().map { index, entry in
            let content = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
            return EffectiveContextSource(
                url: entry.url,
                scope: entry.scope,
                order: index + 1,
                relativeDirectory: entry.directory,
                estimatedTokens: ContextAssessment.evaluate(content).estimatedTokens,
                content: content
            )
        }
        return EffectiveContextReport(
            sources: sources,
            diagnostics: diagnostics(for: sources, availableSkillNames: availableSkillNames, fileManager: fileManager)
        )
    }

    private static func directories(from root: URL, through cwd: URL) -> [URL] {
        if root.path == cwd.path { return [root] }
        var result = [root]
        var current = root
        let suffix = cwd.path.dropFirst(root.path.count + 1)
        for component in suffix.split(separator: "/") {
            current.append(path: String(component))
            result.append(current)
        }
        return result
    }

    private static func preferredInstruction(in directory: URL, fileManager: FileManager) -> URL? {
        let override = directory.appending(path: "AGENTS.override.md")
        if fileManager.fileExists(atPath: override.path) { return override }
        let standard = directory.appending(path: "AGENTS.md")
        return fileManager.fileExists(atPath: standard.path) ? standard : nil
    }

    private static func diagnostics(
        for sources: [EffectiveContextSource],
        availableSkillNames: Set<String>,
        fileManager: FileManager
    ) -> [ContextDiagnostic] {
        guard !sources.isEmpty else {
            return [ContextDiagnostic(
                id: "no-instructions",
                severity: .info,
                title: "No Codex instructions apply",
                detail: "Codex will run without an AGENTS.md instruction layer for this folder."
            )]
        }

        var results: [ContextDiagnostic] = []
        let total = sources.reduce(0) { $0 + $1.estimatedTokens }
        if total > 12_000 {
            results.append(ContextDiagnostic(
                id: "large-stack",
                severity: .warning,
                title: "Large instruction stack",
                detail: "The effective stack is approximately \(total) tokens before task context and model output."
            ))
        }

        for source in sources where source.url.lastPathComponent == "AGENTS.override.md" {
            let standard = source.url.deletingLastPathComponent().appending(path: "AGENTS.md")
            if fileManager.fileExists(atPath: standard.path) {
                results.append(ContextDiagnostic(
                    id: "override-\(source.url.path)",
                    severity: .info,
                    title: "Override replaces AGENTS.md",
                    detail: "\(source.relativeDirectory) uses AGENTS.override.md; the AGENTS.md beside it is not loaded."
                ))
            }
        }

        let directives = sources.flatMap { source in
            directiveLines(in: source.content).map { (source, $0) }
        }
        let duplicates = Dictionary(grouping: directives, by: { normalizedDirective($0.1) })
            .filter { !$0.key.isEmpty && Set($0.value.map { $0.0.url }).count > 1 }
        for (normalized, matches) in duplicates.sorted(by: { $0.key < $1.key }) {
            let locations = matches.map { $0.0.displayDirectory }.uniqued().joined(separator: ", ")
            results.append(ContextDiagnostic(
                id: "duplicate-\(normalized)",
                severity: .info,
                title: "Repeated directive",
                detail: "\"\(matches[0].1)\" appears in \(locations)."
            ))
        }

        let polarized = directives.compactMap { source, text -> (EffectiveContextSource, String, Bool, String)? in
            guard let value = directivePolarity(text) else { return nil }
            return (source, value.core, value.negative, text)
        }
        let tensions = Dictionary(grouping: polarized, by: { $0.1 }).filter { group in
            Set(group.value.map { $0.2 }).count > 1
        }
        for (core, matches) in tensions.sorted(by: { $0.key < $1.key }) {
            let examples = matches.prefix(2).map { "\"\($0.3)\" (\($0.0.displayDirectory))" }.joined(separator: " versus ")
            results.append(ContextDiagnostic(
                id: "tension-\(core)",
                severity: .warning,
                title: "Conflicting directives",
                detail: examples
            ))
        }

        let referencedSkills = Set(sources.flatMap { referencedSkillNames(in: $0.content) })
        for name in referencedSkills.subtracting(availableSkillNames).sorted() {
            results.append(ContextDiagnostic(
                id: "missing-skill-\(name)",
                severity: .warning,
                title: "Referenced skill is unavailable",
                detail: "The effective instructions reference `\(name)`, but no matching skill package was found."
            ))
        }
        return results
    }

    private static func directiveLines(in content: String) -> [String] {
        content.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["- ", "* "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    private static func normalizedDirective(_ directive: String) -> String {
        directive.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func directivePolarity(_ directive: String) -> (core: String, negative: Bool)? {
        let normalized = normalizedDirective(directive)
        let negativePrefixes = ["do not ", "don't ", "never ", "must not "]
        if let prefix = negativePrefixes.first(where: normalized.hasPrefix) {
            return (String(normalized.dropFirst(prefix.count)), true)
        }
        let positivePrefixes = ["always ", "must "]
        if let prefix = positivePrefixes.first(where: normalized.hasPrefix) {
            return (String(normalized.dropFirst(prefix.count)), false)
        }
        return (normalized, false)
    }

    static func referencedSkillNames(in content: String) -> [String] {
        let pieces = content.components(separatedBy: "`")
        guard pieces.count > 2 else { return [] }
        return stride(from: 1, to: pieces.count, by: 2).compactMap { index in
            let name = pieces[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let following = index + 1 < pieces.count ? pieces[index + 1].lowercased() : ""
            guard following.trimmingCharacters(in: .whitespaces).hasPrefix("skill"), !name.isEmpty else { return nil }
            return name.hasSuffix("/") ? String(name.dropLast()) : name
        }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
