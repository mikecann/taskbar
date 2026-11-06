import XCTest
@testable import TaskbarApp

final class AgentChromeTests: XCTestCase {
    func testKnowsBrowserBearsAgentChromeByItsProfileFolder() {
        XCTAssertTrue(isAgentChromeArguments([
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--user-data-dir=/Users/m5-mike/Library/Application Support/BrowserBear/agent/chrome-profile",
            "--remote-debugging-port=9339",
        ]))
    }

    func testLeavesTheUsersOwnChromeAlone() {
        XCTAssertFalse(isAgentChromeArguments(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]))
        XCTAssertFalse(isAgentChromeArguments([
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "--user-data-dir=/tmp/some-test-profile",
        ]))
    }

    func testReadsThisProcesssOwnArguments() {
        let arguments = processArguments(pid: getpid())
        XCTAssertEqual(arguments?.first.map { URL(fileURLWithPath: $0).lastPathComponent }, URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent)
    }
}
