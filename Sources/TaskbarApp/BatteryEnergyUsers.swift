import Foundation

/// An app (or loose process) and its Energy Impact, the same number Activity Monitor shows.
struct BatteryEnergyUser: Equatable {
    let name: String
    let impact: Double
    /// The app bundle to take an icon from, or the executable for loose processes.
    let appPath: String?
    let processCount: Int
}

/// Reads `top -l 2 -o power`. The first sample has no rates yet, so only the last block
/// counts. Helpers anywhere inside an app bundle are added to that app, so Chrome's
/// renderers show up as Chrome.
func batteryEnergyUsers(
    fromTopOutput output: String,
    ownPID: Int,
    limit: Int = 6,
    pathForPID: (Int) -> String?
) -> [BatteryEnergyUser] {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    guard let headerIndex = lines.lastIndex(where: { $0.hasPrefix("PID") && $0.contains("POWER") }) else {
        return []
    }

    var groups: [String: (name: String, impact: Double, path: String?, count: Int)] = [:]
    for line in lines[(headerIndex + 1)...] {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3,
              let pid = Int(fields[0]),
              let impact = Double(fields[fields.count - 1]),
              pid != ownPID,
              impact > 0
        else {
            continue
        }
        let command = fields[1..<(fields.count - 1)].joined(separator: " ")
        let path = pathForPID(pid)
        let bundle = path.flatMap(batteryOutermostAppBundle)
        let key = bundle ?? path ?? "pid:\(pid)"
        let name = bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? path.map { ($0 as NSString).lastPathComponent }
            ?? command

        var group = groups[key] ?? (name, 0, bundle ?? path, 0)
        group.impact += impact
        group.count += 1
        groups[key] = group
    }

    return groups.values
        .map {
            BatteryEnergyUser(
                name: $0.name,
                impact: ($0.impact * 10).rounded() / 10,
                appPath: $0.path,
                processCount: $0.count
            )
        }
        .sorted { $0.impact == $1.impact ? $0.name < $1.name : $0.impact > $1.impact }
        .prefix(limit)
        .map { $0 }
}

func batteryOutermostAppBundle(_ path: String) -> String? {
    guard path.hasPrefix("/"), let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
}

/// Samples energy use with `top` while the battery popover is open. One run takes about two
/// seconds (it needs two samples a second apart), so it never runs more than once at a time.
final class BatteryEnergySampler {
    static let shared = BatteryEnergySampler()

    private let queue = DispatchQueue(label: "com.mikerosoft.taskbar.battery-energy", qos: .utility)
    private let lock = NSLock()
    private var users: [BatteryEnergyUser] = []
    private var lastSample: Date?
    private var isSampling = false

    var latest: [BatteryEnergyUser] {
        lock.lock()
        defer { lock.unlock() }
        return users
    }

    func refreshIfNeeded(interval: TimeInterval = 4, onUpdate: @escaping () -> Void) {
        lock.lock()
        if isSampling || lastSample.map({ Date().timeIntervalSince($0) < interval }) == true {
            lock.unlock()
            return
        }
        isSampling = true
        lock.unlock()

        queue.async { [weak self] in
            let output = runStatsCommandOutput(
                "/usr/bin/top",
                arguments: ["-l", "2", "-s", "1", "-o", "power", "-n", "20", "-stats", "pid,command,power"],
                timeout: 8
            )
            let users = output.map {
                batteryEnergyUsers(fromTopOutput: $0, ownPID: -1, pathForPID: readStatsProcessPath)
                    .filter { $0.name != "top" }
            }
            guard let self else { return }
            self.lock.lock()
            if let users { self.users = users }
            self.lastSample = Date()
            self.isSampling = false
            self.lock.unlock()
            DispatchQueue.main.async(execute: onUpdate)
        }
    }
}
