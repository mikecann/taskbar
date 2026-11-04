import AppKit
import XCTest
@testable import TaskbarApp

final class StudioControlsTests: XCTestCase {
    func testPopoverListsLightsLargeTextAndPrompterInThatOrder() {
        XCTAssertEqual(StudioControl.allCases, [.lights, .largeText, .prompter])
        XCTAssertEqual(StudioControl.allCases.map(\.title), ["Lights", "Large text", "Prompter"])
    }

    func testDisplayedStateShowsWhatTheHardwareReports() {
        XCTAssertEqual(
            studioControlDisplayedState(actualOn: true, pendingTarget: nil, isBusy: false),
            StudioControlState(isOn: true, isAvailable: true, isBusy: false)
        )
        XCTAssertEqual(
            studioControlDisplayedState(actualOn: false, pendingTarget: nil, isBusy: false),
            StudioControlState(isOn: false, isAvailable: true, isBusy: false)
        )
    }

    func testDisplayedStateShowsTheRequestedValueWhileAChangeIsInFlight() {
        XCTAssertEqual(
            studioControlDisplayedState(actualOn: false, pendingTarget: true, isBusy: false),
            StudioControlState(isOn: true, isAvailable: true, isBusy: true)
        )
        // The display or prompter can disappear mid-change; the switch still shows the intent.
        XCTAssertEqual(
            studioControlDisplayedState(actualOn: nil, pendingTarget: false, isBusy: false),
            StudioControlState(isOn: false, isAvailable: true, isBusy: true)
        )
    }

    func testDisplayedStateIsUnavailableWhenTheHardwareIsMissing() {
        XCTAssertEqual(
            studioControlDisplayedState(actualOn: nil, pendingTarget: nil, isBusy: false),
            StudioControlState(isOn: false, isAvailable: false, isBusy: false)
        )
    }

    func testDisplayedStateIsBusyWhileTheLightsButtonIsTogglingEverything() {
        XCTAssertEqual(
            studioControlDisplayedState(actualOn: true, pendingTarget: nil, isBusy: true),
            StudioControlState(isOn: true, isAvailable: true, isBusy: true)
        )
    }

    func testLargeTextIsOnOnlyForTheLargerTextMode() {
        XCTAssertEqual(studioDisplayIsLargeText(studioDisplayScaleTarget(isStudioEnabled: true)), true)
        XCTAssertEqual(studioDisplayIsLargeText(studioDisplayScaleTarget(isStudioEnabled: false)), false)
        XCTAssertEqual(
            studioDisplayIsLargeText(StudioDisplayModeSize(width: 2048, height: 1152, pixelWidth: 4096, pixelHeight: 2304)),
            false
        )
    }

    func testPopoverSitsCentredAboveTheButton() {
        let frame = studioControlsPopoverFrame(
            buttonRect: NSRect(x: 900, y: 0, width: 30, height: 32),
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            size: NSSize(width: 200, height: 120)
        )

        XCTAssertEqual(frame, NSRect(x: 815, y: 38, width: 200, height: 120))
    }

    func testPopoverStaysOnScreenWhenTheButtonIsNearTheRightEdge() {
        let frame = studioControlsPopoverFrame(
            buttonRect: NSRect(x: 1890, y: 0, width: 30, height: 32),
            screenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            size: NSSize(width: 200, height: 120)
        )

        XCTAssertEqual(frame.maxX, 1912)
    }

    func testPopoverStaysOpenWhileThePointerIsOnTheButtonThePopoverOrTheGapBetween() {
        let button = NSRect(x: 900, y: 0, width: 30, height: 32)
        let popover = NSRect(x: 815, y: 38, width: 200, height: 120)

        XCTAssertTrue(studioControlsPopoverKeepsOpen(pointer: NSPoint(x: 910, y: 10), buttonRect: button, popoverFrame: popover))
        XCTAssertTrue(studioControlsPopoverKeepsOpen(pointer: NSPoint(x: 820, y: 150), buttonRect: button, popoverFrame: popover))
        XCTAssertTrue(studioControlsPopoverKeepsOpen(pointer: NSPoint(x: 915, y: 35), buttonRect: button, popoverFrame: popover))
        XCTAssertFalse(studioControlsPopoverKeepsOpen(pointer: NSPoint(x: 700, y: 10), buttonRect: button, popoverFrame: popover))
        XCTAssertFalse(studioControlsPopoverKeepsOpen(pointer: NSPoint(x: 910, y: 400), buttonRect: button, popoverFrame: popover))
    }

    func testRowsAreHitTestedTopToBottom() {
        let bounds = NSRect(origin: .zero, size: StudioControlsLayout.size)
        let first = StudioControlsLayout.rowRect(at: 0, in: bounds)
        let last = StudioControlsLayout.rowRect(at: 2, in: bounds)

        XCTAssertEqual(StudioControlsLayout.control(at: NSPoint(x: first.midX, y: first.midY), in: bounds), .lights)
        XCTAssertEqual(StudioControlsLayout.control(at: NSPoint(x: last.midX, y: last.midY), in: bounds), .prompter)
        XCTAssertNil(StudioControlsLayout.control(at: NSPoint(x: 1, y: 1), in: bounds))
    }

    func testHoveringTheLightsButtonReportsTheWidgetAndItsRect() throws {
        var values = TaskbarSettingValues.defaults
        values.statsWidget.isEnabled = false
        values.batteryWidget.isEnabled = false
        values.dateTimeWidget.isEnabled = false
        let view = TaskbarView(frame: NSRect(x: 0, y: 0, width: 800, height: 32))
        var pointer: NSPoint? = nil
        view.pointerLocationProvider = { pointer }
        var reports: [TaskbarWidgetID?] = []
        view.onWidgetHover = { widgetID, _, _ in reports.append(widgetID) }
        view.update(items: [], settings: values)

        let rect = try XCTUnwrap(view.widgetRect(for: .controlCenterLights))
        pointer = NSPoint(x: rect.midX, y: rect.midY)
        view.update(items: [], settings: values)
        pointer = NSPoint(x: 5, y: 5)
        view.update(items: [], settings: values)

        XCTAssertEqual(reports, [.controlCenterLights, nil])
    }
}
