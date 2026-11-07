import AppKit
import Foundation

enum BatteryPopoverLayout {
    static let size = NSSize(width: 660, height: 690)
    static let columnGap: CGFloat = 22
    static let margin: CGFloat = 18

    static func leftColumn(in bounds: NSRect) -> NSRect {
        let width = (bounds.width - margin * 2 - columnGap) * 0.53
        return NSRect(x: margin, y: 0, width: width, height: bounds.height)
    }

    static func rightColumn(in bounds: NSRect) -> NSRect {
        let left = leftColumn(in: bounds)
        return NSRect(x: left.maxX + columnGap, y: 0, width: bounds.maxX - margin - left.maxX - columnGap, height: bounds.height)
    }

    static func chargeChart(in bounds: NSRect) -> NSRect {
        let column = leftColumn(in: bounds)
        return NSRect(x: column.minX, y: 372, width: column.width, height: 130)
    }

    static func powerChart(in bounds: NSRect) -> NSRect {
        let column = leftColumn(in: bounds)
        return NSRect(x: column.minX, y: 548, width: column.width, height: 124)
    }
}

/// Where a point in time lands on a chart that runs from `end - range` to `end`.
func batteryChartX(for date: Date, end: Date, range: TimeInterval, in plot: NSRect) -> CGFloat {
    let ratio = 1 - CGFloat(end.timeIntervalSince(date) / range)
    return plot.minX + min(1, max(0, ratio)) * plot.width
}

/// The Mac's own estimate wobbles from minute to minute; anything this far apart on the
/// x axis is a gap (asleep, or the taskbar wasn't running) rather than a line to draw.
func batteryChartMaximumGap(for range: BatteryChartRange) -> TimeInterval {
    switch range {
    case .twelveHours: return 5 * 60
    case .twoDays: return 15 * 60
    case .week: return 45 * 60
    }
}

final class BatteryPopoverViewController: NSViewController {
    private var refreshTimer: Timer?

