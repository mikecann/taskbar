import AppKit
import Darwin
import Foundation

/// One real process inside a Top Processes row.
struct StatsProcessMember: Equatable {
    var pid: Int
    /// Executable name, or "node · deploy" style label for interpreters.
    var name: String
    /// Working directory, which is what tells parallel builds apart.
    var folder: String?
    var startedBy: String?
    var cpuPercent: Double
    var memoryBytes: Double
    /// The part of cpuPercent from subprocesses that finished during the window.
    var finishedChildCPUPercent: Double = 0
}

/// Extra facts about a process that `ps` doesn't give us. Only readable for our own user's
/// processes, so every field is optional.
struct StatsProcessDetails: Equatable {
    var arguments: [String]?
    var folder: String?
    var responsiblePID: Int?
}

/// A breakdown line under an expanded row: members that share a folder, or for apps, a
/// helper type.
struct StatsProcessSubrow: Equatable {
    var key: String
    var label: String
    var folder: String?
    var pids: [Int]
    var value: Double
}

private let statsInterpreterNames: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "java", "perl", "php", "bash", "zsh", "sh"
]

func statsIsInterpreter(_ executableName: String) -> Bool {
    statsInterpreterNames.contains(executableName) || executableName.hasPrefix("python3.")
}

/// Turns "node .../deploy.mjs" into "node · deploy" so one row isn't 91 unrelated node
/// processes. Returns nil when there's nothing more useful than the bare executable name.
func statsInterpreterLabel(executableName: String, arguments: [String]) -> String? {
    let args = Array(arguments.dropFirst())
    let hint: String?
    switch executableName {
    case "java":
        hint = statsJavaHint(args)
    case "node", "bun", "deno":
        hint = statsScriptHint(
            args,
            flagsWithValues: ["-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions"],
            specialFlags: ["--test": "test", "-e": "eval", "--eval": "eval", "-p": "eval"]
        )
    case "bash", "zsh", "sh":
        // "zsh -c <long command>" has no script to name.
        hint = args.contains("-c") ? nil : statsScriptHint(args, flagsWithValues: [], specialFlags: [:])
    default:
        if executableName.hasPrefix("python"), let index = args.firstIndex(of: "-m"), index + 1 < args.count {
            hint = args[index + 1]
        } else {
            hint = statsScriptHint(args, flagsWithValues: ["-X", "-W", "-I"], specialFlags: ["-c": "inline"])
        }
    }
    guard let hint, !hint.isEmpty, hint != executableName else { return nil }
    return "\(executableName) · \(hint)"
}

private func statsJavaHint(_ args: [String]) -> String? {
    let joined = args.joined(separator: " ")
    if joined.contains("GradleDaemon") { return "Gradle daemon" }
    if joined.contains("GradleWrapperMain") { return "Gradle wrapper" }
    if joined.contains("KotlinCompileDaemon") { return "Kotlin daemon" }
    if let index = args.firstIndex(of: "-jar"), index + 1 < args.count {
        return URL(fileURLWithPath: args[index + 1]).deletingPathExtension().lastPathComponent
    }

    let flagsWithValues: Set<String> = [
        "-cp", "-classpath", "--class-path", "-p", "--module-path", "--add-opens", "--add-exports",
        "--add-modules", "--add-reads"
    ]
    var index = 0
    while index < args.count {
        let arg = args[index]
        if flagsWithValues.contains(arg) {
            index += 2
            continue
        }
        if arg.hasPrefix("-") {
            index += 1
            continue
        }
        return arg.split(separator: ".").last.map(String.init)
    }
    return nil
}

private func statsScriptHint(
    _ args: [String],
    flagsWithValues: Set<String>,
    specialFlags: [String: String]
) -> String? {
    var index = 0
    while index < args.count {
        let arg = args[index]
        if let special = specialFlags[arg] {
            return special
        }
        if flagsWithValues.contains(arg) {
            index += 2
            continue
        }
        if arg.hasPrefix("-") {
            index += 1
            continue
        }
        return statsScriptName(arg)
    }
    return nil
}

