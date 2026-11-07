import AppKit
import XCTest
@testable import TaskbarApp

/// IOKit hands signed battery values back as unsigned 64-bit numbers.
private func unsigned(_ value: Int64) -> NSNumber {
    NSNumber(value: UInt64(bitPattern: value))
}

/// Trimmed from this M5 MacBook's real AppleSmartBattery on a 15 W charger.
private func pluggedInDrainingRegistry() -> BatteryRegistryReading {
    BatteryRegistryReading(
        battery: [
            "CurrentCapacity": 59,
            "MaxCapacity": 100,
            "IsCharging": false,
            "ExternalConnected": true,
            "FullyCharged": false,
            "AvgTimeToEmpty": 127,
            "AvgTimeToFull": 65535,
            "CycleCount": 33,
            "DesignCycleCount9C": 1000,
            "Voltage": 11644,
            "Amperage": unsigned(-1808),
            "Serial": "F5DHTS005AT0000VD4",
            "DeviceName": "bq40z651",
            "BatteryData": [
                "AppleRawCurrentCapacity": 3487,
                "AppleRawMaxCapacity": 6162,
                "DesignCapacity": 6249,
                "NominalChargeCapacity": 6314
            ],
            "AdapterDetails": [
                "Watts": 15,
                "AdapterVoltage": 20000,
                "Current": 750,
                "Description": "pd charger",
                "IsWireless": false
            ],
            "PowerTelemetryData": [
                "SystemLoad": 26860,
                "SystemPowerIn": 14865,
                "BatteryPower": unsigned(-11995)
            ],
            "ChargerData": [
                "NotChargingReason": 0,
                "SlowChargingReason": 0,
                "TimeChargingThermallyLimited": 0
            ]
        ],
        pack: [
            "Temperature": 3459,
            "DailyMinSoc": 6,
            "DailyMaxSoc": 62,
            "LifetimeData": [
                "MinimumTemperature": 10,
                "MaximumTemperature": 42
            ]
        ],
        cellVoltagesMillivolts: [3887, 3895, 3892]
    )
}

final class BatteryDetailsTests: XCTestCase {
    func testReadsEverythingTheRegistryOffersWithSignedValuesDecoded() throws {
        let details = try XCTUnwrap(BatteryDetails(registry: pluggedInDrainingRegistry(), isLowPowerMode: false))

        XCTAssertEqual(details.percentage, 59)
        XCTAssertFalse(details.isCharging)
        XCTAssertTrue(details.isPluggedIn)
        XCTAssertEqual(details.currentCapacityMilliampHours, 3487)
        XCTAssertEqual(details.fullChargeCapacityMilliampHours, 6162)
        XCTAssertEqual(details.designCapacityMilliampHours, 6249)
        XCTAssertEqual(details.cycleCount, 33)
        XCTAssertEqual(details.designCycleCount, 1000)
        XCTAssertEqual(try XCTUnwrap(details.voltage), 11.644, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(details.amperage), -1.808, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(details.temperatureCelsius), 34.59, accuracy: 0.001)
        XCTAssertEqual(details.cellVoltages, [3.887, 3.895, 3.892])
        XCTAssertEqual(details.adapter?.watts, 15)
        XCTAssertEqual(details.adapter?.description, "USB-C PD")
        XCTAssertEqual(try XCTUnwrap(details.systemLoadWatts), 26.86, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(details.adapterPowerWatts), 14.865, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(details.batteryPowerWatts), -11.995, accuracy: 0.001)
        XCTAssertEqual(details.timeToEmptyMinutes, 127)
        XCTAssertNil(details.timeToFullMinutes, "65535 means macOS doesn't know yet")
        XCTAssertEqual(details.todayLowPercent, 6)
        XCTAssertEqual(details.todayHighPercent, 62)
        XCTAssertEqual(details.lifetimeTemperatureRange, 10...42)
        XCTAssertEqual(details.serial, "F5DHTS005AT0000VD4")
    }

