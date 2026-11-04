import AppKit
import PrompterKit

/// The studio pieces the lights button can drive one at a time from its hover panel.
enum StudioControl: CaseIterable {
    case lights
    case largeText
    case prompter

    var title: String {
        switch self {
        case .lights: return "Lights"
        case .largeText: return "Large text"
        case .prompter: return "Prompter"
        }
    }

    /// First symbol this macOS knows wins, so newer names can sit ahead of older fallbacks.
    var symbolNames: [String] {
        switch self {
        case .lights: return ["lightbulb"]
        case .largeText: return ["textformat.size"]
        case .prompter: return ["text.viewfinder", "doc.plaintext"]
        }
    }
}

struct StudioControlState: Equatable {
    var isOn: Bool
    var isAvailable: Bool
    var isBusy: Bool
}

func studioControlDisplayedState(actualOn: Bool?, pendingTarget: Bool?, isBusy: Bool) -> StudioControlState {
    // While a change is running, show where it's heading rather than flicking
    // back to the old value until the hardware catches up.
    if let pendingTarget {
        return StudioControlState(isOn: pendingTarget, isAvailable: true, isBusy: true)
    }
    guard let actualOn else {
        return StudioControlState(isOn: false, isAvailable: false, isBusy: isBusy)
    }
    return StudioControlState(isOn: actualOn, isAvailable: true, isBusy: isBusy)
}

/// Runs studio changes from the lights button and its hover panel. Main thread only.
final class StudioControlsCoordinator {
    static let shared = StudioControlsCoordinator()

    private let displayLinkManagerURL = URL(fileURLWithPath: "/Applications/DisplayLink Manager.app")
    private var pending: [StudioControl: Bool] = [:]
    private var displayOperations: [(@escaping () -> Void) -> Void] = []
    private var isRunningDisplayOperation = false

    func state(of control: StudioControl) -> StudioControlState {
        switch control {
        case .lights:
            let snapshot = ControlCenterLightsController.shared.snapshot()
            return studioControlDisplayedState(
                actualOn: snapshot.reachableCount > 0 ? snapshot.allReachableLightsAreOn : nil,
                pendingTarget: pending[.lights],
                isBusy: snapshot.isBusy
            )
        case .largeText, .prompter:
            return studioControlDisplayedState(
                actualOn: actualState(of: control),
                pendingTarget: pending[control],
                isBusy: false
            )
        }
    }

    func toggle(_ control: StudioControl) {
        let current = state(of: control)
        guard current.isAvailable, !current.isBusy else { return }
        set(control, on: !current.isOn)
    }

    /// The lights button itself: everything follows the lights, as it always has.
    func toggleStudio(controlsTeleprompter: Bool, controlsStudioDisplayScaling: Bool) {
        ControlCenterLightsController.shared.toggleAll { [weak self] target in
            guard let target else { return }
            DispatchQueue.main.async {
                launchRecordItWhenStudioTurnsOn(target)
                // Queued in this order on purpose: a display mode change makes
                // macOS rebuild menu-bar state, so DisplayLink's AX interaction
                // has to finish before PA27JCV scaling can invalidate its status item.
                if controlsTeleprompter {
                    self?.set(.prompter, on: target)
                }
                if controlsStudioDisplayScaling {
                    self?.set(.largeText, on: target)
                }
            }
        }
    }