/// "…/node_modules/vite/bin/vite.js" → "vite", "…/runner/scripts/deploy.mjs" → "deploy",
/// "…/convex/dist/cli/index.js" → "convex".
func statsScriptName(_ path: String) -> String {
    let components = path.split(separator: "/").map(String.init)
    if let modulesIndex = components.lastIndex(of: "node_modules"), modulesIndex + 1 < components.count {
        let package = components[modulesIndex + 1]
        if package == ".bin", modulesIndex + 2 < components.count {
            return components[modulesIndex + 2]
        }
        if package.hasPrefix("@"), modulesIndex + 2 < components.count {
            return components[modulesIndex + 2]
        }
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return statsGenericScriptNames.contains(base) ? package : base
    }

    let url = URL(fileURLWithPath: path)
    let base = url.deletingPathExtension().lastPathComponent
    guard statsGenericScriptNames.contains(base) else { return base }
    let parents = url.deletingLastPathComponent().pathComponents.reversed()
    return parents.first { !statsGenericFolderNames.contains($0) && $0 != "/" } ?? base
}

private let statsGenericScriptNames: Set<String> = [
    "index", "cli", "main", "run", "bin", "start", "server", "entry", "launch", "npm-cli", "npx-cli"
]

private let statsGenericFolderNames: Set<String> = [
    "app", "src", "web", "ios", "android", "packages", "server", "client", "frontend", "backend",
    "build", "dist", "scripts", "test", "tests", "lib", "bin", ".build", "cli", "out"
]

/// A short, recognisable name for a working directory: the last folder, plus its parent when
/// the last one is something generic like "app" or "src". Nil for "/", where daemons sit.
func statsFolderLabel(_ path: String, home: String = NSHomeDirectory()) -> String? {
    guard path != "/", !path.isEmpty else { return nil }
    if path == home { return "~" }
    let components = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
    guard let last = components.last else { return nil }
    if statsGenericFolderNames.contains(last), components.count >= 2 {
        return "\(components[components.count - 2])/\(last)"
    }
    return last
}

/// Keeps rows where they were while the pointer is over the list, so a row doesn't jump
/// out from under the click. New rows go at the end, finished ones drop out.
func statsStableOrder(current: [String], frozen: [String]?) -> [String] {
    guard let frozen else { return current }
    let present = Set(current)
    let kept = frozen.filter { present.contains($0) }
    let keptSet = Set(kept)
    return kept + current.filter { !keptSet.contains($0) }
}

/// Splits a row into folders (parallel builds in different worktrees) or, when the members
/// have no folder of their own, into executable names (Chrome's helper types).
func statsProcessSubrows(
    _ members: [StatsProcessMember],
    value: (StatsProcessMember) -> Double,
    home: String = NSHomeDirectory()
) -> [StatsProcessSubrow] {
    var rows: [String: StatsProcessSubrow] = [:]
    var order: [String] = []
    for member in members {
        let folderLabel = member.folder.flatMap { statsFolderLabel($0, home: home) }
        let key = folderLabel.map { "folder:\(member.folder ?? $0)" } ?? "name:\(member.name)"
        if rows[key] == nil {
            rows[key] = StatsProcessSubrow(
                key: key,
                label: folderLabel ?? member.name,
                folder: folderLabel == nil ? nil : member.folder,
                pids: [],
                value: 0
            )
            order.append(key)
        }
        rows[key]?.pids.append(member.pid)
        rows[key]?.value += value(member)
    }
    return order.compactMap { rows[$0] }.sorted {
        $0.value == $1.value ? $0.label < $1.label : $0.value > $1.value
    }
}

private typealias StatsResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

/// Activity Monitor uses this private libSystem call to find which app a helper or child
/// process belongs to. Looked up at runtime so a future macOS without it just loses the
/// "Started by" line.
private let statsResponsiblePIDFunction: StatsResponsiblePIDFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: StatsResponsiblePIDFunction.self)
}()