    func testHealthMatchesSystemSettingsAndNeverShowsOverAHundred() throws {
        let details = try XCTUnwrap(BatteryDetails(registry: pluggedInDrainingRegistry(), isLowPowerMode: false))
        // Nominal 6314 of a 6249 design: System Settings says 100%, not 101%.
        XCTAssertEqual(details.healthPercent, 100)

        var worn = pluggedInDrainingRegistry()
        worn.battery["BatteryData"] = [
            "AppleRawCurrentCapacity": 3000,
            "AppleRawMaxCapacity": 5100,
            "DesignCapacity": 6249,
            "NominalChargeCapacity": 5300
        ]
        XCTAssertEqual(try XCTUnwrap(BatteryDetails(registry: worn, isLowPowerMode: false)).healthPercent, 85)
    }

    func testFallsBackToVoltageTimesCurrentWithoutTelemetry() throws {
        var registry = pluggedInDrainingRegistry()
        registry.battery.removeValue(forKey: "PowerTelemetryData")
        let details = try XCTUnwrap(BatteryDetails(registry: registry, isLowPowerMode: false))

        XCTAssertEqual(try XCTUnwrap(details.batteryPowerWatts), -21.05, accuracy: 0.01)
        XCTAssertNil(details.systemLoadWatts)
    }

    func testNoBatteryMeansNoDetails() {
        XCTAssertNil(BatteryDetails(registry: BatteryRegistryReading(battery: [:]), isLowPowerMode: false))
        XCTAssertNil(BatteryDetails(
            registry: BatteryRegistryReading(battery: ["BatteryInstalled": false, "CurrentCapacity": 50, "MaxCapacity": 100]),
            isLowPowerMode: false
        ))
    }

    func testExplainsAChargerThatCannotKeepUp() throws {
        let details = try XCTUnwrap(BatteryDetails(registry: pluggedInDrainingRegistry(), isLowPowerMode: false))
        let status = batteryPowerStatus(details)

        XCTAssertEqual(status.state, .chargerTooWeak)
        XCTAssertEqual(status.title, "Plugged in, still draining")
        XCTAssertEqual(
            status.explanation,
            "The 15 W charger can't keep up. The Mac is using 27 W, so the battery covers the other 12 W."
        )
        XCTAssertEqual(status.timeValue, "2h 7m")
        XCTAssertEqual(status.timeCaption, "until empty")
    }

    func testChargingShowsTimeToFull() throws {
        var registry = pluggedInDrainingRegistry()
        registry.battery["IsCharging"] = true
        registry.battery["AvgTimeToFull"] = 74
        registry.battery["Amperage"] = 2400
        registry.battery["PowerTelemetryData"] = ["SystemLoad": 9000, "SystemPowerIn": 37000, "BatteryPower": 28000]
        registry.battery["AdapterDetails"] = ["Watts": 70, "AdapterVoltage": 20000, "Current": 3500, "Description": "pd charger"]
        let status = batteryPowerStatus(try XCTUnwrap(BatteryDetails(registry: registry, isLowPowerMode: false)))

        XCTAssertEqual(status.state, .charging)
        XCTAssertEqual(status.title, "Charging")
        XCTAssertEqual(status.timeValue, "1h 14m")
        XCTAssertEqual(status.timeCaption, "until full")
        XCTAssertEqual(status.explanation, "70 W charger, 28 W going into the battery.")
    }

    func testOnBatteryEstimatesFromCurrentWhenMacOSHasNoEstimateYet() throws {
        var registry = pluggedInDrainingRegistry()
        registry.battery["ExternalConnected"] = false
        registry.battery["AvgTimeToEmpty"] = 65535
        registry.battery.removeValue(forKey: "AdapterDetails")
        let details = try XCTUnwrap(BatteryDetails(registry: registry, isLowPowerMode: false))
        let status = batteryPowerStatus(details)

        XCTAssertEqual(status.state, .onBattery)
        XCTAssertEqual(status.title, "On battery")
        // 3487 mAh at 1.808 A is about 1h 56m.
        XCTAssertEqual(status.timeValue, "1h 56m")
        XCTAssertEqual(status.timeCaption, "until empty")
    }