    func set(_ control: StudioControl, on target: Bool) {
        pending[control] = target
        switch control {
        case .lights:
            ControlCenterLightsController.shared.setAll(target) { [weak self] _ in
                DispatchQueue.main.async {
                    if self?.pending[.lights] == target {
                        self?.pending[.lights] = nil
                    }
                }
            }
        case .largeText:
            enqueueDisplayOperation { [weak self] done in
                StudioDisplayScalingController.shared.setStudioEnabled(target) { result in
                    if case let .failure(error) = result {
                        log("PA27JCV scaling change failed: \(error.localizedDescription)")
                    }
                    self?.settle(.largeText, at: target, succeeded: (try? result.get()) != nil)
                    done()
                }
            }
        case .prompter:
            enqueueDisplayOperation { [weak self] done in
                let largeTextBefore = StudioDisplayScalingController.shared.isLargeText()
                DisplayLinkTeleprompterController.shared.setEnabled(target) { result in
                    if case let .failure(error) = result {
                        log("DisplayLink Elgato Prompter change failed: \(error.localizedDescription)")
                    }
                    self?.settle(.prompter, at: target, succeeded: (try? result.get()) != nil)
                    guard (try? result.get()) != nil, let largeTextBefore else {
                        done()
                        return
                    }
                    // macOS remembers a layout per set of connected displays,
                    // modes included, so the prompter coming or going also
                    // switches PA27JCV's scaling. Put it back once the display
                    // change has landed, unless a Large text change is queued.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self?.restoreLargeText(largeTextBefore, then: done)
                    }
                }
            }
        }
    }

    private func restoreLargeText(_ wanted: Bool, then done: @escaping () -> Void) {
        guard pending[.largeText] == nil,
              let current = StudioDisplayScalingController.shared.isLargeText(),
              current != wanted
        else {
            done()
            return
        }
        log("PA27JCV scaling changed with the prompter; putting it back")
        StudioDisplayScalingController.shared.setStudioEnabled(wanted) { result in
            if case let .failure(error) = result {
                log("PA27JCV scaling restore failed: \(error.localizedDescription)")
            }
            done()
        }
    }

    private func actualState(of control: StudioControl) -> Bool? {
        switch control {
        case .lights:
            let snapshot = ControlCenterLightsController.shared.snapshot()
            return snapshot.reachableCount > 0 ? snapshot.allReachableLightsAreOn : nil
        case .largeText:
            return StudioDisplayScalingController.shared.isLargeText()
        case .prompter:
            // The prompter only exists as a screen while it's switched on, so
            // DisplayLink Manager being installed is what makes the switch usable.
            guard FileManager.default.fileExists(atPath: displayLinkManagerURL.path) else { return nil }
            return NSScreen.screens.contains { PrompterDisplay.isPrompterDisplay(named: $0.localizedName) }
        }
    }

    /// DisplayLink reports success when its switch flips, and the prompter screen
    /// (or PA27JCV's new mode) can show up a moment later. Keep showing the target
    /// until macOS agrees, for up to three seconds.
    private func settle(_ control: StudioControl, at target: Bool, succeeded: Bool, attemptsLeft: Int = 12) {
        guard pending[control] == target else { return }
        guard succeeded, attemptsLeft > 0, actualState(of: control) != target else {
            pending[control] = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.settle(control, at: target, succeeded: true, attemptsLeft: attemptsLeft - 1)
        }
    }

    private func enqueueDisplayOperation(_ operation: @escaping (@escaping () -> Void) -> Void) {
        displayOperations.append(operation)
        runNextDisplayOperation()
    }

    private func runNextDisplayOperation() {
        guard !isRunningDisplayOperation, !displayOperations.isEmpty else { return }
        isRunningDisplayOperation = true
        let operation = displayOperations.removeFirst()
        operation { [weak self] in
            self?.isRunningDisplayOperation = false
            self?.runNextDisplayOperation()
        }
    }
}

// MARK: - Hover panel

enum StudioControlsLayout {
    static let padding: CGFloat = 6
    static let rowHeight: CGFloat = 34
    static let width: CGFloat = 184

    static var size: NSSize {
        NSSize(width: width, height: padding * 2 + rowHeight * CGFloat(StudioControl.allCases.count))
    }

    /// In the panel's flipped coordinates, first row at the top.
    static func rowRect(at index: Int, in bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.minX + padding,
            y: bounds.minY + padding + CGFloat(index) * rowHeight,
            width: bounds.width - padding * 2,
            height: rowHeight
        )
    }

    static func control(at point: NSPoint, in bounds: NSRect) -> StudioControl? {
        StudioControl.allCases.enumerated()
            .first { rowRect(at: $0.offset, in: bounds).contains(point) }?
            .element
    }
}

