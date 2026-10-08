import Foundation
import Testing
@testable import ContextApp

struct HarnessSupportTests {
    @Test func codexEffectiveContextFollowsRootToWorkingDirectoryOrder() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let home = base.appending(path: "home")
        let root = base.appending(path: "repo")
        let api = root.appending(path: "apps/api")
        try manager.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try manager.createDirectory(at: api, withIntermediateDirectories: true)
        try "global".write(to: home.appending(path: ".codex/AGENTS.md"), atomically: true, encoding: .utf8)
        try "root".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try "apps".write(to: root.appending(path: "apps/AGENTS.md"), atomically: true, encoding: .utf8)
        try "api".write(to: api.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

        let report = CodexContextResolver.resolve(home: home, projectRoot: root, workingDirectory: api)

        #expect(report.sources.map(\.relativeDirectory) == ["~/.codex", ".", "apps", "apps/api"])
        #expect(report.sources.map(\.order) == [1, 2, 3, 4])
        #expect(report.sources.last?.scope == .folder)
    }

    @Test func codexOverrideReplacesStandardFileInTheSameDirectory() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let home = base.appending(path: "home")
        let root = base.appending(path: "repo")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try "standard".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try "override".write(to: root.appending(path: "AGENTS.override.md"), atomically: true, encoding: .utf8)

        let report = CodexContextResolver.resolve(home: home, projectRoot: root, workingDirectory: root)

        #expect(report.sources.map { $0.url.lastPathComponent } == ["AGENTS.override.md"])
        #expect(report.diagnostics.contains { $0.id.hasPrefix("override-") })
    }

    @Test func codexResolverRejectsAWorkingDirectoryOutsideTheRepository() {
        let report = CodexContextResolver.resolve(
            home: URL(fileURLWithPath: "/tmp/home"),
            projectRoot: URL(fileURLWithPath: "/tmp/repo"),
            workingDirectory: URL(fileURLWithPath: "/tmp/elsewhere")
        )

        #expect(report.sources.isEmpty)
        #expect(report.diagnostics.first?.id == "outside-project")
    }

    @Test func codexResolverFindsDuplicatesConflictsAndMissingSkills() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let home = base.appending(path: "home")
        let root = base.appending(path: "repo")
        let api = root.appending(path: "api")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: api, withIntermediateDirectories: true)
        try """
        - Always use snapshots.
        - Use the `api-contracts` skill before schema work.
        - Run focused tests.
        """.write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try """
        - Never use snapshots.
        - Run focused tests.
        """.write(to: api.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

        let report = CodexContextResolver.resolve(
            home: home,
            projectRoot: root,
            workingDirectory: api,
            availableSkillNames: []
        )

        #expect(report.diagnostics.contains { $0.id.hasPrefix("duplicate-") })
        #expect(report.diagnostics.contains { $0.id.hasPrefix("tension-") })
        #expect(report.diagnostics.contains { $0.id == "missing-skill-api-contracts" })
        #expect(report.referencedSkillNames == ["api-contracts"])
    }

    @Test func compiledPreviewUsesCodexMessageOrderAndHeaders() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let home = base.appending(path: "home")
        let root = base.appending(path: "repo")
        let api = root.appending(path: "api")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: api, withIntermediateDirectories: true)
        try "root rule".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try "api rule".write(to: api.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)

        let preview = CodexContextResolver.resolve(home: home, projectRoot: root, workingDirectory: api).compiledPrompt

        #expect(preview.contains("# AGENTS.md instructions for repository root"))
        #expect(preview.contains("# AGENTS.md instructions for api"))
        #expect(preview.firstRange(of: "root rule")!.lowerBound < preview.firstRange(of: "api rule")!.lowerBound)
    }

    @Test func simulationReplacesOnlyTheSelectedSource() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appending(path: UUID().uuidString)
        let home = base.appending(path: "home")
        let root = base.appending(path: "repo")
        let api = root.appending(path: "api")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: api, withIntermediateDirectories: true)
        try "root rule".write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        try "old api rule".write(to: api.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        let report = CodexContextResolver.resolve(home: home, projectRoot: root, workingDirectory: api)
        let apiSource = try #require(report.sources.last)

        let preview = report.compiledPrompt(replacing: apiSource.url, with: "new api rule with more words")

        #expect(preview.contains("root rule"))
        #expect(preview.contains("new api rule with more words"))
        #expect(!preview.contains("old api rule"))
        #expect(report.estimatedTokens(replacing: apiSource.url, with: "new api rule with more words") > report.estimatedTokens)
    }

    @Test func sharedInstructionIsVisibleToSupportedHarnesses() {
        let file = InstructionFile(url: URL(fileURLWithPath: "/tmp/AGENTS.md"), harness: .shared, scope: "project")
        #expect(file.targets.contains(.codex))
        #expect(file.targets.contains(.cursor))
        #expect(file.targets.contains(.copilot))
    }

    @Test func claudeAndGeminiRemainDistinctFormats() {
        let claude = InstructionFile(url: URL(fileURLWithPath: "/tmp/CLAUDE.md"), harness: .claude, scope: "project")
        let gemini = InstructionFile(url: URL(fileURLWithPath: "/tmp/GEMINI.md"), harness: .gemini, scope: "project")
        #expect(claude.targets.contains(.claude))
        #expect(!claude.targets.contains(.gemini))
        #expect(gemini.targets.contains(.gemini))
        #expect(!gemini.targets.contains(.claude))
    }

    @Test func contextFitFlagsAnOversizedInstructionFile() {
        let large = Array(repeating: "Keep this requirement explicit and testable.", count: 3_500).joined(separator: " ")
        let assessment = ContextAssessment.evaluate(large)
        #expect(assessment.status == "Too large")
        #expect(assessment.estimatedTokens > 12_000)
    }

    @Test func contextFitKeepsFocusedInstructionFilesFocused() {
        let assessment = ContextAssessment.evaluate("# Project rules\n\nRun the focused tests before changing a contract.")
        #expect(assessment.status == "Focused")
        #expect(assessment.headingCount == 1)
    }

    @Test func detectsEverySupportedProjectInstructionFormat() {
        let root = URL(fileURLWithPath: "/tmp/context-fixture")
        let cases: [(String, Harness)] = [
            ("AGENTS.md", .shared),
            ("CLAUDE.md", .claude),
            ("GEMINI.md", .gemini),
            (".cursor/rules/api.mdc", .cursor),
            (".github/copilot-instructions.md", .copilot),
            (".clinerules", .cline),
            (".roo/rules/quality.md", .roo),
            (".windsurfrules", .windsurf),
            (".continue/rules/testing.md", .continueDev)
        ]
        for (path, expected) in cases {
            #expect(harnessForInstruction(root.appending(path: path), projectRoot: root) == expected)
        }
    }
}