    func testFullAndHeldChargeAreToldApart() throws {
        var full = pluggedInDrainingRegistry()
        full.battery["CurrentCapacity"] = 100
        full.battery["FullyCharged"] = true
        full.battery["PowerTelemetryData"] = ["SystemLoad": 8000, "SystemPowerIn": 8000, "BatteryPower": 0]
        XCTAssertEqual(batteryPowerStatus(try XCTUnwrap(BatteryDetails(registry: full, isLowPowerMode: false))).state, .full)

        var held = pluggedInDrainingRegistry()
        held.battery["CurrentCapacity"] = 80
        held.battery["Amperage"] = 0
        held.battery["PowerTelemetryData"] = ["SystemLoad": 8000, "SystemPowerIn": 8000, "BatteryPower": 0]
        let status = batteryPowerStatus(try XCTUnwrap(BatteryDetails(registry: held, isLowPowerMode: false)))
        XCTAssertEqual(status.state, .onHold)
        XCTAssertEqual(status.title, "Plugged in, not charging")
        XCTAssertEqual(status.timeValue, "Paused")
    }

    func testChargerDescriptionReadsLikeAPerson() throws {
        let adapter = try XCTUnwrap(BatteryDetails(registry: pluggedInDrainingRegistry(), isLowPowerMode: false)?.adapter)
        XCTAssertEqual(batteryAdapterText(adapter), "15 W USB-C PD, 20 V at 0.75 A")
    }

    func testDurationsFormatLikeTheRestOfTheTaskbar() {
        XCTAssertEqual(formattedBatteryDuration(minutes: 5), "5m")
        XCTAssertEqual(formattedBatteryDuration(minutes: 60), "1h 0m")
        XCTAssertEqual(formattedBatteryDuration(minutes: 127), "2h 7m")
    }
}

final class BatteryHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ minutes: Double, _ percent: Int, charging: Bool = false) -> BatteryHistorySample {
        BatteryHistorySample(
            date: start.addingTimeInterval(minutes * 60),
            percentage: percent,
            isCharging: charging,
            isPluggedIn: charging,
            systemLoadWatts: 10,
            batteryPowerWatts: charging ? 20 : -10
        )
    }

    func testKeepsOneSampleAMinuteAndDropsAnythingOlderThanAWeek() {
        var history = BatteryHistory()
        history.append(sample(0, 80))
        history.append(sample(0.5, 79))
        history.append(sample(1, 78))
        XCTAssertEqual(history.samples.map(\.percentage), [80, 78])

        history.append(sample(7 * 24 * 60 + 2, 50))
        XCTAssertEqual(history.samples.map(\.percentage), [50])
    }

    func testRoundTripsThroughItsFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("battery-history.json")
        var history = BatteryHistory()
        history.append(sample(0, 80))
        history.append(sample(1, 79, charging: true))
        try history.save(to: url)

        let loaded = try XCTUnwrap(BatteryHistory.load(from: url))
        XCTAssertEqual(loaded, history)
        XCTAssertNil(BatteryHistory.load(from: url.appendingPathExtension("missing")))
    }

    func testSplitsTheChartLineWhereTheMacWasAsleep() {
        let samples = [sample(0, 80), sample(1, 79), sample(2, 78), sample(90, 70), sample(91, 69)]
        let runs = batteryHistoryRuns(samples, maximumGap: 5 * 60)
        XCTAssertEqual(runs.map { $0.map(\.percentage) }, [[80, 79, 78], [70, 69]])
    }

    func testImportsChargeLevelsFromThePowerManagementLog() {
        let log = """
        2026-11-06 15:02:11 +0800 Assertions          \tSummary- [System: PrevIdle DeclUser kDisp] Using AC(Charge: 41)
        2026-11-06 15:40:00 +0800 Sleep               \tEntering Sleep state due to 'Idle Sleep' Using Batt (Charge:55%) 12 secs
        2026-11-07 07:36:20 +0800 Assertions          \tSummary- [System: PrevIdle] Using Batt(Charge: 62)
        2026-11-07 07:36:21 +0800 Wake Requests        [*process=dasd]
        """
        let samples = parsePMSetLogBatteryHistory(log)

        XCTAssertEqual(samples.map(\.percentage), [41, 55, 62])
        XCTAssertEqual(samples.map(\.isPluggedIn), [true, false, false])
        XCTAssertEqual(samples.first?.date, ISO8601DateFormatter().date(from: "2026-11-06T07:02:11Z"))
        XCTAssertNil(samples.first?.systemLoadWatts)
    }

    func testChargeChartRangesCycleThroughTwelveHoursTwoDaysAndAWeek() {
        XCTAssertEqual(BatteryChartRange.allCases.map(\.label), ["12h", "48h", "7d"])
        XCTAssertEqual(BatteryChartRange.twelveHours.duration, 12 * 3600)
    }
}