func readStatsProcessDetails(pid: Int, executableName: String) -> StatsProcessDetails? {
    var details = StatsProcessDetails()

    var vnode = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    if proc_pidinfo(pid_t(pid), PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size {
        let path = withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        details.folder = path.isEmpty ? nil : path
    }

    if let responsible = statsResponsiblePIDFunction?(pid_t(pid)), responsible > 0, Int(responsible) != pid {
        details.responsiblePID = Int(responsible)
    }

    if statsIsInterpreter(executableName) {
        details.arguments = readStatsProcessArguments(pid: pid)
    }

    return details == StatsProcessDetails() ? nil : details
}

/// Reads argv through KERN_PROCARGS2: argc, the executable path, padding, then argv.
func readStatsProcessArguments(pid: Int) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseStatsProcArgs(Array(buffer.prefix(size)))
}

func parseStatsProcArgs(_ buffer: [UInt8]) -> [String]? {
    guard buffer.count > MemoryLayout<Int32>.size else { return nil }
    let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = MemoryLayout<Int32>.size
    while index < buffer.count, buffer[index] != 0 { index += 1 }
    while index < buffer.count, buffer[index] == 0 { index += 1 }

    var arguments: [String] = []
    var start = index
    while index < buffer.count, arguments.count < argc {
        if buffer[index] == 0 {
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            start = index + 1
        }
        index += 1
    }
    return arguments.isEmpty ? nil : arguments
}

/// Quits the given processes: running apps get a normal quit (so they can save), everything
/// else gets SIGTERM. Force uses forceTerminate / SIGKILL. Returns false if any refused.
@discardableResult
func quitStatsProcesses(_ pids: [Int], force: Bool) -> Bool {
    let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
    var allSucceeded = true
    for pid in pids where pid > 1 && pid != ownPID {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            allSucceeded = (force ? app.forceTerminate() : app.terminate()) && allSucceeded
        } else {
            allSucceeded = kill(pid_t(pid), force ? SIGKILL : SIGTERM) == 0 && allSucceeded
        }
    }
    return allSucceeded
}

enum StatsProcessTableItem: Equatable {
    case group(key: String, rect: NSRect)
    case detail(key: String, rect: NSRect)
    case subrow(key: String, subrowKey: String, rect: NSRect)
    case more(key: String, hidden: Int, rect: NSRect)

    var rect: NSRect {
        switch self {
        case let .group(_, rect), let .detail(_, rect), let .subrow(_, _, rect), let .more(_, _, rect):
            return rect
        }
    }
}

enum StatsProcessTableMetrics {
    static let groupHeight: CGFloat = 26
    static let detailHeight: CGFloat = 24
    static let subrowHeight: CGFloat = 22
    static let maxSubrows = 4
}

/// Where each row of the Top Processes table goes, with the expanded row's details and
/// folder breakdown under it. Rows that don't fit above `bottom` are left out.
func statsProcessTableLayout(
    rowKeys: [String],
    expandedKey: String?,
    subrowKeys: [String],
    top: CGFloat,
    bottom: CGFloat,
    x: CGFloat,
    width: CGFloat
) -> [StatsProcessTableItem] {
    typealias M = StatsProcessTableMetrics
    var items: [StatsProcessTableItem] = []
    var y = top
    func fits(_ height: CGFloat) -> Bool { y + height <= bottom }

    for key in rowKeys {
        guard fits(M.groupHeight) else { break }
        items.append(.group(key: key, rect: NSRect(x: x, y: y, width: width, height: M.groupHeight)))
        y += M.groupHeight
        guard key == expandedKey else { continue }

        if fits(M.detailHeight) {
            items.append(.detail(key: key, rect: NSRect(x: x, y: y, width: width, height: M.detailHeight)))
            y += M.detailHeight
        }
        let shown = subrowKeys.count > M.maxSubrows ? M.maxSubrows - 1 : subrowKeys.count
        for subrowKey in subrowKeys.prefix(shown) {
            guard fits(M.subrowHeight) else { break }
            items.append(.subrow(key: key, subrowKey: subrowKey, rect: NSRect(x: x, y: y, width: width, height: M.subrowHeight)))
            y += M.subrowHeight
        }
        if subrowKeys.count > shown, fits(M.subrowHeight) {
            items.append(.more(key: key, hidden: subrowKeys.count - shown, rect: NSRect(x: x, y: y, width: width, height: M.subrowHeight)))
            y += M.subrowHeight
        }
        y += 6
    }
    return items
}
