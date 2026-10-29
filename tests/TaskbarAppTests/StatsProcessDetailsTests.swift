import AppKit
import XCTest
@testable import TaskbarApp

final class StatsProcessDetailsTests: XCTestCase {
    func testInterpreterLabelsNameTheScriptOrDaemon() {
        XCTAssertEqual(
            statsInterpreterLabel(
                executableName: "node",
                arguments: ["/usr/local/bin/node", "/Users/me/Library/Threadbear/runner/scripts/deploy.mjs", "--no-restart"]
            ),
            "node · deploy"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "node", arguments: ["node", "/repo/node_modules/vite/bin/vite.js", "dev"]),
            "node · vite"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "node", arguments: ["node", "/repo/node_modules/convex/dist/cli/index.js"]),
            "node · convex"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "node", arguments: ["node", "--require", "/x/hook.js", "/repo/server/index.js"]),
            "node · repo"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "node", arguments: ["node", "--test", "test/unit/a.test.ts"]),
            "node · test"
        )
        XCTAssertEqual(
            statsInterpreterLabel(
                executableName: "java",
                arguments: ["java", "-Xmx64m", "-cp", "/x/gradle-launcher.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.9"]
            ),
            "java · Gradle daemon"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "java", arguments: ["java", "--add-opens", "java.base/java.lang=ALL-UNNAMED", "-cp", "/a.jar", "com.example.MainKt"]),
            "java · MainKt"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "python3", arguments: ["python3", "-u", "-m", "http.server"]),
            "python3 · http.server"
        )
        XCTAssertEqual(
            statsInterpreterLabel(executableName: "python3.12", arguments: ["python3.12", "/x/train.py"]),
            "python3.12 · train"
        )
        // Nothing better than the bare name.
        XCTAssertNil(statsInterpreterLabel(executableName: "node", arguments: ["node"]))
        XCTAssertNil(statsInterpreterLabel(executableName: "zsh", arguments: ["zsh", "-c", "swift build"]))
    }

    func testFolderLabelsKeepGenericFoldersReadable() {
        let home = "/Users/me"
        XCTAssertEqual(statsFolderLabel("/Users/me/dev/threadbear-threads/usage-e6846bb0/app", home: home), "usage-e6846bb0/app")
        XCTAssertEqual(statsFolderLabel("/Users/me/dev/poddle", home: home), "poddle")
        XCTAssertEqual(statsFolderLabel("/Users/me", home: home), "~")
        XCTAssertNil(statsFolderLabel("/", home: home))
    }

    func testStableOrderKeepsRowsStillAndAppendsNewOnes() {
        XCTAssertEqual(statsStableOrder(current: ["b", "a", "c"], frozen: nil), ["b", "a", "c"])
        XCTAssertEqual(statsStableOrder(current: ["b", "a", "d"], frozen: ["a", "b", "c"]), ["a", "b", "d"])
    }

    func testSubrowsSplitByFolderThenByName() {
        let members = [
            StatsProcessMember(pid: 1, name: "swift-frontend", folder: "/Users/me/w/one/app", startedBy: nil, cpuPercent: 3, memoryBytes: 0),
            StatsProcessMember(pid: 2, name: "swift-frontend", folder: "/Users/me/w/one/app", startedBy: nil, cpuPercent: 2, memoryBytes: 0),
            StatsProcessMember(pid: 3, name: "swift-frontend", folder: "/Users/me/w/two", startedBy: nil, cpuPercent: 6, memoryBytes: 0),
            StatsProcessMember(pid: 4, name: "Helper (Renderer)", folder: "/", startedBy: nil, cpuPercent: 1, memoryBytes: 0)
        ]

        let rows = statsProcessSubrows(members, values: [\.cpuPercent], home: "/Users/me")

        XCTAssertEqual(rows.map(\.label), ["two", "one/app", "Helper (Renderer)"])
        XCTAssertEqual(rows.map(\.pids), [[3], [1, 2], [4]])
        XCTAssertEqual(rows.map(\.value), [6, 5, 1])
        XCTAssertEqual(rows[1].folder, "/Users/me/w/one/app")
        XCTAssertNil(rows[2].folder)
    }

    func testTableLayoutExpandsOneRowAndClipsToTheBottom() {
        let items = statsProcessTableLayout(
            rowKeys: ["a", "b", "c"],
            expandedKey: "a",
            subrowKeys: ["s1", "s2", "s3", "s4", "s5"],
            top: 0,
            bottom: 190,
            x: 0,
            width: 300
        )

        // 26 + 24 + 3 × 22 + "+2 more" 22 + 6 gap = 144, then b at 144-170; c would end at 196, past 190.
        XCTAssertEqual(items.map(Self.describe), [
            "group a", "detail a", "subrow s1", "subrow s2", "subrow s3", "more 2", "group b"
        ])
        XCTAssertEqual(items.last?.rect.minY, 144)
    }

    func testWindowCPUCountsReapedChildrenOnceAndHandlesPIDReuse() {
        let previous: [Int: StatsProcessReading] = [
            40: StatsProcessReading(pid: 40, parentPID: 1, cpuSeconds: 1.0, memoryBytes: 0, executablePath: "swift-package", childCPUSeconds: 0),
            // Seen alive last time, so its 0.5s (and 0.1s of its own children) are already counted.
            41: StatsProcessReading(pid: 41, parentPID: 40, cpuSeconds: 0.5, memoryBytes: 0, executablePath: "swift-frontend", childCPUSeconds: 0.1),
            50: StatsProcessReading(pid: 50, parentPID: 1, cpuSeconds: 9.0, memoryBytes: 0, executablePath: "old", childCPUSeconds: nil)
        ]
        let current = [
            StatsProcessReading(pid: 40, parentPID: 1, cpuSeconds: 1.2, memoryBytes: 0, executablePath: "swift-package", childCPUSeconds: 2.0),
            // pid 50 now belongs to a new process with less CPU time than the old one had.
            StatsProcessReading(pid: 50, parentPID: 1, cpuSeconds: 0.3, memoryBytes: 0, executablePath: "new", childCPUSeconds: nil)
        ]

        let window = statsProcessWindowCPUSeconds(current: current, previous: previous)

        XCTAssertEqual(window[40]?.fromChildren ?? 0, 2.0 - 0.6, accuracy: 0.0001)
        XCTAssertEqual(window[40]?.total ?? 0, 0.2 + 1.4, accuracy: 0.0001)
        XCTAssertEqual(window[50]?.total ?? 0, 0.3, accuracy: 0.0001)
    }

    func testWindowCPUDoesNotDoubleCountAChainThatExitsTogether() {
        // bash (live) → swift test (exits) → xctest (exits). We counted 2s of swift test and
        // 30s of xctest while they ran; bash's child time now jumps by their lifetimes.
        let previous: [Int: StatsProcessReading] = [
            60: StatsProcessReading(pid: 60, parentPID: 1, cpuSeconds: 0.1, memoryBytes: 0, executablePath: "bash", childCPUSeconds: 0),
            61: StatsProcessReading(pid: 61, parentPID: 60, cpuSeconds: 2.0, memoryBytes: 0, executablePath: "swift-test", childCPUSeconds: 0),
            62: StatsProcessReading(pid: 62, parentPID: 61, cpuSeconds: 30.0, memoryBytes: 0, executablePath: "xctest", childCPUSeconds: 0)
        ]
        let current = [
            StatsProcessReading(pid: 60, parentPID: 1, cpuSeconds: 0.1, memoryBytes: 0, executablePath: "bash", childCPUSeconds: 2.5 + 31.0)
        ]

        let window = statsProcessWindowCPUSeconds(current: current, previous: previous)

        // Only the last 0.5s of swift test and 1s of xctest are new.
        XCTAssertEqual(window[60]?.fromChildren ?? 0, 1.5, accuracy: 0.0001)
    }

    func testProcArgsParserSkipsTheExecutablePathAndPadding() {
        var buffer: [UInt8] = []
        var argc = Int32(2)
        withUnsafeBytes(of: &argc) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/usr/bin/node".utf8) + [0, 0, 0])
        buffer.append(contentsOf: Array("node".utf8) + [0])
        buffer.append(contentsOf: Array("script.js".utf8) + [0])
        buffer.append(contentsOf: Array("PATH=/bin".utf8) + [0])

        XCTAssertEqual(parseStatsProcArgs(buffer), ["node", "script.js"])
    }

    func testQuitStopsAProcessAndRefusesToQuitItself() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        XCTAssertTrue(quitStatsProcesses([Int(sleeper.processIdentifier)], force: false))
        sleeper.waitUntilExit()
        XCTAssertEqual(sleeper.terminationReason, .uncaughtSignal)

        // Our own pid and launchd are skipped rather than signalled.
        XCTAssertTrue(quitStatsProcesses([Int(ProcessInfo.processInfo.processIdentifier), 1], force: true))
    }

    func testExecutableDisplayNameLooksPastVersionNamedBinaries() {
        XCTAssertEqual(statsExecutableDisplayName("/Users/me/.local/share/claude/versions/2.1.312"), "claude")
        XCTAssertEqual(statsExecutableDisplayName("/usr/bin/swift-frontend"), "swift-frontend")
        XCTAssertEqual(statsExecutableDisplayName("/opt/tool/bin/tool.sh"), "tool")
        XCTAssertEqual(statsExecutableDisplayName("node"), "node")
    }

    func testNettopParserSkipsLifetimeTotalsAndTimesEachBlock() {
        var parser = StatsNettopStreamParser()
        let start = Date(timeIntervalSince1970: 1_000)

        // First block is lifetime totals, with the control bytes `script` puts in front.
        XCTAssertEqual(parser.feed("\u{4}\u{8}\u{8},bytes_in,bytes_out,\r\napsd.387,20908531,6495667,\r\n", at: start), [])
        XCTAssertNil(parser.flush())

        // A block can arrive split across reads.
        XCTAssertEqual(parser.feed(",bytes_in,bytes_out,\r\nScreen Sharing.36643,94", at: start.addingTimeInterval(2)), [])
        XCTAssertEqual(parser.feed("104,0,\r\nnode.73302,1215,4362,\r\n", at: start.addingTimeInterval(2.05)), [])
        let block = parser.flush()
        XCTAssertEqual(block?.interval, 2)
        XCTAssertEqual(block?.entries, [
            .init(name: "Screen Sharing", pid: 36643, bytesIn: 94104, bytesOut: 0),
            .init(name: "node", pid: 73302, bytesIn: 1215, bytesOut: 4362)
        ])
        XCTAssertNil(parser.flush(), "a block is only handed over once")

        // If nothing flushed it, the next header does.
        _ = parser.feed(",bytes_in,bytes_out,\r\napsd.387,10,20,\r\n", at: start.addingTimeInterval(4))
        let closed = parser.feed(",bytes_in,bytes_out,\r\n", at: start.addingTimeInterval(6))
        XCTAssertEqual(closed.map(\.entries.count), [1])
    }

    private static func describe(_ item: StatsProcessTableItem) -> String {
        switch item {
        case let .group(key, _): return "group \(key)"
        case let .detail(key, _): return "detail \(key)"
        case let .subrow(_, subrowKey, _): return "subrow \(subrowKey)"
        case let .more(_, hidden, _): return "more \(hidden)"
        }
    }
}
