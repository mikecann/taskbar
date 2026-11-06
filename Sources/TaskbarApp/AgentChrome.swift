import Darwin
import Foundation

// BrowserBear's agent Chrome is a second copy of Google Chrome, started with
// its own profile folder, whose pages show in Threadbear's Browser panel. Its
// windows are parked at the edge of the screen (Chrome draws nothing when
// they're hidden or minimised), so they still showed here as a blank Chrome
// button next to Mike's own windows, which made it hard to tell which Chrome
// to click (6 Nov 2026). They're the agent's, so the taskbar leaves them out.

/// True for the command line of BrowserBear's agent Chrome.
func isAgentChromeArguments(_ arguments: [String]) -> Bool {
    arguments.contains { argument in
        argument.hasPrefix("--user-data-dir=") && argument.contains("/BrowserBear/agent/")
    }
}

/// The command line of a process run by the same user, or nil.
func processArguments(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    // argc, then the executable's path, padding, then argc NUL-ended strings.
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while index < size, arguments.count < argc {
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
    }
    return arguments
}

/// Remembers which processes are the agent Chrome, so each is looked up once.
final class AgentChromeProcesses {
    static let shared = AgentChromeProcesses()
    private var known: [pid_t: Bool] = [:]
    private let lock = NSLock()

    func contains(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let answer = known[pid] { return answer }
        let answer = processArguments(pid: pid).map(isAgentChromeArguments) ?? false
        // A pid can be reused once its process exits; keep the table small.
        if known.count > 512 { known.removeAll() }
        known[pid] = answer
        return answer
    }
}