    override func loadView() {
        view = BatteryPopoverView(frame: NSRect(origin: .zero, size: BatteryPopoverLayout.size))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        (view as? BatteryPopoverView)?.refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            (self?.view as? BatteryPopoverView)?.refresh()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

final class BatteryPopoverView: NSView {
    private(set) var details: BatteryDetails?
    private var history: [BatteryHistorySample] = []
    private var energyUsers: [BatteryEnergyUser] = []
    private(set) var range: BatteryChartRange = .twelveHours
    private var rangeButtonRects: [(BatteryChartRange, NSRect)] = []
    private var hoverPoint: NSPoint?
    private var trackingArea: NSTrackingArea?
    /// Lets tests and screenshots draw a fixed moment instead of the live battery.
    var now: () -> Date = Date.init

    override var isFlipped: Bool { true }

    // The panel never becomes key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func refresh() {
        details = currentBatteryDetails()
        if let details {
            BatteryHistoryRecorder.shared.record(details)
        }
        history = BatteryHistoryRecorder.shared.samples
        energyUsers = BatteryEnergySampler.shared.latest
        BatteryEnergySampler.shared.refreshIfNeeded { [weak self] in
            self?.energyUsers = BatteryEnergySampler.shared.latest
            self?.needsDisplay = true
        }
        needsDisplay = true
    }

    /// For tests and screenshots: show fixed data with no sampling.
    func show(details: BatteryDetails?, history: [BatteryHistorySample], energyUsers: [BatteryEnergyUser], range: BatteryChartRange = .twelveHours) {
        self.details = details
        self.history = history
        self.energyUsers = energyUsers
        self.range = range
        needsDisplay = true
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charts = [BatteryPopoverLayout.chargeChart(in: bounds), BatteryPopoverLayout.powerChart(in: bounds)]
        let wasOverChart = hoverPoint.map { point in charts.contains { $0.contains(point) } } ?? false
        hoverPoint = point
        if wasOverChart || charts.contains(where: { $0.contains(point) }) {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = rangeButtonRects.first(where: { $0.1.insetBy(dx: -3, dy: -3).contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        range = hit.0
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18).fill()

        drawHeader()
        guard let details else {
            drawText(
                "No internal battery found",
                in: NSRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24),
                size: 15, weight: .medium, color: secondaryTextColor, alignment: .center
            )
            return
        }

        let status = batteryPowerStatus(details)
        let left = BatteryPopoverLayout.leftColumn(in: bounds)
        let right = BatteryPopoverLayout.rightColumn(in: bounds)

        drawHero(details: details, status: status, in: left)
        drawPowerFlow(details: details, in: left)
        drawChargeHistory(in: BatteryPopoverLayout.chargeChart(in: bounds), column: left)
        drawPowerHistory(in: BatteryPopoverLayout.powerChart(in: bounds), column: left)
        let detailsBottom = drawHealthAndDetails(details: details, in: right)
        drawEnergyUsers(in: right, below: detailsBottom)
    }

    private func drawHeader() {
        let iconRect = NSRect(x: 24, y: 27, width: 26, height: 14)
        drawBatteryGlyph(percentage: details?.percentage ?? 0, color: primaryTextColor, in: iconRect)
        drawText("Battery", in: NSRect(x: 0, y: 18, width: bounds.width, height: 32), size: 24, weight: .semibold, color: .white, alignment: .center)
    }

    private func drawHero(details: BatteryDetails, status: BatteryPowerStatus, in column: NSRect) {
        let accent = batteryPopoverAccent(details: details, status: status)
        let center = NSPoint(x: column.minX + 60, y: 122)
        drawRing(percent: Double(details.percentage), color: accent, center: center, radius: 50)
        drawText("\(details.percentage)%", in: NSRect(x: center.x - 46, y: center.y - 16, width: 92, height: 30), size: 25, weight: .semibold, color: .white, alignment: .center)

        let textX = column.minX + 132
        let textWidth = column.maxX - textX
        drawText(status.title, in: NSRect(x: textX, y: 72, width: textWidth, height: 22), size: 15, weight: .semibold, color: accent)
        drawText(status.timeValue, in: NSRect(x: textX, y: 96, width: textWidth, height: 40), size: 32, weight: .light, color: .white)
        drawText(status.timeCaption, in: NSRect(x: textX, y: 138, width: textWidth, height: 18), size: 13, weight: .medium, color: secondaryTextColor)

        if let explanation = status.explanation {
            drawWrappedText(explanation, in: NSRect(x: column.minX + 4, y: 184, width: column.width - 4, height: 36), size: 12, color: secondaryTextColor)
        }
    }

    private func drawPowerFlow(details: BatteryDetails, in column: NSRect) {
        drawSectionTitle("POWER", y: 232, in: column)
        let gap: CGFloat = 8
        let width = (column.width - gap * 2) / 3
        let battery = details.batteryPowerWatts
        let charger = details.adapterPowerWatts ?? (details.isPluggedIn ? nil : 0)

        let batteryValue: String
        let batteryColor: NSColor
        if let battery, battery > 0.5 {
            batteryValue = "+" + formattedBatteryWatts(battery)
            batteryColor = chargingColor
        } else if let battery, battery < -0.5 {
            batteryValue = "−" + formattedBatteryWatts(battery)
            batteryColor = drainingColor
        } else {
            batteryValue = battery == nil ? "--" : "0 W"
            batteryColor = primaryTextColor
        }

        let tiles: [(String, String, NSColor, String)] = [
            ("Charger", charger.map(formattedBatteryWatts) ?? "--", details.isPluggedIn ? chargingColor : secondaryTextColor,
             details.adapter.map { "\($0.watts) W max" } ?? "not connected"),
            ("Mac", details.systemLoadWatts.map(formattedBatteryWatts) ?? "--", macLoadColor, "using now"),
            ("Battery", batteryValue, batteryColor, battery.map { $0 > 0.5 ? "charging" : ($0 < -0.5 ? "draining" : "idle") } ?? "")
        ]
        for (index, tile) in tiles.enumerated() {
            let rect = NSRect(x: column.minX + CGFloat(index) * (width + gap), y: 262, width: width, height: 70)
            NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            drawText(tile.0, in: NSRect(x: rect.minX + 10, y: rect.minY + 8, width: rect.width - 20, height: 16), size: 11, weight: .semibold, color: secondaryTextColor)
            drawText(tile.1, in: NSRect(x: rect.minX + 10, y: rect.minY + 24, width: rect.width - 20, height: 26), size: 20, weight: .medium, color: tile.2)
            drawText(tile.3, in: NSRect(x: rect.minX + 10, y: rect.minY + 50, width: rect.width - 20, height: 14), size: 10, weight: .medium, color: tertiaryTextColor)
        }
    }

    private func drawChargeHistory(in rect: NSRect, column: NSRect) {
        drawSectionTitle("CHARGE", y: 346, in: column, leftAligned: true)
        drawRangeButtons(rightEdge: column.maxX, y: 344)

        let end = now()
        let samples = history.filter { $0.date >= end.addingTimeInterval(-range.duration) }
        let plot = drawChartFrame(in: rect, yLabels: [(0, "0%"), (50, "50%"), (100, "100%")], maxValue: 100)
        let runs = batteryHistoryRuns(samples, maximumGap: batteryChartMaximumGap(for: range))

        withClip(plot) {
            // Green bands where the charger was in, so the line's rises and falls make sense.
            for run in runs {
                for (sample, next) in zip(run, run.dropFirst()) where sample.isPluggedIn {
                    let x0 = batteryChartX(for: sample.date, end: end, range: range.duration, in: plot)
                    let x1 = batteryChartX(for: next.date, end: end, range: range.duration, in: plot)
                    chargingColor.withAlphaComponent(0.12).setFill()
                    NSRect(x: x0, y: plot.minY, width: max(1, x1 - x0), height: plot.height).fill()
                }
            }
            for run in runs {
                drawSeries(run.map { ($0.date, Double($0.percentage)) }, end: end, maxValue: 100, in: plot, color: chargeLineColor, fillAlpha: 0.16)
            }
        }

        if samples.isEmpty {
            drawText("History starts filling in from now", in: plot, size: 11, weight: .medium, color: tertiaryTextColor, alignment: .center, verticallyCentered: true)
        }
        drawHover(in: plot, end: end, samples: samples) { sample in
            var parts = ["\(sample.percentage)%"]
            parts.append(sample.isCharging ? "charging" : (sample.isPluggedIn ? "plugged in" : "on battery"))
            return parts.joined(separator: ", ")
        }
    }

    private func drawPowerHistory(in rect: NSRect, column: NSRect) {
        drawSectionTitle("POWER USE", y: 522, in: column, leftAligned: true)
        drawLegend([("Mac", macLoadColor), ("Charger", chargingColor)], rightEdge: column.maxX, y: 522)

        let end = now()
        let samples = history.filter { $0.date >= end.addingTimeInterval(-range.duration) && $0.systemLoadWatts != nil }
        let chargerWatts: (BatteryHistorySample) -> Double = { sample in
            max(0, (sample.systemLoadWatts ?? 0) + (sample.batteryPowerWatts ?? 0))
        }
        let peak = samples.map { max($0.systemLoadWatts ?? 0, chargerWatts($0)) }.max() ?? 0
        let maxValue = batteryNiceChartMax(peak)
        let plot = drawChartFrame(
            in: rect,
            yLabels: [(0, "0 W"), (maxValue / 2, formattedBatteryWatts(maxValue / 2)), (maxValue, formattedBatteryWatts(maxValue))],
            maxValue: maxValue
        )
        let runs = batteryHistoryRuns(samples, maximumGap: batteryChartMaximumGap(for: range))
        withClip(plot) {
            for run in runs {
                drawSeries(run.map { ($0.date, chargerWatts($0)) }, end: end, maxValue: maxValue, in: plot, color: chargingColor, fillAlpha: 0.10)
                drawSeries(run.map { ($0.date, $0.systemLoadWatts ?? 0) }, end: end, maxValue: maxValue, in: plot, color: macLoadColor, fillAlpha: 0.0)
            }
        }
        if samples.isEmpty {
            drawText("Power readings start from now", in: plot, size: 11, weight: .medium, color: tertiaryTextColor, alignment: .center, verticallyCentered: true)
        }
        drawHover(in: plot, end: end, samples: samples) { sample in
            "Mac \(formattedBatteryWatts(sample.systemLoadWatts ?? 0)), charger \(formattedBatteryWatts(chargerWatts(sample)))"
        }
    }

    /// Returns where the details end, so the energy list can sit right under them.
    private func drawHealthAndDetails(details: BatteryDetails, in column: NSRect) -> CGFloat {
        drawSectionTitle("HEALTH", y: 66, in: column)
        var y: CGFloat = 94
        func row(_ label: String, _ value: String, color: NSColor = .white) {
            drawText(label, in: NSRect(x: column.minX + 4, y: y, width: column.width * 0.46, height: 18), size: 13, weight: .medium, color: secondaryTextColor)
            drawText(value, in: NSRect(x: column.minX + column.width * 0.40, y: y, width: column.width * 0.60 - 4, height: 18), size: 13, weight: .semibold, color: color, alignment: .right)
            y += 24
        }

        if let health = details.healthPercent {
            row("Maximum capacity", "\(health)%", color: health < 80 ? drainingColor : .white)
        }
        if let cycles = details.cycleCount {
            let limit = details.designCycleCount.map { " of \(formattedBatteryCount($0))" } ?? ""
            row("Cycle count", "\(formattedBatteryCount(cycles))\(limit)")
        }
        if let temperature = details.temperatureCelsius {
            row("Temperature", String(format: "%.1f °C", temperature), color: temperature >= 40 ? drainingColor : .white)
        }

        drawSectionTitle("DETAILS", y: y + 10, in: column)
        y += 38
        if let current = details.currentCapacityMilliampHours, let full = details.fullChargeCapacityMilliampHours {
            row("Charge", "\(formattedBatteryCount(current)) of \(formattedBatteryCount(full)) mAh")
        }
        if let design = details.designCapacityMilliampHours {
            row("Design capacity", "\(formattedBatteryCount(design)) mAh")
        }
        if let energy = details.watthoursRemaining {
            row("Energy left", String(format: "%.1f Wh", energy))
        }
        if let voltage = details.voltage {
            row("Voltage", String(format: "%.2f V", voltage))
        }
        if let amperage = details.amperage {
            row("Current", String(format: "%@%.2f A", amperage < -0.005 ? "−" : "", abs(amperage)))
        }
        if !details.cellVoltages.isEmpty {
            row("Cells", details.cellVoltages.map { String(format: "%.2f", $0) }.joined(separator: " · ") + " V")
        }
        if let adapter = details.adapter {
            row("Charger", "\(adapter.watts) W" + (adapter.description.map { " \($0)" } ?? ""))
            if let voltage = adapter.voltage, let current = adapter.current, voltage > 0, current > 0 {
                row("Charger supply", "\(formattedBatteryNumber(voltage)) V at \(formattedBatteryNumber(current)) A")
            }
        }
        if let low = details.todayLowPercent, let high = details.todayHighPercent {
            row("Today", "\(low)% to \(high)%")
        }
        if let lifetime = details.lifetimeTemperatureRange {
            row("Lifetime temps", "\(lifetime.lowerBound) to \(lifetime.upperBound) °C")
        }
        row("Low Power Mode", details.isLowPowerMode ? "On" : "Off")
        return y
    }

    private func drawEnergyUsers(in column: NSRect, below detailsBottom: CGFloat) {
        let titleY = detailsBottom + 14
        drawSectionTitle("USING ENERGY", y: titleY, in: column)
        guard !energyUsers.isEmpty else {
            drawText("Measuring...", in: NSRect(x: column.minX, y: titleY + 30, width: column.width, height: 18), size: 12, weight: .medium, color: tertiaryTextColor, alignment: .center)
            return
        }
        let top = energyUsers.first?.impact ?? 1
        for (index, user) in energyUsers.prefix(6).enumerated() {
            let y = titleY + 28 + CGFloat(index) * 25
            let iconRect = NSRect(x: column.minX + 4, y: y, width: 18, height: 18)
            if let path = user.appPath {
                NSWorkspace.shared.icon(forFile: path).draw(in: iconRect)
            }
            let barWidth = (column.width * 0.28) * CGFloat(min(1, user.impact / max(top, 1)))
            NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
            NSBezierPath(roundedRect: NSRect(x: column.maxX - column.width * 0.28 - 4, y: y + 6, width: column.width * 0.28, height: 6), xRadius: 3, yRadius: 3).fill()
            macLoadColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: column.maxX - column.width * 0.28 - 4, y: y + 6, width: max(3, barWidth), height: 6), xRadius: 3, yRadius: 3).fill()
            let name = user.processCount > 1 ? "\(user.name) (\(user.processCount))" : user.name
            drawText(name, in: NSRect(x: iconRect.maxX + 8, y: y + 1, width: column.width * 0.46, height: 18), size: 13, weight: .medium, color: primaryTextColor)
            drawText(String(format: "%.0f", user.impact), in: NSRect(x: column.minX + column.width * 0.5, y: y + 1, width: column.width * 0.18, height: 18), size: 13, weight: .semibold, color: .white, alignment: .right)
        }
    }