func studioControlsPopoverFrame(buttonRect: NSRect, screenFrame: NSRect, size: NSSize) -> NSRect {
    let x = min(
        max(buttonRect.midX - size.width / 2, screenFrame.minX + 8),
        screenFrame.maxX - size.width - 8
    )
    let y = min(buttonRect.maxY + 6, screenFrame.maxY - size.height - 8)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
}

func studioControlsPopoverKeepsOpen(pointer: NSPoint, buttonRect: NSRect, popoverFrame: NSRect) -> Bool {
    // The bridge spans the gap between the button and the panel, so moving
    // straight up into the panel doesn't count as leaving.
    let bridge = NSRect(
        x: buttonRect.minX,
        y: buttonRect.maxY - 1,
        width: buttonRect.width,
        height: max(0, popoverFrame.minY - buttonRect.maxY) + 2
    )
    return [buttonRect, bridge, popoverFrame].contains { $0.insetBy(dx: -2, dy: -2).contains(pointer) }
}

final class StudioControlsPopoverView: NSView {
    var stateProvider: (StudioControl) -> StudioControlState = { _ in
        StudioControlState(isOn: false, isAvailable: false, isBusy: false)
    }
    var onToggle: (StudioControl) -> Void = { _ in }

    private var hoveredControl: StudioControl?
    private var trackingArea: NSTrackingArea?
    private static let onColor = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.32, alpha: 1)

    override var isFlipped: Bool { true }

    // The panel never becomes key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
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
        let control = StudioControlsLayout.control(at: convert(event.locationInWindow, from: nil), in: bounds)
        guard control != hoveredControl else { return }
        hoveredControl = control
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredControl = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let control = StudioControlsLayout.control(at: convert(event.locationInWindow, from: nil), in: bounds) else {
            return
        }
        onToggle(control)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor(calibratedWhite: 0.18, alpha: 0.98).setFill()
        background.fill()
        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        background.lineWidth = 1
        background.stroke()

        for (index, control) in StudioControl.allCases.enumerated() {
            drawRow(
                control,
                state: stateProvider(control),
                in: StudioControlsLayout.rowRect(at: index, in: bounds)
            )
        }
    }

    private func drawRow(_ control: StudioControl, state: StudioControlState, in rect: NSRect) {
        let canToggle = state.isAvailable && !state.isBusy
        if hoveredControl == control, canToggle {
            NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        let contentAlpha: CGFloat = state.isAvailable ? 1 : 0.35
        let iconColor = state.isOn ? Self.onColor : NSColor(calibratedWhite: 0.86, alpha: 1)
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: iconColor))
        if let image = control.symbolNames.lazy
            .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: control.title) })
            .first?
            .withSymbolConfiguration(configuration) {
            let imageRect = NSRect(
                x: rect.minX + 10 + (18 - image.size.width) / 2,
                y: rect.midY - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: contentAlpha, respectFlipped: true, hints: nil)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: contentAlpha)
        ]
        let title = control.title as NSString
        let titleSize = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: rect.minX + 38, y: rect.midY - titleSize.height / 2), withAttributes: attributes)

        drawSwitch(isOn: state.isOn, alpha: canToggle ? 1 : 0.4, in: NSRect(
            x: rect.maxX - 10 - 30,
            y: rect.midY - 9,
            width: 30,
            height: 18
        ))
    }

    private func drawSwitch(isOn: Bool, alpha: CGFloat, in rect: NSRect) {
        let track = isOn ? Self.onColor : NSColor(calibratedWhite: 1, alpha: 0.18)
        track.withAlphaComponent(track.alphaComponent * alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        let knobSize = rect.height - 4
        let knob = NSRect(
            x: isOn ? rect.maxX - 2 - knobSize : rect.minX + 2,
            y: rect.minY + 2,
            width: knobSize,
            height: knobSize
        )
        NSColor(calibratedWhite: 1, alpha: alpha).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}
