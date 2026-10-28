import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarPinMarkerTests: XCTestCase {
    func testPinMarkerSitsInBottomLeftCornerAwayFromBadge() throws {
        let iconRect = NSRect(x: 10, y: 4, width: 24, height: 24)
        let marker = try XCTUnwrap(taskbarPinMarkerRect(in: iconRect))

        // Bottom-left, overhanging the icon a touch like a Dock badge does.
        XCTAssertLessThan(marker.minX, iconRect.minX)
        XCTAssertLessThan(marker.minY, iconRect.minY)
        XCTAssertLessThan(marker.maxX, iconRect.midX)
        XCTAssertLessThan(marker.maxY, iconRect.midY)

        // The Dock badge owns the top-right corner.
        let badge = NSRect(x: iconRect.maxX - 12, y: iconRect.maxY - 12, width: 12, height: 12)
        XCTAssertFalse(marker.intersects(badge))
    }

    func testPinMarkerIsSkippedOnTinyIcons() {
        XCTAssertNil(taskbarPinMarkerRect(in: NSRect(x: 0, y: 0, width: 12, height: 12)))
    }

    func testOnlyPinnedItemsShowThePinMarker() {
        let pinned = PinnedApp(displayName: "Notion", bundleID: "notion.id", appPath: "/Applications/Notion.app")
        let items = buildTaskbarItems(windows: [], frontmostPID: nil, pinnedApps: [pinned], runningApps: [
            TaskbarRunningApp(name: "Notion", pid: 42, bundleID: "notion.id", appPath: "/Applications/Notion.app"),
            TaskbarRunningApp(name: "Slack", pid: 43, bundleID: "com.tinyspeck.slackmacgap", appPath: "/Applications/Slack.app")
        ])

        XCTAssertTrue(taskbarItemShowsPinMarker(items.first(where: { $0.owner == "Notion" })!))
        XCTAssertFalse(taskbarItemShowsPinMarker(items.first(where: { $0.owner == "Slack" })!))
    }
}