    // MARK: Chart pieces

    private func drawChartFrame(in rect: NSRect, yLabels: [(Double, String)], maxValue: Double) -> NSRect {
        let layout = statsPopoverChartLayout(in: rect)
        NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
        NSBezierPath(roundedRect: layout.panel, xRadius: 7, yRadius: 7).fill()

        let grid = NSBezierPath()
        for (value, label) in yLabels where maxValue > 0 {
            let y = layout.plot.maxY - CGFloat(min(1, max(0, value / maxValue))) * layout.plot.height
            grid.move(to: NSPoint(x: layout.plot.minX, y: y))
            grid.line(to: NSPoint(x: layout.plot.maxX, y: y))
            drawText(label, in: NSRect(x: layout.yAxis.minX - 4, y: y - 6, width: layout.yAxis.width + 4, height: 12), size: 8.5, weight: .medium, color: tertiaryTextColor, alignment: .right)
        }
        let ticks = batteryChartTicks(for: range)
        for (index, label) in ticks.enumerated() {
            let x = layout.plot.minX + CGFloat(index) / CGFloat(ticks.count - 1) * layout.plot.width
            grid.move(to: NSPoint(x: x, y: layout.plot.minY))
            grid.line(to: NSPoint(x: x, y: layout.plot.maxY))
            let alignment: NSTextAlignment = index == 0 ? .left : (index == ticks.count - 1 ? .right : .center)
            let labelX = alignment == .left ? x : (alignment == .right ? x - 50 : x - 25)
            drawText(label, in: NSRect(x: labelX, y: layout.xAxis.minY, width: 50, height: layout.xAxis.height), size: 8.5, weight: .medium, color: tertiaryTextColor, alignment: alignment)
        }
        grid.lineWidth = 0.75
        NSColor(calibratedWhite: 1, alpha: 0.09).setStroke()
        grid.stroke()
        return layout.plot
    }

