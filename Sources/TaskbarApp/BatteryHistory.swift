import Foundation

struct BatteryHistorySample: Codable, Equatable {
    let date: Date
    let percentage: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    /// Nil for points imported from the power management log, which only has the level.
    let systemLoadWatts: Double?
    let batteryPowerWatts: Double?

    private enum CodingKeys: String, CodingKey {
        case date = "t"
        case percentage = "p"
        case isCharging = "c"
        case isPluggedIn = "ac"
        case systemLoadWatts = "load"
        case batteryPowerWatts = "batt"
    }
}

enum BatteryChartRange: CaseIterable, Equatable {
    case twelveHours
    case twoDays
    case week

    var label: String {
        switch self {
        case .twelveHours: return "12h"
        case .twoDays: return "48h"
        case .week: return "7d"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .twelveHours: return 12 * 3600
        case .twoDays: return 48 * 3600
        case .week: return 7 * 24 * 3600
        }
    }
}

/// A week of battery readings, one a minute, so the popover has graphs the moment it opens.
struct BatteryHistory: Codable, Equatable {
    static let retention: TimeInterval = 7 * 24 * 3600
    static let minimumSpacing: TimeInterval = 55

    private(set) var samples: [BatteryHistorySample] = []

    mutating func append(_ sample: BatteryHistorySample) {
        if let last = samples.last, sample.date.timeIntervalSince(last.date) < Self.minimumSpacing {
            return
        }
        samples.append(sample)
        prune(now: sample.date)
    }

    /// Older points from somewhere else (the power management log), kept only where they
    /// come before anything we recorded ourselves.
    mutating func prepend(_ older: [BatteryHistorySample], now: Date) {
        let cutoff = samples.first?.date ?? .distantFuture
        samples = older.filter { $0.date < cutoff }.sorted { $0.date < $1.date } + samples
        prune(now: now)
    }

    private mutating func prune(now: Date) {
        let oldest = now.addingTimeInterval(-Self.retention)
        if let index = samples.firstIndex(where: { $0.date >= oldest }), index > 0 {
            samples.removeFirst(index)
        } else if samples.last.map({ $0.date < oldest }) == true {
            samples.removeAll()
        }
    }

    static func load(from url: URL) -> BatteryHistory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BatteryHistory.self, from: data)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Breaks the history wherever the Mac was asleep or the taskbar wasn't running, so the
/// charts don't draw a straight line across the gap.
func batteryHistoryRuns(_ samples: [BatteryHistorySample], maximumGap: TimeInterval) -> [[BatteryHistorySample]] {
    var runs: [[BatteryHistorySample]] = []
    for sample in samples {
        if let last = runs.last?.last, sample.date.timeIntervalSince(last.date) <= maximumGap {
            runs[runs.count - 1].append(sample)
        } else {
            runs.append([sample])
        }
    }
    return runs
}

/// `pmset -g log` notes the charge level at every sleep, wake and plug-in. It's sparse, but
/// it means the first popover after installing already shows the last few days.
func parsePMSetLogBatteryHistory(_ log: String) -> [BatteryHistorySample] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    var samples: [BatteryHistorySample] = []
    for line in log.split(separator: "\n") {
        guard line.count > 25,
              let date = formatter.date(from: String(line.prefix(25))),
              let using = line.range(of: "Using ", options: .backwards)
        else {
            continue
        }
        let rest = line[using.upperBound...]
        let pluggedIn: Bool
        if rest.hasPrefix("AC") {
            pluggedIn = true
        } else if rest.hasPrefix("Batt") {
            pluggedIn = false
        } else {
            continue
        }
        guard let charge = rest.range(of: "Charge:") else { continue }
        let digits = rest[charge.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        guard let percentage = Int(digits), (0...100).contains(percentage) else { continue }
        samples.append(BatteryHistorySample(
            date: date,
            percentage: percentage,
            isCharging: false,
            isPluggedIn: pluggedIn,
            systemLoadWatts: nil,
            batteryPowerWatts: nil
        ))
    }
    return samples
}

/// Records a sample a minute in the background and keeps the file up to date.
final class BatteryHistoryRecorder {
    static let shared = BatteryHistoryRecorder()

    private let queue = DispatchQueue(label: "com.mikerosoft.taskbar.battery-history", qos: .utility)
    private let lock = NSLock()
    private var history = BatteryHistory()
    private var timer: DispatchSourceTimer?
    private var unsavedCount = 0
    private let fileURL: URL

    init(fileURL: URL = BatteryHistoryRecorder.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mikerosoft Taskbar", isDirectory: true)
            .appendingPathComponent("battery-history.json")
    }

    var samples: [BatteryHistorySample] {
        lock.lock()
        defer { lock.unlock() }
        return history.samples
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.recordNow() }
        self.timer = timer
        queue.async { [weak self] in
            self?.loadOrImport()
            timer.resume()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { saveIfNeeded(force: true) }
    }

    /// The popover calls this as it opens so the newest point is never a minute stale.
    func record(_ details: BatteryDetails, at date: Date = Date()) {
        lock.lock()
        history.append(BatteryHistorySample(details: details, date: date))
        lock.unlock()
    }

    private func recordNow() {
        guard let details = currentBatteryDetails() else { return }
        record(details)
        unsavedCount += 1
        saveIfNeeded(force: false)
    }

    private func saveIfNeeded(force: Bool) {
        guard force ? unsavedCount > 0 : unsavedCount >= 5 else { return }
        lock.lock()
        let snapshot = history
        lock.unlock()
        do {
            try snapshot.save(to: fileURL)
            unsavedCount = 0
        } catch {
            log("battery history save failed: \(error.localizedDescription)")
        }
    }

    private func loadOrImport() {
        if let saved = BatteryHistory.load(from: fileURL) {
            lock.lock()
            history = saved
            lock.unlock()
            return
        }
        // First run: fill in the last week from the power management log. It takes a few
        // seconds of CPU, so it happens once, in the background, and never again.
        guard let output = runStatsCommandOutput("/usr/bin/pmset", arguments: ["-g", "log"], timeout: 20) else { return }
        let imported = parsePMSetLogBatteryHistory(output)
        lock.lock()
        history.prepend(imported, now: Date())
        lock.unlock()
        unsavedCount += 1
        saveIfNeeded(force: true)
    }
}

extension BatteryHistorySample {
    init(details: BatteryDetails, date: Date) {
        self.init(
            date: date,
            percentage: details.percentage,
            isCharging: details.isCharging,
            isPluggedIn: details.isPluggedIn,
            systemLoadWatts: details.systemLoadWatts,
            batteryPowerWatts: details.batteryPowerWatts
        )
    }
}
