import XCTest
@testable import TaskbarApp

private func dragHoverItem(
    owner: String = "Slack",
    pid: pid_t? = 42,
    windowIDs: [Int] = [7],
    isFrontmost: Bool = false,
    isMinimized: Bool = false
) -> TaskbarItem {
    TaskbarItem(
        owner: owner,
        pid: pid,
        title: "",
        windowCount: windowIDs.count,
        windowIDs: windowIDs,
        windowBounds: nil,
        accessibilitySignature: "",
        isFrontmost: isFrontmost,
        isMinimized: isMinimized,
        bundleID: "com.example.\(owner.lowercased())",
        appPath: "/Applications/\(owner).app",
        isPinned: false,
        pinOrder: nil
    )
}

final class TaskbarDragHoverTests: XCTestCase {
    func testFiresOnceAfterDwellingOnTheSameItem() {
        var hover = TaskbarDragHover(delay: 0.5)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(hover.update(key: "slack", at: start))
        XCTAssertFalse(hover.update(key: "slack", at: start.addingTimeInterval(0.3)))
        XCTAssertTrue(hover.update(key: "slack", at: start.addingTimeInterval(0.5)))
        // Staying on the tile after it opened must not keep re-activating it.
        XCTAssertFalse(hover.update(key: "slack", at: start.addingTimeInterval(2)))
    }

    func testMovingToAnotherItemRestartsTheDwell() {
        var hover = TaskbarDragHover(delay: 0.5)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(hover.update(key: "slack", at: start))
        XCTAssertFalse(hover.update(key: "chrome", at: start.addingTimeInterval(0.4)))
        XCTAssertFalse(hover.update(key: "chrome", at: start.addingTimeInterval(0.8)))
        XCTAssertTrue(hover.update(key: "chrome", at: start.addingTimeInterval(0.9)))
    }

    func testComingBackToAnItemAfterLeavingCanFireAgain() {
        var hover = TaskbarDragHover(delay: 0.5)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        _ = hover.update(key: "slack", at: start)
        XCTAssertTrue(hover.update(key: "slack", at: start.addingTimeInterval(0.6)))
        XCTAssertFalse(hover.update(key: nil, at: start.addingTimeInterval(0.7)))
        XCTAssertFalse(hover.update(key: "slack", at: start.addingTimeInterval(0.8)))
        XCTAssertTrue(hover.update(key: "slack", at: start.addingTimeInterval(1.3)))
    }

    func testNoItemNeverFires() {
        var hover = TaskbarDragHover(delay: 0.5)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(hover.update(key: nil, at: start))
        XCTAssertFalse(hover.update(key: nil, at: start.addingTimeInterval(5)))
    }

    func testResetForgetsTheDwell() {
        var hover = TaskbarDragHover(delay: 0.5)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        _ = hover.update(key: "slack", at: start)
        hover.reset()
        XCTAssertFalse(hover.update(key: "slack", at: start.addingTimeInterval(0.6)))
        XCTAssertTrue(hover.update(key: "slack", at: start.addingTimeInterval(1.1)))
    }

    func testDragHoverOpensBackgroundAndMinimizedWindows() {
        XCTAssertTrue(taskbarItemOpensOnDragHover(dragHoverItem()))
        XCTAssertTrue(taskbarItemOpensOnDragHover(dragHoverItem(isMinimized: true)))
        XCTAssertTrue(taskbarItemOpensOnDragHover(dragHoverItem(pid: nil, windowIDs: [])))
    }

    func testDragHoverLeavesTheFrontmostWindowAlone() {
        // A click on the frontmost tile minimizes it, which is the opposite of
        // what you want while carrying something to drop into it.
        XCTAssertFalse(taskbarItemOpensOnDragHover(dragHoverItem(isFrontmost: true)))
    }
}