    private func drawSeries(_ points: [(Date, Double)], end: Date, maxValue: Double, in plot: NSRect, color: NSColor, fillAlpha: CGFloat) {
        guard maxValue > 0, !points.isEmpty else { return }
        let mapped = points.map { date, value in
            NSPoint(
                x: batteryChartX(for: date, end: end, range: range.duration, in: plot),
                y: plot.maxY - CGFloat(min(1, max(0, value / maxValue))) * plot.height
            )
        }
        if mapped.count == 1 {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: mapped[0].x - 1.5, y: mapped[0].y - 1.5, width: 3, height: 3)).fill()
            return
        }
        if fillAlpha > 0 {
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: mapped[0].x, y: plot.maxY))
            mapped.forEach { fill.line(to: $0) }
            fill.line(to: NSPoint(x: mapped[mapped.count - 1].x, y: plot.maxY))
            fill.close()
            color.withAlphaComponent(fillAlpha).setFill()
            fill.fill()
        }
        let line = NSBezierPath()
        line.move(to: mapped[0])
        mapped.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1.6
        line.lineJoinStyle = .round
        color.setStroke()
        line.stroke()
    }

    private func drawHover(in plot: NSRect, end: Date, samples: [BatteryHistorySample], label: (BatteryHistorySample) -> String) {
        guard let hoverPoint, plot.insetBy(dx: -2, dy: -2).contains(hoverPoint), !samples.isEmpty else { return }
        let ratio = Double((hoverPoint.x - plot.minX) / plot.width)
        let date = end.addingTimeInterval(-range.duration * (1 - ratio))
        guard let nearest = samples.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) < batteryChartMaximumGap(for: range)
        else {
            return
        }
        let x = batteryChartX(for: nearest.date, end: end, range: range.duration, in: plot)
        NSColor(calibratedWhite: 1, alpha: 0.45).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: x, y: plot.minY), to: NSPoint(x: x, y: plot.maxY))

        let text = "\(batteryHoverTimeFormatter(range: range).string(from: nearest.date))  \(label(nearest))"
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 14
        let boxX = min(max(plot.minX + 2, x - width / 2), plot.maxX - width - 2)
        let box = NSRect(x: boxX, y: plot.minY + 4, width: width, height: 18)
        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        drawText(text, in: box.insetBy(dx: 7, dy: 2), size: 10.5, weight: .semibold, color: .white)
    }

    private func drawRangeButtons(rightEdge: CGFloat, y: CGFloat) {
        rangeButtonRects = []
        var x = rightEdge
        for option in BatteryChartRange.allCases.reversed() {
            let width: CGFloat = 34
            x -= width
            let rect = NSRect(x: x, y: y, width: width, height: 20)
            if option == range {
                NSColor(calibratedWhite: 1, alpha: 0.16).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            drawText(option.label, in: rect.insetBy(dx: 0, dy: 3), size: 11, weight: .semibold, color: option == range ? .white : tertiaryTextColor, alignment: .center)
            rangeButtonRects.append((option, rect))
            x -= 2
        }
    }

    private func drawLegend(_ items: [(String, NSColor)], rightEdge: CGFloat, y: CGFloat) {
        var x = rightEdge
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for (label, color) in items.reversed() {
            let width = ceil((label as NSString).size(withAttributes: [.font: font]).width)
            x -= width
            drawText(label, in: NSRect(x: x, y: y + 2, width: width + 2, height: 16), size: 11, weight: .semibold, color: secondaryTextColor)
            x -= 13
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 7, width: 9, height: 6), xRadius: 2, yRadius: 2).fill()
            x -= 12
        }
    }

    private func drawSectionTitle(_ title: String, y: CGFloat, in column: NSRect, leftAligned: Bool = false) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let lineY = y + 9.5
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        if leftAligned {
            drawText(title, in: NSRect(x: column.minX, y: y, width: width + 4, height: 20), size: 11.5, weight: .semibold, color: tertiaryTextColor)
            return
        }
        let titleX = column.midX - width / 2
        NSBezierPath.strokeLine(from: NSPoint(x: column.minX, y: lineY), to: NSPoint(x: titleX - 12, y: lineY))
        NSBezierPath.strokeLine(from: NSPoint(x: titleX + width + 12, y: lineY), to: NSPoint(x: column.maxX, y: lineY))
        drawText(title, in: NSRect(x: titleX - 2, y: y, width: width + 4, height: 20), size: 11.5, weight: .semibold, color: tertiaryTextColor, alignment: .center)
    }

    private func drawRing(percent: Double, color: NSColor, center: NSPoint, radius: CGFloat) {
        let base = NSBezierPath()
        base.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        base.lineWidth = 9
        NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
        base.stroke()

        let value = NSBezierPath()
        value.appendArc(withCenter: center, radius: radius, startAngle: 270, endAngle: 270 + CGFloat(min(100, max(0, percent)) / 100 * 360), clockwise: false)
        value.lineWidth = 9
        value.lineCapStyle = .round
        color.setStroke()
        value.stroke()
    }

    private func drawBatteryGlyph(percentage: Int, color: NSColor, in rect: NSRect) {
        let geometry = batteryIconGeometry(in: rect, percentage: percentage)
        let body = NSBezierPath(roundedRect: geometry.bodyRect.insetBy(dx: 0.6, dy: 0.6), xRadius: 3, yRadius: 3)
        body.lineWidth = 1.2
        color.setStroke()
        body.stroke()
        color.setFill()
        NSBezierPath(roundedRect: geometry.terminalRect, xRadius: 1, yRadius: 1).fill()
        if geometry.fillRect.width > 0 {
            NSBezierPath(roundedRect: geometry.fillRect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func withClip(_ rect: NSRect, _ body: () -> Void) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).addClip()
        body()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawText(
        _ value: String,
        in rect: NSRect,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        verticallyCentered: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        var target = rect
        if verticallyCentered {
            let height = ceil(font.ascender - font.descender)
            target = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        (value as NSString).draw(in: target, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawWrappedText(_ value: String, in rect: NSRect, size: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1
        // Keep "27 W" together when the sentence wraps.
        let value = value.replacingOccurrences(of: " W", with: "\u{00A0}W")
        (value as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    private var primaryTextColor: NSColor { NSColor(calibratedWhite: 0.92, alpha: 1) }
    private var secondaryTextColor: NSColor { NSColor(calibratedWhite: 0.72, alpha: 1) }
    private var tertiaryTextColor: NSColor { NSColor(calibratedWhite: 0.56, alpha: 1) }
    private var chargingColor: NSColor { NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.39, alpha: 1) }
    private var drainingColor: NSColor { NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1) }
    private var macLoadColor: NSColor { NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1) }
    private var chargeLineColor: NSColor { NSColor(calibratedRed: 0.40, green: 0.68, blue: 1.0, alpha: 1) }
}

func batteryPopoverAccent(details: BatteryDetails, status: BatteryPowerStatus) -> NSColor {
    switch status.state {
    case .charging, .full:
        return NSColor(calibratedRed: 0.28, green: 0.84, blue: 0.39, alpha: 1)
    case .chargerTooWeak:
        return NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1)
    case .onBattery, .onHold:
        return details.percentage <= 20
            ? NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.26, alpha: 1)
            : NSColor(calibratedWhite: 0.92, alpha: 1)
    }
}

/// x axis labels, oldest first.
func batteryChartTicks(for range: BatteryChartRange) -> [String] {
    switch range {
    case .twelveHours: return ["-12h", "-9h", "-6h", "-3h", "now"]
    case .twoDays: return ["-48h", "-36h", "-24h", "-12h", "now"]
    case .week: return ["-7d", "-6d", "-5d", "-4d", "-3d", "-2d", "-1d", "now"]
    }
}

func batteryNiceChartMax(_ value: Double) -> Double {
    for step in [10.0, 20, 30, 40, 60, 80, 100, 120, 160, 200] where value <= step * 0.95 {
        return step
    }
    return (value / 50).rounded(.up) * 50
}

func formattedBatteryCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

private func batteryHoverTimeFormatter(range: BatteryChartRange) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = range == .twelveHours ? "HH:mm" : "EEE HH:mm"
    return formatter
}
