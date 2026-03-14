import SwiftUI
import AppKit
import Combine
import Darwin

// MARK: - Constants

private let kIgnoredDirs: Set<String> = [
    ".git", "node_modules", "__pycache__", ".venv", "venv", "env",
    ".next", ".nuxt", "dist", "build", ".cache", ".turbo",
    ".svn", ".hg", "vendor", ".idea", ".vscode", "target",
    "coverage", ".pytest_cache", ".mypy_cache",
    "bower_components", ".terraform", ".angular",
]

private let kIgnoredFiles: Set<String> = [
    ".DS_Store", "Thumbs.db", ".env", ".env.local",
]

private let kBinaryExts: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "ico", "svg", "webp",
    "woff", "woff2", "ttf", "eot", "otf",
    "pdf", "zip", "tar", "gz", "bz2", "7z", "rar",
    "exe", "dll", "so", "dylib", "o", "a",
    "mp3", "mp4", "avi", "mov", "wav", "flac",
    "sqlite", "db", "lock",
]

private let kAllowedDotfiles: Set<String> = [
    ".gitignore", ".env.example", ".eslintrc", ".eslintrc.js",
    ".eslintrc.json", ".prettierrc", ".prettierrc.js",
    ".prettierrc.json", ".editorconfig", ".dockerignore",
    ".npmrc", ".nvmrc", ".eslintrc.cjs", ".prettierrc.cjs",
]

private let kMaxFileSize = 512 * 1024

private let kLangMap: [String: String] = [
    "py": "python", "js": "javascript", "ts": "typescript",
    "tsx": "tsx", "jsx": "jsx", "go": "go", "rs": "rust",
    "rb": "ruby", "java": "java", "kt": "kotlin",
    "swift": "swift", "c": "c", "cpp": "cpp", "h": "c",
    "cs": "csharp", "php": "php", "sh": "bash", "zsh": "bash",
    "sql": "sql", "html": "html", "css": "css", "scss": "scss",
    "less": "less", "json": "json", "yaml": "yaml", "yml": "yaml",
    "toml": "toml", "xml": "xml", "md": "markdown",
    "vue": "vue", "svelte": "svelte", "graphql": "graphql",
    "proto": "protobuf", "tf": "hcl", "lua": "lua",
]

// MARK: - File Node

final class FileNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let fileSize: Int // bytes, 0 for directories
    var children: [FileNode]
    weak var parent: FileNode?

    init(name: String, path: String, isDirectory: Bool, fileSize: Int = 0, children: [FileNode] = []) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.children = children
        for child in children { child.parent = self }
    }
}

// MARK: - Check State

enum CheckState {
    case unchecked, checked, partial
}

// MARK: - App State

final class AppState: ObservableObject {
    @Published var rootNode: FileNode?
    @Published var projectPath: String = ""
    @Published var instructions: String = ""
    var checkStates: [String: CheckState] = [:]
    // Full prompt — not @Published, only used for clipboard
    var fullPrompt: String = ""
    @Published var tokenCount: Int = 0
    @Published var selectedFileCount: Int = 0
    @Published var copied: Bool = false
    @Published var isBuilding: Bool = false
    @Published var excludePatterns: String = "*.css, *.md, *.test.ts, *.test.tsx"
    @Published var excludedCount: Int = 0

    private var gitignorePatterns: [String] = []
    private var instructionsSub: AnyCancellable?

