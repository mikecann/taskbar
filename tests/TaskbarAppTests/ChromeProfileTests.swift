import AppKit
import XCTest
@testable import TaskbarApp

final class ChromeProfileTests: XCTestCase {
    // Real titles from Chrome 2026, with the tab's own " – Pinned" in one.
    func testReadsTheProfileChromeAppendsToItsWindowTitle() {
        XCTAssertEqual(
            chromeWindowProfileName(
                accessibilityTitle: "Inbox (7,211) - mike@cannstudios.co - Cann Studios Mail - Google Chrome \u{2013} Michael (cannstudios.com)",
                bundleID: "com.google.Chrome"
            ),
            "Michael (cannstudios.com)"
        )
        XCTAssertEqual(
            chromeWindowProfileName(
                accessibilityTitle: "Channel content - YouTube Studio \u{2013} Pinned - Google Chrome \u{2013} Michael (convex.dev)",
                bundleID: "com.google.Chrome"
            ),
            "Michael (convex.dev)"
        )
        XCTAssertEqual(
            chromeWindowProfileName(
                accessibilityTitle: "New Tab - Google Chrome Canary \u{2013} Work",
                bundleID: "com.google.Chrome.canary"
            ),
            "Work"
        )
    }

    func testNoProfileForSingleProfileChromeOrOtherApps() {
        XCTAssertNil(chromeWindowProfileName(accessibilityTitle: "Inbox - Google Chrome", bundleID: "com.google.Chrome"))
        XCTAssertNil(chromeWindowProfileName(
            accessibilityTitle: "Doc \u{2013} Draft - Google Chrome",
            bundleID: "com.google.Chrome"
        ))
        XCTAssertNil(chromeWindowProfileName(
            accessibilityTitle: "Notes - Google Chrome \u{2013} Michael",
            bundleID: "com.apple.Safari"
        ))
    }

    func testMatchesSignedInAndPlainProfileNames() throws {
        let entries = parseChromeLocalState(Data(localState.utf8))
        XCTAssertEqual(entries.map(\.directory), ["Default", "Profile 4", "Profile 9"])

        XCTAssertEqual(matchChromeProfile(windowProfile: "Michael (cannstudios.com)", in: entries)?.directory, "Profile 4")
        // Chrome drops the brackets when the profile name is the given name.
        XCTAssertEqual(matchChromeProfile(windowProfile: "Michael", in: entries)?.directory, "Default")
        XCTAssertEqual(matchChromeProfile(windowProfile: "Guesty", in: entries)?.directory, "Profile 9")
        XCTAssertNil(matchChromeProfile(windowProfile: "Someone else", in: entries))
        XCTAssertNil(try XCTUnwrap(entries.last).pictureFileName)
    }

    func testBadgeWaitsForThePictureThenReportsItReady() {
        var scheduled: [() -> Void] = []
        var loaded: [String] = []
        let store = ChromeProfileStore(
            applicationSupport: URL(fileURLWithPath: "/AS"),
            readData: { _ in Data(localState.utf8) },
            modificationDate: { _ in Date(timeIntervalSince1970: 1) },
            loadPicture: { path in loaded.append(path); return makeImage() },
            schedule: { scheduled.append($0) }
        )

        let first = store.badge(windowProfile: "Michael (cannstudios.com)", bundleID: "com.google.Chrome")
        XCTAssertEqual(first, TaskbarProfileBadge(
            initial: "C",
            picturePath: "/AS/Google/Chrome/Profile 4/Google Profile Picture.png",
            pictureReady: false
        ))
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(loaded, ["/AS/Google/Chrome/Profile 4/Google Profile Picture.png"])

        let second = store.badge(windowProfile: "Michael (cannstudios.com)", bundleID: "com.google.Chrome")
        XCTAssertEqual(second?.pictureReady, true)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testProfilesWithoutAPictureFallBackToTheirInitial() {
        let store = ChromeProfileStore(
            applicationSupport: URL(fileURLWithPath: "/AS"),
            readData: { _ in Data(localState.utf8) },
            modificationDate: { _ in nil },
            loadPicture: { _ in XCTFail("nothing to load"); return nil },
            schedule: { $0() }
        )
        XCTAssertEqual(
            store.badge(windowProfile: "Guesty", bundleID: "com.google.Chrome"),
            TaskbarProfileBadge(initial: "G", picturePath: nil, pictureReady: false)
        )
        XCTAssertNil(store.badge(windowProfile: "Guesty", bundleID: "com.apple.Safari"))
    }

    func testChromeWindowItemsCarryTheirProfile() {
        let items = buildTaskbarItems(windows: [
            chromeWindow(id: 1, axTitle: "Inbox - Google Chrome \u{2013} Michael (cannstudios.com)"),
            chromeWindow(id: 2, axTitle: "Inbox - Google Chrome")
        ], frontmostPID: nil)

        XCTAssertEqual(items.map(\.browserProfileName), ["Michael (cannstudios.com)", nil])
    }

    func testProfileBadgeSitsBottomRightClearOfThePinAndDockBadge() throws {
        let iconRect = NSRect(x: 10, y: 4, width: 24, height: 24)
        let profile = try XCTUnwrap(taskbarProfileBadgeRect(in: iconRect))
        let pin = try XCTUnwrap(taskbarPinMarkerRect(in: iconRect))
        let dockBadge = NSRect(x: iconRect.maxX - 12, y: iconRect.maxY - 12, width: 12, height: 12)

        XCTAssertGreaterThan(profile.minX, iconRect.midX)
        XCTAssertLessThan(profile.maxY, iconRect.midY)
        XCTAssertFalse(profile.intersects(pin))
        XCTAssertFalse(profile.intersects(dockBadge))
        XCTAssertNil(taskbarProfileBadgeRect(in: NSRect(x: 0, y: 0, width: 12, height: 12)))
    }
}

private let localState = """
{"profile": {"info_cache": {
  "Default": {"name": "Michael", "gaia_given_name": "Michael", "gaia_picture_file_name": "Google Profile Picture.png"},
  "Profile 4": {"name": "cannstudios.com", "gaia_given_name": "Michael", "gaia_picture_file_name": "Google Profile Picture.png"},
  "Profile 9": {"name": "Guesty", "gaia_given_name": "", "gaia_picture_file_name": ""}
}}}
"""

private func chromeWindow(id: Int, axTitle: String) -> WindowRecord {
    WindowRecord(
        owner: "Google Chrome", title: "Inbox", pid: 7, windowID: id, accessibilityWindowID: id,
        layer: 0, isOnScreen: true, isMinimized: false, bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
        screenID: 1, bundleID: "com.google.Chrome", appPath: "/Applications/Google Chrome.app",
        accessibilityTitle: axTitle, accessibilitySignature: ""
    )
}

private func makeImage() -> CGImage {
    let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
