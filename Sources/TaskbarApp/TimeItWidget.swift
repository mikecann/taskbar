import AppKit

struct TimeItWidgetSnapshot: Decodable, Equatable {
    let running: Bool
    let startedAt: Double
    let category: String
    let pending: Int

    static func decode(_ data: Data) -> TimeItWidgetSnapshot? {
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.startedAt.isFinite, value.startedAt >= 0 else { return nil }
        return value
    }
    func text(at date: Date) -> String {
        guard running else { return "Time It" }
        let seconds = Int(max(0, date.timeIntervalSince1970 - startedAt / 1000))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

final class TimeItWidgetMonitor {
    static let shared = TimeItWidgetMonitor()
    private var lastRead = Date.distantPast
    private var cached: TimeItWidgetSnapshot?
    private let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.mikerosoft.time-it/widget.json")
    func snapshot(at date: Date) -> TimeItWidgetSnapshot? {
        // Taskbar can repaint many times a second. Read the atomic projection once per second.
        if date.timeIntervalSince(lastRead) >= 1 {
            cached = (try? Data(contentsOf: file)).flatMap(TimeItWidgetSnapshot.decode)
            lastRead = date
        }
        return cached
    }
}

struct TimeItWidgetPlugin: TaskbarWidgetPlugin {
    let id: TaskbarWidgetID = .timeIt
    let title = "Time It"
    let symbolName = "timer"
    func isEnabled(in values: TaskbarSettingValues) -> Bool { values.timeItWidget.isEnabled }
    func minimumWidth(in values: TaskbarSettingValues, height: CGFloat) -> CGFloat { 96 }
    func preferredWidth(in values: TaskbarSettingValues, height: CGFloat, availableWidth: CGFloat) -> CGFloat { 96 }
    func draw(in rect: NSRect, values: TaskbarSettingValues, date: Date) {
        let snapshot = TimeItWidgetMonitor.shared.snapshot(at: date)
        let running = snapshot?.running == true
        let text = (running ? "■ " : "▶ ") + (snapshot?.text(at: date) ?? "Time It")
        let font = NSFont.monospacedDigitSystemFont(ofSize: min(12, max(10, rect.height - 10)), weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: running ? NSColor.systemOrange : NSColor(calibratedWhite: 0.92, alpha: 1), .paragraphStyle: paragraph]
        let height = ceil(font.ascender - font.descender)
        (text as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2 - 1, width: rect.width, height: height + 2), withAttributes: attrs)
    }
}
