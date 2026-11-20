import AppKit
import XCTest
@testable import TaskbarApp

final class TaskbarAudioTests: XCTestCase {
    private let chrome = TaskbarRunningApp(name: "Google Chrome", pid: 42, bundleID: "com.google.Chrome", appPath: "/Applications/Google Chrome.app")
    private let slack = TaskbarRunningApp(name: "Slack", pid: 43, bundleID: "com.tinyspeck.slackmacgap", appPath: "/Applications/Slack.app")

    func testHelperProcessesAreCreditedToTheAppResponsibleForThem() {
        // Chrome plays sound from its audio service helper; WebKit from a
        // process launchd started, whose responsible app is the one showing it.
        let pids = taskbarAudioAppPIDs([
            AudioOutputProcess(pid: 900, responsiblePID: 42),
            AudioOutputProcess(pid: 77, responsiblePID: -1)
        ])
        XCTAssertEqual(pids, [900, 42, 77])
    }

    func testOnlyItemsOfAppsPlayingSoundGetTheSpeaker() {
        let items = buildTaskbarItems(windows: [], frontmostPID: nil, runningApps: [chrome, slack])
        let marked = applyingAudioPlaying([42], to: items)
        XCTAssertTrue(marked.first(where: { $0.owner == "Google Chrome" })!.isPlayingAudio)
        XCTAssertFalse(marked.first(where: { $0.owner == "Slack" })!.isPlayingAudio)
        // A change in sound has to repaint the bar.
        XCTAssertNotEqual(items, marked)
        XCTAssertEqual(applyingAudioPlaying([], to: marked), items)
    }

    func testClosedPinnedAppsNeverGetTheSpeaker() {
        let pinned = PinnedApp(displayName: "Notion", bundleID: "notion.id", appPath: "/Applications/Notion.app")
        let items = buildTaskbarItems(windows: [], frontmostPID: nil, pinnedApps: [pinned])
        XCTAssertFalse(applyingAudioPlaying([0], to: items)[0].isPlayingAudio)
    }

    func testSpeakerSitsTopLeftClearOfTheOtherCornerMarks() throws {
        let iconRect = NSRect(x: 10, y: 4, width: 24, height: 24)
        let speaker = try XCTUnwrap(taskbarAudioMarkerRect(in: iconRect))
        XCTAssertLessThan(speaker.minX, iconRect.minX)
        XCTAssertGreaterThan(speaker.maxY, iconRect.maxY)
        XCTAssertLessThan(speaker.maxX, iconRect.midX)
        XCTAssertGreaterThan(speaker.minY, iconRect.midY)

        // The Dock badge owns the top-right, the pin the bottom-left.
        let badge = NSRect(x: iconRect.maxX - 12, y: iconRect.maxY - 12, width: 12, height: 12)
        XCTAssertFalse(speaker.intersects(badge))
        XCTAssertFalse(speaker.intersects(try XCTUnwrap(taskbarPinMarkerRect(in: iconRect))))
    }

    func testSpeakerIsSkippedOnTinyIcons() {
        XCTAssertNil(taskbarAudioMarkerRect(in: NSRect(x: 0, y: 0, width: 12, height: 12)))
    }

    func testAgentBrowserPlayingSoundGetsALabelledButtonThatPausesIt() throws {
        let agent = TaskbarRunningApp(name: "Helium", pid: 50, bundleID: "net.imput.helium", appPath: "/Applications/Helium.app")
        let items = taskbarAgentAudioItems([agent], pausePending: [])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(taskbarItemLabel(item), "Agent browser")
        XCTAssertTrue(taskbarItemShowsLabel(item))
        XCTAssertTrue(item.isPlayingAudio)
        XCTAssertFalse(item.isPinned)
        XCTAssertEqual(taskbarItemClickAction(for: item), .pauseAgentAudio)
        XCTAssertFalse(item.isAudioPausePending)

        // After a click it shows the pause is on its way and takes no second click.
        let pending = try XCTUnwrap(taskbarAgentAudioItems([agent], pausePending: [50]).first)
        XCTAssertTrue(pending.isAudioPausePending)
        XCTAssertEqual(taskbarItemClickAction(for: pending), .ignore)
    }

    func testPendingPausesExpire() {
        let now: TimeInterval = 100
        XCTAssertEqual(taskbarPendingAudioPauses([1: 98, 2: 80], now: now), [1])
    }

    func testDebuggingPortComesFromTheCommandLine() {
        XCTAssertEqual(remoteDebuggingPort([
            "/Applications/Helium.app/Contents/MacOS/Helium",
            "--user-data-dir=/x/BrowserBear/agent/helium-profile",
            "--remote-debugging-port=9339"
        ]), 9339)
        XCTAssertNil(remoteDebuggingPort(["/Applications/Helium.app/Contents/MacOS/Helium"]))
        XCTAssertNil(remoteDebuggingPort(["--remote-debugging-port=0"]))
    }

    func testPauseReachesPagesAndEmbeddedFramesOnly() throws {
        let json = """
        [{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9339/devtools/page/A"},
         {"type":"iframe","webSocketDebuggerUrl":"ws://127.0.0.1:9339/devtools/page/B"},
         {"type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:9339/devtools/page/C"},
         {"type":"page"}]
        """
        let urls = try devToolsMediaTargets(Data(json.utf8))
        XCTAssertEqual(urls.map(\.absoluteString), [
            "ws://127.0.0.1:9339/devtools/page/A",
            "ws://127.0.0.1:9339/devtools/page/B"
        ])
    }
}