final class BatteryEnergyUsersTests: XCTestCase {
    func testParsesTheSecondTopSampleAndGroupsHelpersIntoTheirApp() {
        let output = """
        Processes: 700 total
        PID    COMMAND          POWER
        1      launchd          0.0
        613    WindowServer     12.0
        PID    COMMAND          POWER
        33728  helper           73.4
        613    WindowServer     44.4
        3328   Google Chrome He 29.3
        45088  Google Chrome He 28.0
        70007  top              9.8
        12     idle             0.0
        """
        let paths: [Int: String] = [
            3328: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)",
            45088: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            613: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            33728: "/Applications/Threadbear.app/Contents/Resources/helper"
        ]

        let users = batteryEnergyUsers(fromTopOutput: output, ownPID: 70007, pathForPID: { paths[$0] })

        XCTAssertEqual(users.map(\.name), ["Threadbear", "Google Chrome", "WindowServer"])
        XCTAssertEqual(users.map(\.impact), [73.4, 57.3, 44.4])
        XCTAssertEqual(users[1].appPath, "/Applications/Google Chrome.app")
        XCTAssertEqual(users[1].processCount, 2)
    }
}


final class BatteryPopoverRenderTests: XCTestCase {
    /// Draws the popover offscreen. With BATTERY_POPOVER_SNAPSHOT set to a folder, it uses
    /// the real battery and writes PNGs there for eyeballing the layout.
    func testPopoverDrawsWithAndWithoutABattery() throws {
        let end = Date()
        var history: [BatteryHistorySample] = []
        for minute in stride(from: 12 * 60, through: 0, by: -1) {
            let t = Double(12 * 60 - minute)
            // Discharge, a nap, a charge on the desk, then off the charger again.
            if (300..<360).contains(t) { continue }
            let charging = (360..<540).contains(t)
            let percent = charging ? 30 + (t - 360) * 0.38 : (t < 300 ? 95 - t * 0.2 : 98 - (t - 540) * 0.22)
            let load = 8 + 6 * sin(t / 9) + (t.truncatingRemainder(dividingBy: 47) < 4 ? 14 : 0)
            history.append(BatteryHistorySample(
                date: end.addingTimeInterval(-Double(minute) * 60),
                percentage: Int(percent.rounded()),
                isCharging: charging,
                isPluggedIn: charging,
                systemLoadWatts: load,
                batteryPowerWatts: charging ? 28 : -load
            ))
        }
        let users = [
            BatteryEnergyUser(name: "Threadbear", impact: 73.4, appPath: "/Applications/Threadbear.app", processCount: 1),
            BatteryEnergyUser(name: "WindowServer", impact: 44.4, appPath: nil, processCount: 1),
            BatteryEnergyUser(name: "Google Chrome", impact: 57.3, appPath: "/Applications/Google Chrome.app", processCount: 6)
        ].sorted { $0.impact > $1.impact }

        let snapshotFolder = ProcessInfo.processInfo.environment["BATTERY_POPOVER_SNAPSHOT"]
        let details = snapshotFolder != nil ? currentBatteryDetails() : nil
        for (name, shown) in [("battery-popover.png", details), ("battery-popover-none.png", nil)] {
            let view = BatteryPopoverView(frame: NSRect(origin: .zero, size: BatteryPopoverLayout.size))
            view.appearance = NSAppearance(named: .darkAqua)
            view.show(details: shown, history: history, energyUsers: users)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            if let snapshotFolder, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: snapshotFolder).appendingPathComponent(name))
            }
        }
    }
}