    init() {
        // Debounced token recount on instructions change
        instructionsSub = $instructions
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.estimateTokenCount() }
    }

    // MARK: Open Folder

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select Project Folder"
        if panel.runModal() == .OK, let url = panel.url {
            loadProject(path: url.path)
        }
    }

    func loadProject(path: String) {
        projectPath = path
        gitignorePatterns = Self.parseGitignore(root: path)
        checkStates.removeAll()
        rootNode = buildTree(at: path, name: URL(fileURLWithPath: path).lastPathComponent)
        fullPrompt = ""
        tokenCount = 0
        selectedFileCount = 0
    }

    // MARK: Gitignore

    private static func parseGitignore(root: String) -> [String] {
        let gi = (root as NSString).appendingPathComponent(".gitignore")
        guard let content = try? String(contentsOfFile: gi, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func shouldIgnore(name: String, relPath: String, isDir: Bool) -> Bool {
        if isDir && kIgnoredDirs.contains(name) { return true }
        if kIgnoredFiles.contains(name) { return true }
        if name.hasPrefix(".") && !kAllowedDotfiles.contains(name) { return true }
        if !isDir {
            let ext = (name as NSString).pathExtension.lowercased()
            if kBinaryExts.contains(ext) { return true }
        }
        for pattern in gitignorePatterns {
            let clean = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if fnmatch(clean, name, 0) == 0 { return true }
            if fnmatch(clean, relPath, 0) == 0 { return true }
        }
        return false
    }

    // MARK: Tree Building

    private func buildTree(at path: String, name: String) -> FileNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)

        let size: Int
        if !isDir.boolValue, let attrs = try? fm.attributesOfItem(atPath: path), let s = attrs[.size] as? Int {
            size = min(s, kMaxFileSize)
        } else {
            size = 0
        }
        let node = FileNode(name: name, path: path, isDirectory: isDir.boolValue, fileSize: size)
        checkStates[path] = .unchecked

        guard isDir.boolValue else { return node }
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return node }

        let sorted = entries.sorted { a, b in
            let ap = (path as NSString).appendingPathComponent(a)
            let bp = (path as NSString).appendingPathComponent(b)
            var ad: ObjCBool = false, bd: ObjCBool = false
            fm.fileExists(atPath: ap, isDirectory: &ad)
            fm.fileExists(atPath: bp, isDirectory: &bd)
            if ad.boolValue != bd.boolValue { return ad.boolValue }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }

        var children: [FileNode] = []
        for entry in sorted {
            let childPath = (path as NSString).appendingPathComponent(entry)
            var childIsDir: ObjCBool = false
            fm.fileExists(atPath: childPath, isDirectory: &childIsDir)
            let relPath: String
            if childPath.count > projectPath.count + 1 {
                relPath = String(childPath.dropFirst(projectPath.count + 1))
            } else {
                relPath = entry
            }
            if shouldIgnore(name: entry, relPath: relPath, isDir: childIsDir.boolValue) { continue }
            let child = buildTree(at: childPath, name: entry)
            child.parent = node
            children.append(child)
        }
        node.children = children
        return node
    }

    // MARK: Check Toggling

    func toggle(_ node: FileNode) {
        let current = checkStates[node.path] ?? .unchecked
        let newState: CheckState = (current == .checked) ? .unchecked : .checked
        setCheckedRecursive(node, state: newState)
        updateParentsUp(from: node)
        updateFileCount()
        estimateTokenCount()
        objectWillChange.send()
    }

    private func setCheckedRecursive(_ node: FileNode, state: CheckState) {
        checkStates[node.path] = state
        for child in node.children {
            setCheckedRecursive(child, state: state)
        }
    }

    private func updateParentsUp(from node: FileNode) {
        guard let parent = node.parent else { return }
        let childStates = parent.children.map { checkStates[$0.path] ?? .unchecked }
        let allChecked = childStates.allSatisfy { $0 == .checked }
        let allUnchecked = childStates.allSatisfy { $0 == .unchecked }
        if allChecked {
            checkStates[parent.path] = .checked
        } else if allUnchecked {
            checkStates[parent.path] = .unchecked
        } else {
            checkStates[parent.path] = .partial
        }
        updateParentsUp(from: parent)
    }

    private func updateFileCount() {
        guard let root = rootNode else { selectedFileCount = 0; return }
        selectedFileCount = countSelectedFiles(root)
    }

    private func countSelectedFiles(_ node: FileNode) -> Int {
        if !node.isDirectory { return (checkStates[node.path] == .checked) ? 1 : 0 }
        return node.children.reduce(0) { $0 + countSelectedFiles($1) }
    }

    // MARK: Token Estimation (fast, no file reads)

    func estimateTokenCount() {
        guard let root = rootNode else { tokenCount = 0; return }

        // Sum file sizes of selected files
        let totalBytes = sumSelectedBytes(root)

        // Overhead: file_map tree (~50 bytes per node), file headers (~80 per file),
        // instructions, XML tags
        let overhead = selectedFileCount * 80 + 200 + instructions.count
        let totalChars = totalBytes + overhead

        tokenCount = max(0, totalChars / 4)
    }

    private func sumSelectedBytes(_ node: FileNode) -> Int {
        if !node.isDirectory {
            return (checkStates[node.path] == .checked) ? node.fileSize : 0
        }
        return node.children.reduce(0) { $0 + sumSelectedBytes($1) }
    }

    func selectAll() {
        guard let root = rootNode else { return }
        setCheckedRecursive(root, state: .checked)
        updateFileCount()
        estimateTokenCount()
        objectWillChange.send()
    }

    func deselectAll() {
        guard let root = rootNode else { return }
        setCheckedRecursive(root, state: .unchecked)
        updateFileCount()
        estimateTokenCount()
        objectWillChange.send()
    }

    // MARK: Exclude by patterns

    func applyExcludes() {
        guard let root = rootNode else { return }
        let patterns = excludePatterns
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return }

        var count = 0
        uncheckMatching(node: root, patterns: patterns, count: &count)
        excludedCount = count

        // Recalculate all parent states bottom-up
        recalcAllParents(node: root)
        updateFileCount()
        estimateTokenCount()
        objectWillChange.send()
    }

    private func uncheckMatching(node: FileNode, patterns: [String], count: inout Int) {
        if !node.isDirectory {
            if checkStates[node.path] == .checked {
                let name = node.name
                for pattern in patterns {
                    if fnmatch(pattern, name, 0) == 0 {
                        checkStates[node.path] = .unchecked
                        count += 1
                        break
                    }
                }
            }
        } else {
            for child in node.children {
                uncheckMatching(node: child, patterns: patterns, count: &count)
            }
        }
    }

    private func recalcAllParents(node: FileNode) {
        // Post-order: recalc children first, then self
        for child in node.children {
            recalcAllParents(node: child)
        }
        if node.isDirectory && !node.children.isEmpty {
            let childStates = node.children.map { checkStates[$0.path] ?? .unchecked }
            let allChecked = childStates.allSatisfy { $0 == .checked }
            let allUnchecked = childStates.allSatisfy { $0 == .unchecked }
            if allChecked {
                checkStates[node.path] = .checked
            } else if allUnchecked {
                checkStates[node.path] = .unchecked
            } else {
                checkStates[node.path] = .partial
            }
        }
    }

    // MARK: Prompt Building (background thread)

    func buildAndCopy() {
        guard let root = rootNode else { return }
        isBuilding = true

        let selectedFilePaths = collectSelectedFilePaths(root)
        let instr = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootSnapshot = root

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selectedSet = Set(selectedFilePaths)
            var buf = ""
            buf.reserveCapacity(selectedFilePaths.count * 2048)

            // File map
            buf.append("<file_map>\n")
            Self.renderTreeInto(buf: &buf, node: rootSnapshot, prefix: "", isLast: true, isRoot: true, selected: selectedSet)
            buf.append("\n\n(* denotes selected files)\n</file_map>")

            // File contents
            if !selectedFilePaths.isEmpty {
                buf.append("\n\n<file_contents>\n")
                for (i, path) in selectedFilePaths.enumerated() {
                    if i > 0 { buf.append("\n\n") }
                    let content = Self.readFileSafe(path)
                    let lang = Self.detectLang(path)
                    buf.append("File: \(path)\n```\(lang)\n\(content)\n```")
                }
                buf.append("\n</file_contents>")
            }

            if !instr.isEmpty {
                buf.append("\n\n<user_instructions>\n\(instr)\n</user_instructions>")
            }

            let tokens = max(1, buf.count / 4)
            let fileCount = selectedFilePaths.count

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fullPrompt = buf
                self.tokenCount = tokens
                self.selectedFileCount = fileCount
                self.isBuilding = false

                // Auto-copy to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(buf, forType: .string)
                self.copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.copied = false
                }
            }
        }
    }

    private func collectSelectedFilePaths(_ node: FileNode) -> [String] {
        if !node.isDirectory { return (checkStates[node.path] == .checked) ? [node.path] : [] }
        return node.children.flatMap { collectSelectedFilePaths($0) }
    }

    private static func renderTreeInto(buf: inout String, node: FileNode, prefix: String, isLast: Bool, isRoot: Bool, selected: Set<String>) {
        if isRoot {
            buf.append(node.path)
        } else {
            buf.append("\n\(prefix)")
            buf.append(isLast ? "└── " : "├── ")
            buf.append(node.name)
            if selected.contains(node.path) { buf.append(" *") }
        }
        if node.isDirectory {
            let childPrefix = isRoot ? "" : (prefix + (isLast ? "    " : "│   "))
            for (i, child) in node.children.enumerated() {
                renderTreeInto(buf: &buf, node: child, prefix: childPrefix, isLast: i == node.children.count - 1, isRoot: false, selected: selected)
            }
        }
    }

    private static func readFileSafe(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return "[Error reading file]" }
        if size > kMaxFileSize { return "[File too large: \(size) bytes]" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? "[Binary or unreadable file]"
    }

    private static func detectLang(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" { return "dockerfile" }
        if name == "makefile" { return "makefile" }
        return kLangMap[(path as NSString).pathExtension.lowercased()] ?? ""
    }

    func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Views

