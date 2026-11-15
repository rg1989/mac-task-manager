import Foundation

/// Facts about processes that the basic `ps` listing does not carry: full
/// command lines, terminals, listening ports, working folders and which pids
/// macOS runs as services. Collected by `ProcessContextSampler`; a plain
/// input to `LeftoverDetector`, so the rules can be checked without a Mac.
public struct ProcessContext: Equatable, Sendable {
    public var commandLines: [Int32: String]
    /// Terminal name per pid; `??` means no terminal.
    public var terminals: [Int32: String]
    public var listeningPorts: [Int32: [Int]]
    public var workingDirectories: [Int32: String]
    public var launchdManagedPIDs: Set<Int32>

    public init(
        commandLines: [Int32: String] = [:],
        terminals: [Int32: String] = [:],
        listeningPorts: [Int32: [Int]] = [:],
        workingDirectories: [Int32: String] = [:],
        launchdManagedPIDs: Set<Int32> = []
    ) {
        self.commandLines = commandLines
        self.terminals = terminals
        self.listeningPorts = listeningPorts
        self.workingDirectories = workingDirectories
        self.launchdManagedPIDs = launchdManagedPIDs
    }
}

/// A headless browser or a dev server, with the processes under it.
public struct LeftoverItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case headlessBrowser, devServer
    }

    public enum Ownership: Equatable, Sendable {
        /// Whatever started it has exited, it has no terminal, and macOS does
        /// not run it as a service. Nothing is using it.
        case leftover
        /// A running app or coding agent is above it in the process tree.
        case ownedBy(String)
        /// Attached to a terminal the user still has open.
        case terminal
        /// Started and kept alive by launchd (for example `brew services`).
        case service
    }

    public var id: Int32 { root.pid }
    public let kind: Kind
    public let title: String
    public let root: ProcessSnapshot
    /// The root and every process below it.
    public let members: [ProcessSnapshot]
    public let ports: [Int]
    public let workingDirectory: String?
    public let commandLine: String
    public let ownership: Ownership
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public var isLeftover: Bool { ownership == .leftover }

    public init(
        kind: Kind,
        title: String,
        root: ProcessSnapshot,
        members: [ProcessSnapshot],
        ports: [Int],
        workingDirectory: String?,
        commandLine: String,
        ownership: Ownership
    ) {
        self.kind = kind
        self.title = title
        self.root = root
        self.members = members
        self.ports = ports
        self.workingDirectory = workingDirectory
        self.commandLine = commandLine
        self.ownership = ownership
        self.cpuPercent = members.reduce(0) { $0 + $1.cpuPercent }
        self.memoryBytes = members.reduce(0) { $0 + $1.memoryBytes }
    }
}

/// Finds headless browsers and dev servers among the user's processes and
/// says who, if anyone, still owns each one. Coding agents and test tools
/// start these and do not always stop them.
public enum LeftoverDetector {
    static let browserDrivers: Set<String> = ["chromedriver", "geckodriver", "msedgedriver"]
    static let headlessShells: Set<String> = ["chrome-headless-shell", "headless_shell"]

    /// Programs that run other people's code: a listening port on one of
    /// these is a server someone started, not part of an installed app.
    static let runtimes: Set<String> = [
        "node", "nodejs", "bun", "deno", "python", "ruby", "php", "java", "go",
        "uvicorn", "gunicorn", "hypercorn", "flask", "vite", "next-server",
        "webpack", "esbuild", "tsx", "ts-node", "nodemon", "rails", "puma",
        "hugo", "jekyll", "http-server", "serve", "live-server", "air",
    ]

    /// Command-line words that name a server, with the title to show.
    static let serverTitles: [(word: String, title: String)] = [
        ("next-server", "Next.js server"), ("next", "Next.js dev server"),
        ("vite", "Vite dev server"), ("webpack-dev-server", "webpack dev server"),
        ("webpack", "webpack dev server"), ("nuxt", "Nuxt dev server"),
        ("astro", "Astro dev server"), ("remix", "Remix dev server"),
        ("uvicorn", "Uvicorn server"), ("gunicorn", "Gunicorn server"),
        ("hypercorn", "Hypercorn server"), ("flask", "Flask server"),
        ("streamlit", "Streamlit app"), ("jupyter-lab", "Jupyter"),
        ("jupyter", "Jupyter"), ("rails", "Rails server"), ("puma", "Puma server"),
        ("hugo", "Hugo server"), ("jekyll", "Jekyll server"),
        ("http-server", "http-server"), ("live-server", "live-server"),
    ]

