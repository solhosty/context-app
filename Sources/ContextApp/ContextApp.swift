import AppKit
import SwiftUI
import Darwin

@main
struct ContextApp: App {
    @StateObject private var store = ContextStore()

    private var isUITestMode: Bool {
        ProcessInfo.processInfo.environment["CONTEXT_UI_TEST"] == "1"
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        if environment["CONTEXT_UI_TEST"] == "1" || environment["CONTEXT_RECORDING_MODE"] == "1" {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                ContextVerificationWindow.show(recordingMode: environment["CONTEXT_RECORDING_MODE"] == "1")
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContextMenu(store: store)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
                .accessibilityLabel("Context")
        }
        .menuBarExtraStyle(.window)

        WindowGroup(id: "context-window") {
            ContextWindow(store: store)
        }
        .defaultSize(width: 980, height: 680)
    }
}

@MainActor
private enum ContextVerificationWindow {
    private static var controller: NSWindowController?

    static func show(recordingMode: Bool = false) {
        guard controller == nil else { return }
        let store = ContextStore()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 520),
            styleMask: recordingMode ? [.borderless] : [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Context verification"
        window.isMovableByWindowBackground = recordingMode
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: ContextMenu(store: store))
        if recordingMode, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.maxX - 410, y: frame.maxY - 540))
        }
        let newController = NSWindowController(window: window)
        controller = newController
        newController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ContextStore: ObservableObject {
    @Published private(set) var projectURL: URL?
    @Published private(set) var workingDirectoryURL: URL?
    @Published private(set) var instructionFiles: [InstructionFile] = []
    @Published private(set) var effectiveCodexReport = EffectiveContextReport(sources: [], diagnostics: [])
    @Published private(set) var skills: [SkillPackage] = []
    @Published private(set) var plugins: [PluginPackage] = []
    @Published private(set) var projectSource = "Choose a project folder"
    @Published var requestedWorkspace: WorkspaceSection?
    @Published fileprivate var menuScreen = MenuScreen.overview
    @Published fileprivate var menuPackage: MenuPackage?
    @Published fileprivate var menuDirectory: URL?
    @Published fileprivate var menuEditingURL: URL?
    @Published fileprivate var menuEditorReturnScreen = MenuScreen.overview
    @Published fileprivate var menuEditorText = ""
    @Published fileprivate var menuEditorMessage = ""
    @Published fileprivate var menuEditorRevisions: [FileRevision] = []

    private let fileManager = FileManager.default
    private let bridgeFileURL: URL
    private let revisionStore = RevisionStore()
    private var lastBridgeValue: String?
    private var projectWatcher: DispatchSourceFileSystemObject?
    private var projectPicker: NSOpenPanel?

    init() {
        bridgeFileURL = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Context/active-project-path")
        let fixturePath = ProcessInfo.processInfo.environment["CONTEXT_TEST_PROJECT"]
        let fixtureRootPath = ProcessInfo.processInfo.environment["CONTEXT_TEST_PROJECT_ROOT"]
        if let fixturePath, fileManager.fileExists(atPath: fixturePath) {
            let fixtureRoot = fixtureRootPath.map { URL(fileURLWithPath: $0) }
            selectProject(URL(fileURLWithPath: fixturePath), source: "Verification fixture", rootOverride: fixtureRoot)
        } else if let savedPath = UserDefaults.standard.string(forKey: "context.projectPath") {
            selectProject(URL(fileURLWithPath: savedPath), source: "Manual selection")
        }
        if fixturePath == nil {
            readBridge()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.readBridge() }
            }
        }
    }

    var healthSymbol: String {
        if projectURL == nil { return "circle.dotted" }
        if instructionFiles.isEmpty { return "exclamationmark.circle" }
        return "checkmark.circle.fill"
    }

    var agentFiles: [URL] { instructionFiles.map(\.url) }
    var projectName: String { projectURL?.lastPathComponent ?? "Choose a project" }
    var projectPath: String { projectURL?.path ?? "No project selected" }
    var workingDirectoryPath: String { workingDirectoryURL?.path ?? projectPath }

    func chooseProject() {
        if let projectPicker {
            NSApp.activate(ignoringOtherApps: true)
            projectPicker.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        projectPicker = panel
        panel.title = "Choose a project folder"
        panel.prompt = "Use this project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            defer { self?.projectPicker = nil }
            guard response == .OK, let url = panel?.url else { return }
            self?.selectProject(url, source: "Manual selection")
        }
    }

    func selectProject(_ url: URL, source: String, rootOverride: URL? = nil) {
        // A project chosen in Context must not be replaced by an older value from
        // the optional manual switcher. A later `context-project use` call writes
        // a new token and will still be applied.
        if source == "Manual selection" {
            lastBridgeValue = try? String(contentsOf: bridgeFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let workingDirectory = url.standardizedFileURL
        workingDirectoryURL = workingDirectory
        projectURL = rootOverride?.standardizedFileURL ?? gitRoot(containing: workingDirectory) ?? workingDirectory
        projectSource = source
        UserDefaults.standard.set(workingDirectory.path, forKey: "context.projectPath")
        watchProject(at: projectURL ?? workingDirectory)
        refresh()
    }

    func refresh() {
        guard let root = projectURL else {
            instructionFiles = []
            effectiveCodexReport = EffectiveContextReport(sources: [], diagnostics: [])
            skills = []
            plugins = []
            return
        }

        instructionFiles = findInstructions(in: root)
        skills = findSkills(in: root)
        effectiveCodexReport = CodexContextResolver.resolve(
            home: fileManager.homeDirectoryForCurrentUser,
            projectRoot: root,
            workingDirectory: workingDirectoryURL ?? root,
            availableSkillNames: Set(skills.map(\.name)),
            fileManager: fileManager
        )
        plugins = findPlugins(in: root)
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func browseInContext(_ workspace: WorkspaceSection) { requestedWorkspace = workspace }

    fileprivate func browseInMenu(_ package: MenuPackage) {
        menuPackage = package
        menuDirectory = package.root
        menuScreen = .package
    }

    fileprivate func editInMenu(_ url: URL, returningTo screen: MenuScreen) {
        if menuEditingURL != url {
            menuEditorText = contents(of: url)
            menuEditorRevisions = revisions(for: url)
            menuEditorMessage = ""
        }
        menuEditingURL = url
        menuEditorReturnScreen = screen
        menuScreen = .editor
    }

    func saveMenuEditor() {
        guard let file = menuEditingURL else { return }
        do {
            try save(menuEditorText, to: file)
            menuEditorRevisions = revisions(for: file)
            menuEditorMessage = "Saved just now"
        } catch {
            menuEditorMessage = "Could not save: \(error.localizedDescription)"
        }
    }
    func contents(of url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func revisions(for url: URL) -> [FileRevision] { revisionStore.history(for: url) }

    func gitHistory(for url: URL) -> [GitRevision] {
        guard let root = projectURL, url.path.hasPrefix(root.path + "/") else { return [] }
        let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "log", "--format=%H%x1f%aI%x1f%s", "-n", "20", "--", relativePath]
        process.standardOutput = output
        do { try process.run(); process.waitUntilExit() } catch { return [] }
        guard process.terminationStatus == 0 else { return [] }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", maxSplits: 2).map(String.init)
            guard parts.count == 3, let date = ISO8601DateFormatter().date(from: parts[1]) else { return nil }
            return GitRevision(hash: parts[0], date: date, message: parts[2])
        }
    }

    func save(_ content: String, to url: URL) throws {
        revisionStore.capture(contents(of: url), for: url)
        try content.write(to: url, atomically: true, encoding: .utf8)
        refresh()
    }

    func saveReviewDraft(_ content: String, destination: ReviewDestination) throws -> URL {
        let drafts = fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Context/drafts")
        try fileManager.createDirectory(at: drafts, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "\(formatter.string(from: .now).replacingOccurrences(of: ":", with: "-"))-\(destination.filename).md"
        let file = drafts.appending(path: filename)
        let header = "# Context review draft\n\nDestination: \(destination.title)\nCreated: \(Date.now.formatted(date: .abbreviated, time: .shortened))\n\n"
        try (header + content).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func readBridge() {
        guard let value = try? String(contentsOf: bridgeFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let path = value.split(separator: "\n", maxSplits: 1).first.map(String.init),
              !path.isEmpty,
              value != lastBridgeValue,
              fileManager.fileExists(atPath: path) else { return }
        lastBridgeValue = value
        selectProject(URL(fileURLWithPath: path), source: "Manual project switcher")
    }

    private func gitRoot(containing directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: candidate.appending(path: ".git").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }

    private func findSkills(in root: URL) -> [SkillPackage] {
        let home = fileManager.homeDirectoryForCurrentUser
        let bases: [(URL, String)] = [
            (home.appending(path: ".agents/skills"), "global"),
            (home.appending(path: ".codex/skills"), "global"),
            (home.appending(path: ".claude/skills"), "global"),
            (root.appending(path: ".agents/skills"), "project"),
            (root.appending(path: ".codex/skills"), "project"),
            (root.appending(path: ".claude/skills"), "project")
        ]
        var found: [SkillPackage] = []
        for (base, scope) in bases {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            found.append(contentsOf: entries.compactMap { candidate in
                let manifest = candidate.appending(path: "SKILL.md")
                guard fileManager.fileExists(atPath: manifest.path) else { return nil }
                return SkillPackage(name: candidate.lastPathComponent, url: candidate, scope: scope)
            })
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func findInstructions(in root: URL) -> [InstructionFile] {
        let home = fileManager.homeDirectoryForCurrentUser
        let globalCandidates: [(URL, Harness)] = [
            (home.appending(path: ".agents/AGENTS.md"), .shared),
            (home.appending(path: ".codex/AGENTS.md"), .codex),
            (home.appending(path: ".claude/CLAUDE.md"), .claude),
            (home.appending(path: ".gemini/GEMINI.md"), .gemini),
            (home.appending(path: ".copilot/copilot-instructions.md"), .copilot)
        ]
        var found = globalCandidates.compactMap { url, harness in
            fileManager.fileExists(atPath: url.path) ? InstructionFile(url: url, harness: harness, scope: "global") : nil
        }
        let ignoredDirectories: Set<String> = [".git", ".build", "node_modules", "dist", "DerivedData"]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            let resource = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if resource?.isDirectory == true, ignoredDirectories.contains(url.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            guard resource?.isDirectory != true, let harness = harnessForInstruction(url, projectRoot: root) else { continue }
            found.append(InstructionFile(url: url, harness: harness, scope: "project"))
        }
        return Array(Set(found)).sorted { lhs, rhs in
            if lhs.scope != rhs.scope { return lhs.scope == "global" }
            return lhs.url.path.count < rhs.url.path.count
        }
    }

    private func findPlugins(in root: URL) -> [PluginPackage] {
        let home = fileManager.homeDirectoryForCurrentUser
        let bases: [(URL, String, String)] = [
            (home.appending(path: ".codex/plugins"), "Codex", "global"),
            (home.appending(path: ".codex/plugins/cache"), "Codex", "global"),
            (home.appending(path: ".claude/plugins"), "Claude", "global"),
            (root.appending(path: ".codex/plugins"), "Codex", "project"),
            (root.appending(path: ".claude/plugins"), "Claude", "project")
        ]
        var found: [PluginPackage] = []
        var seenPaths = Set<String>()
        for (base, harness, scope) in bases {
            guard let enumerator = fileManager.enumerator(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for case let manifest as URL in enumerator where manifest.lastPathComponent == "plugin.json" {
                let parent = manifest.deletingLastPathComponent()
                let packageRoot = parent.lastPathComponent == ".claude-plugin"
                    ? parent.deletingLastPathComponent()
                    : parent
                guard seenPaths.insert(packageRoot.path).inserted else { continue }
                found.append(PluginPackage(
                    name: packageRoot.lastPathComponent,
                    url: packageRoot,
                    harness: harness,
                    scope: scope
                ))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func watchProject(at root: URL) {
        projectWatcher?.cancel()
        let descriptor = Darwin.open(root.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in self?.refresh() }
        watcher.setCancelHandler { close(descriptor) }
        watcher.resume()
        projectWatcher = watcher
    }
}

final class RevisionStore {
    private let fileManager = FileManager.default
    private let root: URL

    init() {
        root = fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Context/revisions")
    }

    func history(for url: URL) -> [FileRevision] {
        let file = revisionFile(for: url)
        guard let data = try? Data(contentsOf: file), let revisions = try? JSONDecoder().decode([FileRevision].self, from: data) else { return [] }
        return revisions.sorted { $0.date > $1.date }
    }

    func capture(_ content: String, for url: URL) {
        guard !content.isEmpty else { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var revisions = history(for: url)
        revisions.insert(FileRevision(id: UUID(), date: .now, content: content), at: 0)
        revisions = Array(revisions.prefix(50))
        if let data = try? JSONEncoder().encode(revisions) { try? data.write(to: revisionFile(for: url), options: .atomic) }
    }

    private func revisionFile(for url: URL) -> URL {
        let safeName = url.path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return root.appending(path: safeName + ".json")
    }
}

struct SkillPackage: Identifiable, Hashable {
    let name: String
    let url: URL
    let scope: String
    var id: URL { url }
}

struct PluginPackage: Identifiable, Hashable {
    let name: String
    let url: URL
    let harness: String
    let scope: String
    var id: URL { url }
}

struct InstructionFile: Identifiable, Hashable {
    let url: URL
    let harness: Harness
    let scope: String
    var id: URL { url }

    var targets: [Harness] {
        switch harness {
        case .shared: [.codex, .cursor, .copilot]
        case .claude: [.claude, .cursor, .copilot]
        case .gemini: [.gemini, .copilot]
        default: [harness]
        }
    }
}

struct ContextAssessment {
    let estimatedTokens: Int
    let headingCount: Int
    let status: String
    let detail: String

    static func evaluate(_ content: String) -> ContextAssessment {
        let words = content.split(whereSeparator: { $0.isWhitespace }).count
        let tokens = max(1, words * 4 / 3)
        let headings = content.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }.count

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ContextAssessment(estimatedTokens: 0, headingCount: 0, status: "Empty", detail: "Add only the rules an agent needs.")
        }
        if tokens > 12_000 || headings > 40 {
            return ContextAssessment(estimatedTokens: tokens, headingCount: headings, status: "Too large", detail: "Split stable procedures into skills and keep this file as the routing layer.")
        }
        if tokens > 6_000 || headings > 24 {
            return ContextAssessment(estimatedTokens: tokens, headingCount: headings, status: "Review", detail: "This may crowd task context. Move detailed reference material into skills.")
        }
        return ContextAssessment(estimatedTokens: tokens, headingCount: headings, status: "Focused", detail: "Size is reasonable. Check the local review for conflicts or ambiguous rules.")
    }
}

enum Harness: String, Hashable {
    case shared = "Shared"
    case codex = "Codex"
    case claude = "Claude"
    case gemini = "Gemini"
    case cursor = "Cursor"
    case copilot = "Copilot"
    case cline = "Cline"
    case roo = "Roo Code"
    case windsurf = "Windsurf"
    case continueDev = "Continue"
}

func harnessForInstruction(_ url: URL, projectRoot: URL) -> Harness? {
    let name = url.lastPathComponent
    let relativePath = url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
    if name == "AGENTS.md" || name == "AGENTS.override.md" { return .shared }
    if name == "CLAUDE.md" || relativePath.contains(".claude/rules/") { return .claude }
    if name == "GEMINI.md" { return .gemini }
    if name == ".cursorrules" || relativePath.contains(".cursor/rules/") { return .cursor }
    if name == ".windsurfrules" { return .windsurf }
    if name == ".clinerules" || relativePath.contains(".clinerules/") { return .cline }
    if relativePath.contains(".roo/rules/") { return .roo }
    if name == "copilot-instructions.md" || relativePath.contains(".github/instructions/") { return .copilot }
    if relativePath.contains(".continue/rules/") { return .continueDev }
    return nil
}

struct ContextMenu: View {
    @ObservedObject var store: ContextStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Context").font(.title2.weight(.semibold))
                    Text(store.workingDirectoryPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(store.projectSource).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Choose project…", action: store.chooseProject)
            }
            .padding(16)

            Divider()
            switch store.menuScreen {
            case .overview:
                Overview(store: store, screen: $store.menuScreen)
            case .agents, .skills, .plugins:
                DetailList(
                    store: store,
                    screen: $store.menuScreen,
                    editInstruction: { store.editInMenu($0, returningTo: .agents) },
                    browsePackage: { store.browseInMenu($0) }
                )
            case .package:
                if let package = store.menuPackage {
                    MenuPackageBrowser(
                        package: package,
                        directory: $store.menuDirectory,
                        back: { store.menuScreen = package.kind.screen },
                        edit: { store.editInMenu($0, returningTo: .package) },
                        reveal: { store.reveal($0) }
                    )
                }
            case .editor:
                if let editingURL = store.menuEditingURL {
                    MenuFileEditor(
                        store: store,
                        file: editingURL,
                        back: { store.menuScreen = store.menuEditorReturnScreen },
                        reveal: { store.reveal(editingURL) }
                    )
                    .id(editingURL.path)
                }
            }

            Divider().padding(.top, 6)
            HStack {
                Button("Refresh", action: store.refresh)
                Spacer()
                Button("Open Context") { openWindow(id: "context-window") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(16)
        }
        .frame(width: 390)
    }

}

private enum MenuScreen { case overview, agents, skills, plugins, package, editor }

private struct MenuPackage {
    enum Kind { case skills, plugins
        var screen: MenuScreen { self == .skills ? .skills : .plugins }
    }
    let title: String
    let root: URL
    let kind: Kind
}

private struct Overview: View {
    @ObservedObject var store: ContextStore
    @Binding var screen: MenuScreen

    var body: some View {
        VStack(spacing: 9) {
            Button(action: store.chooseProject) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus").font(.title3).frame(width: 25).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.projectURL == nil ? "Choose a project" : "Switch project")
                            .font(.body.weight(.semibold))
                        Text("Use this when Context cannot identify your workspace")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("context.project.choose")
            ContextCategory(icon: "doc.text.fill", title: "Instructions", count: store.instructionFiles.count, detail: "AGENTS, Claude, Gemini + rules") {
                screen = .agents
            }
            ContextCategory(icon: "sparkles", title: "Skills", count: store.skills.count, detail: "Packages and attached files") {
                screen = .skills
            }
            ContextCategory(icon: "puzzlepiece.extension.fill", title: "Plugins", count: store.plugins.count, detail: "Codex and Claude integrations") {
                screen = .plugins
            }
            HStack {
                Image(systemName: store.effectiveCodexReport.sources.isEmpty ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(store.effectiveCodexReport.sources.isEmpty ? .orange : .green)
                Text(store.effectiveCodexReport.sources.isEmpty
                    ? "No Codex instructions apply here"
                    : "Codex stack ready · \(store.effectiveCodexReport.sources.count) \(store.effectiveCodexReport.sources.count == 1 ? "source" : "sources") · ~\(store.effectiveCodexReport.estimatedTokens) tokens")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 7)
        }
        .padding(16)
    }
}

private struct ContextCategory: View {
    let icon: String
    let title: String
    let count: Int
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 25).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(count) found").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("context.category.\(title.lowercased())")
    }
}

private struct DetailList: View {
    @ObservedObject var store: ContextStore
    @Binding var screen: MenuScreen
    let editInstruction: (URL) -> Void
    let browsePackage: (MenuPackage) -> Void

    private var title: String {
        switch screen {
        case .agents: "Instructions"
        case .skills: "Skills"
        case .plugins: "Plugins"
        case .overview, .package, .editor: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { screen = .overview } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Color.clear.frame(width: 42, height: 1)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch screen {
                    case .agents:
                        if store.instructionFiles.isEmpty { EmptyRow("No instruction files found for this project") }
                        else { ForEach(store.instructionFiles) { instruction in InstructionRow(instruction: instruction, edit: { editInstruction(instruction.url) }, reveal: { store.reveal(instruction.url) }) } }
                    case .skills:
                        if store.skills.isEmpty { EmptyRow("No project skill packages found") }
                        else { ForEach(store.skills) { skill in SkillRow(skill: skill, browse: { browsePackage(MenuPackage(title: skill.name, root: skill.url, kind: .skills)) }, reveal: { store.reveal(skill.url) }) } }
                    case .plugins:
                        if store.plugins.isEmpty { EmptyRow("No Codex or Claude plugin packages found") }
                        else { ForEach(store.plugins) { plugin in PluginRow(plugin: plugin, browse: { browsePackage(MenuPackage(title: plugin.name, root: plugin.url, kind: .plugins)) }, reveal: { store.reveal(plugin.url) }) } }
                    case .overview, .package, .editor:
                        EmptyView()
                    }
                }
            }
            .frame(height: 360)
        }
    }
}

private struct SkillRow: View {
    let skill: SkillPackage
    let browse: () -> Void
    let reveal: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Button(action: browse) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(skill.name)/").font(.system(.body, design: .monospaced).weight(.medium))
                    Text("\(skill.scope) · Browse in Context").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("context.skill.\(skill.name)")
            Button(action: reveal) { Image(systemName: "arrow.right") }
                .buttonStyle(.plain).help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private struct InstructionRow: View {
    let instruction: InstructionFile
    let edit: () -> Void
    let reveal: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(instruction.url.lastPathComponent).font(.system(.body, design: .monospaced).weight(.medium))
                    Text("\(instruction.harness.rawValue) · \(instruction.scope) · Edit in Context").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("context.instruction.\(instruction.url.lastPathComponent)")
            Button(action: reveal) { Image(systemName: "arrow.right") }
                .buttonStyle(.plain).help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private struct PluginRow: View {
    let plugin: PluginPackage
    let browse: () -> Void
    let reveal: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Button(action: browse) {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.name).font(.body.weight(.medium))
                    Text("\(plugin.harness) · \(plugin.scope) · Browse in Context").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("context.plugin.\(plugin.name)")
            Button(action: reveal) { Image(systemName: "arrow.right") }
                .buttonStyle(.plain).help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

private struct MenuPackageBrowser: View {
    let package: MenuPackage
    @Binding var directory: URL?
    let back: () -> Void
    let edit: (URL) -> Void
    let reveal: (URL) -> Void

    private var currentDirectory: URL { directory ?? package.root }
    private var entries: [URL] {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: currentDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        return items.sorted { lhs, rhs in
            let leftDirectory = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rightDirectory = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if leftDirectory != rightDirectory { return leftDirectory }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text(package.title).font(.headline).lineLimit(1)
                Spacer()
                Button(action: { reveal(package.root) }) { Image(systemName: "arrow.right") }
                    .buttonStyle(.plain).help("Reveal in Finder")
            }
            .padding(16)
            Text(currentDirectory.path.replacingOccurrences(of: package.root.path, with: package.title))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if currentDirectory != package.root {
                        Button { directory = currentDirectory.deletingLastPathComponent() } label: {
                            Label("..", systemImage: "arrow.turn.up.left")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                    }
                    if entries.isEmpty { EmptyRow("This folder is empty") }
                    ForEach(entries, id: \.self) { entry in
                        let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        HStack(spacing: 9) {
                            Button {
                                if isDirectory { directory = entry } else { edit(entry) }
                            } label: {
                                Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                                    .foregroundStyle(isDirectory ? Color.accentColor : Color.secondary)
                                Text(entry.lastPathComponent)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Image(systemName: isDirectory ? "chevron.right" : "pencil")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("context.package.entry.\(entry.lastPathComponent)")
                            Button(action: { reveal(entry) }) { Image(systemName: "arrow.right") }
                                .buttonStyle(.plain).help("Reveal in Finder")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
    }
}

private struct MenuFileEditor: View {
    @ObservedObject var store: ContextStore
    let file: URL
    let back: () -> Void
    let reveal: () -> Void

    private var editable: Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return !data.contains(0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Text(file.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button(action: reveal) { Image(systemName: "arrow.right") }
                    .buttonStyle(.plain).help("Reveal in Finder")
            }
            .padding(16)
            Divider()
            if editable {
                TextEditor(text: $store.menuEditorText)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(height: 270)
                    .accessibilityIdentifier("context.editor.text")
                Divider()
                HStack {
                    Text(store.menuEditorMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("History") {
                        if store.menuEditorRevisions.isEmpty { Text("No local snapshots yet") }
                        ForEach(store.menuEditorRevisions) { revision in
                            Button(revision.date.formatted(date: .abbreviated, time: .shortened)) {
                                store.menuEditorText = revision.content
                                store.menuEditorMessage = "Snapshot restored in the editor. Save to apply."
                            }
                        }
                    }
                    Button("Save", action: store.saveMenuEditor)
                        .keyboardShortcut("s")
                        .accessibilityIdentifier("context.editor.save")
                }
                .padding(16)
            } else {
                ContentUnavailableView("Binary or unreadable file", systemImage: "doc", description: Text("Reveal it in Finder if you need another app."))
                    .frame(height: 270)
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 5)
    }
}

private struct EmptyRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

private struct FileRow: View {
    let url: URL
    let action: () -> Void
    let reveal: () -> Void
    var body: some View {
        HStack(spacing: 9) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.system(.body, design: .monospaced).weight(.medium))
                    Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .buttonStyle(.plain)
            Button(action: reveal) { Image(systemName: "arrow.right") }
                .buttonStyle(.plain).help("Reveal in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
