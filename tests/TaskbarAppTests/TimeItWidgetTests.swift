import XCTest
@testable import TaskbarApp

final class TimeItWidgetTests: XCTestCase {
    func testMissingStateDoesNotClaimRunningTimer() {
        XCTAssertNil(TimeItWidgetSnapshot.decode(Data("broken".utf8)))
    }
    func testRunningTimerUsesPersistedStartAndClampsClockChanges() throws {
        let snapshot = try XCTUnwrap(TimeItWidgetSnapshot.decode(Data(#"{"running":true,"startedAt":100000,"category":"Convex","pending":2}"#.utf8)))
        XCTAssertEqual(snapshot.text(at: Date(timeIntervalSince1970: 160)), "00:01:00")
        XCTAssertEqual(snapshot.text(at: Date(timeIntervalSince1970: 90)), "00:00:00")
        XCTAssertEqual(snapshot.category, "Convex")
    }
    func testStoppedTimerInvitesStartingConvex() throws {
        let snapshot = try XCTUnwrap(TimeItWidgetSnapshot.decode(Data(#"{"running":false,"startedAt":0,"category":"Convex","pending":0}"#.utf8)))
        XCTAssertEqual(snapshot.text(at: Date()), "Time It")
    }
    func testWidgetSettingRoundTripsAndResolvesMonitorOverride() throws {
        let settings = TaskbarSettings(store: RecordingSettingsStore())
        settings.updateGeneral { $0.timeItWidget.isEnabled = true }
        settings.updateOverrides(for: "7") { $0.timeItWidget = TimeItWidgetSettings(isEnabled: false) }
        XCTAssertTrue(settings.values(for: "8").timeItWidget.isEnabled)
        XCTAssertFalse(settings.values(for: "7").timeItWidget.isEnabled)
        let data = try JSONEncoder().encode(settings.preferences.general)
        XCTAssertTrue(try JSONDecoder().decode(TaskbarSettingValues.self, from: data).timeItWidget.isEnabled)
    }
}

private final class RecordingSettingsStore: TaskbarSettingsStoring {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) {}
}