struct FileTreeRow: View {
    let node: FileNode
    @ObservedObject var state: AppState
    @State private var isExpanded: Bool = false

    private var checkState: CheckState { state.checkStates[node.path] ?? .unchecked }

    private var checkIcon: String {
        switch checkState {
        case .unchecked: return "square"
        case .checked:   return "checkmark.square.fill"
        case .partial:   return "minus.square.fill"
        }
    }

    private var checkColor: Color {
        switch checkState {
        case .unchecked: return .secondary
        case .checked:   return .accentColor
        case .partial:   return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } }
                } else {
                    Spacer().frame(width: 14)
                }

                Image(systemName: checkIcon)
                    .foregroundColor(checkColor)
                    .font(.system(size: 14))
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggle(node) }

                Image(systemName: node.isDirectory ? "folder.fill" : "doc.text")
                    .foregroundColor(node.isDirectory ? .blue : .secondary)
                    .font(.system(size: 12))

                Text(node.name)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(checkState == .checked ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { state.toggle(node) }

            if node.isDirectory && isExpanded {
                ForEach(node.children) { child in
                    FileTreeRow(node: child, state: state)
                        .padding(.leading, 18)
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button("Open Folder…") { state.openFolder() }
                    .keyboardShortcut("o")
                if !state.projectPath.isEmpty {
                    Text(state.projectPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Main: tree left, instructions right
            HSplitView {
                // File tree
                Group {
                    if let root = state.rootNode {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                FileTreeRow(node: root, state: state)
                            }
                            .padding(8)
                        }
                    } else {
                        VStack {
                            Spacer()
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("Open a project folder")
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(minWidth: 280, idealWidth: 400)

                // Instructions
                VStack(alignment: .leading, spacing: 0) {
                    Text("Instructions:")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)

                    TextEditor(text: $state.instructions)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                }
                .frame(minWidth: 300)
            }

            Divider()

            // Exclude patterns bar
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(.secondary)
                    .font(.system(size: 13))

                Text("Exclude:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("*.css, *.md, *.test.ts", text: $state.excludePatterns)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.applyExcludes() }

                Button("Apply") { state.applyExcludes() }
                    .font(.system(size: 12))
                    .disabled(state.selectedFileCount == 0)

                if state.excludedCount > 0 {
                    Text("−\(state.excludedCount) files")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Bottom bar
            HStack(spacing: 12) {
                if state.isBuilding {
                    ProgressView()
                        .controlSize(.small)
                    Text("Building & copying…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else if state.copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Copied to clipboard!")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text("~\(state.formatTokens(state.tokenCount)) tokens")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("~\(state.formatTokens(state.tokenCount)) tokens")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                }

                Text("·").foregroundColor(.secondary)

                Text("\(state.selectedFileCount) files")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                Button("Deselect All") { state.deselectAll() }
                Button("Select All") { state.selectAll() }

                Button(action: { state.buildAndCopy() }) {
                    Label("Copy Prompt", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
                .disabled(state.isBuilding || state.selectedFileCount == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            if CommandLine.arguments.count > 1 {
                let path = CommandLine.arguments[1]
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    state.loadProject(path: path)
                }
            }
        }
    }
}

@main
struct PromptBuilderApplication: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1000, height: 700)
    }
}