    /// Coding agents, by a word in the process name or its command.
    static let agents: [(word: String, name: String)] = [
        ("claude", "Claude"), ("codex", "Codex"), ("cursor-agent", "Cursor"),
        ("opencode", "OpenCode"), ("gemini", "Gemini"), ("aider", "Aider"),
    ]

    public static func detect(_ processes: [ProcessSnapshot], context: ProcessContext) -> [LeftoverItem] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [Int32]] = [:]
        for process in processes {
            children[process.ppid, default: []].append(process.pid)
        }

        var kinds: [Int32: LeftoverItem.Kind] = [:]
        for process in processes where process.isOwnedByCurrentUser {
            let commandLine = context.commandLines[process.pid] ?? process.executablePath
            if isHeadlessBrowser(process, commandLine: commandLine) {
                kinds[process.pid] = .headlessBrowser
            } else if isDevServer(process, commandLine: commandLine, ports: context.listeningPorts[process.pid] ?? []) {
                kinds[process.pid] = .devServer
            }
        }

        var items: [LeftoverItem] = []
        for (pid, kind) in kinds {
            guard let root = byPID[pid] else { continue }
            let above = ancestors(of: root, byPID: byPID)
            // A candidate below another candidate belongs to that one's tree.
            if above.contains(where: { kinds[$0.pid] != nil }) { continue }
            let members = tree(from: pid, byPID: byPID, children: children)
            let commandLine = context.commandLines[pid] ?? root.executablePath
            let ports = Set(members.flatMap { context.listeningPorts[$0.pid] ?? [] }).sorted()
            items.append(LeftoverItem(
                kind: kind,
                title: title(for: root, kind: kind, commandLine: commandLine),
                root: root,
                members: members,
                ports: ports,
                workingDirectory: context.workingDirectories[pid],
                commandLine: commandLine,
                ownership: ownership(of: root, ancestors: above, context: context)
            ))
        }
        return items.sorted { a, b in
            if a.isLeftover != b.isLeftover { return a.isLeftover }
            if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            return a.root.pid < b.root.pid
        }
    }

    // MARK: Kinds

    static func executableName(_ process: ProcessSnapshot) -> String {
        (process.executablePath as NSString).lastPathComponent.lowercased()
    }

    static func isHeadlessBrowser(_ process: ProcessSnapshot, commandLine: String) -> Bool {
        // Renderer, GPU and utility helpers carry --type=; they hang under
        // the browser process and are counted with it.
        if commandLine.contains(" --type=") { return false }
        let name = executableName(process)
        if headlessShells.contains(name) || browserDrivers.contains(name) { return true }
        if commandLine.contains(" --headless") { return true }
        let path = process.executablePath
        return path.contains("/ms-playwright/") || path.contains("/.cache/puppeteer/")
    }

    static func isDevServer(_ process: ProcessSnapshot, commandLine: String, ports: [Int]) -> Bool {
        guard !ports.isEmpty, !isInsideInstalledApp(process.executablePath) else { return false }
        if runtimes.contains(runtimeName(process)) { return true }
        let words = commandWords(commandLine, executablePath: process.executablePath)
        return serverTitles.contains { words.contains($0.word) }
    }

    /// `python3.11` and `Python` are both `python`.
    static func runtimeName(_ process: ProcessSnapshot) -> String {
        let name = executableName(process)
        if name.hasPrefix("python"), name.dropFirst(6).allSatisfy({ $0.isNumber || $0 == "." }) {
            return "python"
        }
        return name
    }

    /// A helper that ships inside an installed app (an Electron app's Node,
    /// for example) is that app's business, not a dev server. Framework
    /// bundles outside the Applications folders, such as Python.app, are not.
    static func isInsideInstalledApp(_ path: String) -> Bool {
        guard ProcessListPolicy.appBundlePath(forExecutable: path) != nil else { return false }
        return path.hasPrefix("/Applications/") || path.hasPrefix("/System/") || path.contains("/Applications/")
    }

    /// Lowercased last path components of the arguments after the executable.
    static func commandWords(_ commandLine: String, executablePath: String) -> [String] {
        argumentText(commandLine, executablePath: executablePath)
            .split(separator: " ")
            .map { (String($0) as NSString).lastPathComponent.lowercased() }
    }

    /// The command line without the executable. The executable path can hold
    /// spaces, so it is removed as a prefix when it matches.
    static func argumentText(_ commandLine: String, executablePath: String) -> String {
        if commandLine.hasPrefix(executablePath) {
            return String(commandLine.dropFirst(executablePath.count)).trimmingCharacters(in: .whitespaces)
        }
        // Launched by bare name ("node server.js"): drop that first word. Any
        // other first word means the process retitled itself ("Raycast
        // Backend"), and what follows is not a list of arguments.
        guard let space = commandLine.firstIndex(of: " "),
              (String(commandLine[..<space]) as NSString).lastPathComponent.lowercased()
                == (executablePath as NSString).lastPathComponent.lowercased() else { return "" }
        return String(commandLine[commandLine.index(after: space)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Titles

    static func title(for root: ProcessSnapshot, kind: LeftoverItem.Kind, commandLine: String) -> String {
        switch kind {
        case .headlessBrowser: headlessTitle(root, commandLine: commandLine)
        case .devServer: serverTitle(root, commandLine: commandLine)
        }
    }

    static func headlessTitle(_ root: ProcessSnapshot, commandLine: String) -> String {
        let name = executableName(root)
        let path = root.executablePath.lowercased()
        if name == "chromedriver" { return "ChromeDriver" }
        if name == "geckodriver" { return "GeckoDriver" }
        if name == "msedgedriver" { return "EdgeDriver" }
        if path.contains("firefox") { return "Headless Firefox" }
        if path.contains("webkit") { return "Headless WebKit" }
        if path.contains("microsoft edge") || path.contains("msedge") { return "Headless Edge" }
        if path.contains("chromium") || path.contains("ms-playwright") || headlessShells.contains(name) {
            return "Headless Chromium"
        }
        return "Headless Chrome"
    }

    static func serverTitle(_ root: ProcessSnapshot, commandLine: String) -> String {
        let arguments = argumentText(commandLine, executablePath: root.executablePath)
        let words = commandWords(commandLine, executablePath: root.executablePath)
        if let match = serverTitles.first(where: { words.contains($0.word) }) { return match.title }
        if arguments.contains("http.server") { return "Python http.server" }
        if arguments.contains("manage.py") && arguments.contains("runserver") { return "Django server" }
        if let named = serverTitles.first(where: { $0.word == executableName(root) }) { return named.title }
        // "Python mock.py", "node server.js": the runtime and its script.
        let script = arguments.split(separator: " ").first { !$0.hasPrefix("-") }
        guard let script else { return root.name }
        return "\(root.name) \((String(script) as NSString).lastPathComponent)"
    }

    // MARK: Ownership

    static func ownership(
        of root: ProcessSnapshot,
        ancestors: [ProcessSnapshot],
        context: ProcessContext
    ) -> LeftoverItem.Ownership {
        if context.launchdManagedPIDs.contains(root.pid) { return .service }
        if hasTerminal(root.pid, context: context) { return .terminal }
        for ancestor in ancestors {
            if let agent = agentName(ancestor, commandLine: context.commandLines[ancestor.pid]) {
                return .ownedBy(agent)
            }
            if let bundle = ProcessListPolicy.appBundlePath(forExecutable: ancestor.executablePath),
               isInsideInstalledApp(ancestor.executablePath) {
                return .ownedBy(((bundle as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            if context.launchdManagedPIDs.contains(ancestor.pid) { return .service }
            if hasTerminal(ancestor.pid, context: context) { return .terminal }
        }
        // The chain ended at launchd: whatever started this is gone.
        return .leftover
    }

    static func hasTerminal(_ pid: Int32, context: ProcessContext) -> Bool {
        guard let terminal = context.terminals[pid] else { return false }
        return !terminal.isEmpty && terminal != "??"
    }

    static func agentName(_ process: ProcessSnapshot, commandLine: String?) -> String? {
        let name = process.name.lowercased()
        let executable = executableName(process)
        let firstWord = (commandLine ?? "").split(separator: " ").first.map {
            (String($0) as NSString).lastPathComponent.lowercased()
        } ?? ""
        return agents.first { agent in
            name == agent.word || executable == agent.word || firstWord == agent.word
                || name.hasPrefix(agent.word + " ") || executable.hasPrefix(agent.word + "-")
        }?.name
    }

    // MARK: Tree walking

    /// Parents from nearest to farthest, stopping at launchd.
    static func ancestors(of process: ProcessSnapshot, byPID: [Int32: ProcessSnapshot]) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var current = process
        while result.count < 32, current.ppid > 1, current.ppid != current.pid, let parent = byPID[current.ppid] {
            result.append(parent)
            current = parent
        }
        return result
    }

    static func tree(
        from pid: Int32,
        byPID: [Int32: ProcessSnapshot],
        children: [Int32: [Int32]]
    ) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var queue = [pid]
        var seen: Set<Int32> = []
        while let next = queue.first {
            queue.removeFirst()
            guard seen.insert(next).inserted, let process = byPID[next] else { continue }
            result.append(process)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }
}
