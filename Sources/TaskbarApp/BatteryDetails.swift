import AppKit
import Foundation
import IOKit

/// The raw dictionaries behind the battery popover: AppleSmartBattery itself, its pack
/// (temperature, today's range, lifetime data) and each bank's cell voltage.
struct BatteryRegistryReading {
    var battery: [String: Any]
    var pack: [String: Any] = [:]
    var cellVoltagesMillivolts: [Int] = []
}

struct BatteryAdapter: Equatable {
    let watts: Int
    let voltage: Double?
    let current: Double?
    let description: String?
    let isWireless: Bool
}

/// Everything the battery popover shows. Most of it comes straight from the IORegistry,
/// which is what `ioreg -l -c AppleSmartBattery` prints, so no subprocess is needed.
struct BatteryDetails: Equatable {
    var percentage: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var isFullyCharged: Bool
    var timeToFullMinutes: Int?
    var timeToEmptyMinutes: Int?
    var currentCapacityMilliampHours: Int?
    var fullChargeCapacityMilliampHours: Int?
    var designCapacityMilliampHours: Int?
    var nominalCapacityMilliampHours: Int?
    var cycleCount: Int?
    var designCycleCount: Int?
    /// Volts.
    var voltage: Double?
    /// Amps, negative while the battery is draining.
    var amperage: Double?
    var temperatureCelsius: Double?
    var cellVoltages: [Double]
    var adapter: BatteryAdapter?
    /// What the whole Mac is drawing right now, in watts.
    var systemLoadWatts: Double?
    /// What's coming in from the charger, in watts.
    var adapterPowerWatts: Double?
    /// Watts into the battery, negative while it's draining.
    var batteryPowerWatts: Double?
    var notChargingReason: Int
    var slowChargingReason: Int
    var thermallyLimitedSeconds: Int
    var todayLowPercent: Int?
    var todayHighPercent: Int?
    var lifetimeTemperatureRange: ClosedRange<Int>?
    var serial: String?
    var isLowPowerMode: Bool

    init?(registry: BatteryRegistryReading, isLowPowerMode: Bool) {
        let battery = registry.battery
        guard batteryRegistryBool(battery["BatteryInstalled"]) != false,
              let current = batteryRegistryInt(battery["CurrentCapacity"]),
              let maximum = batteryRegistryInt(battery["MaxCapacity"]),
              maximum > 0
        else {
            return nil
        }

        let data = battery["BatteryData"] as? [String: Any] ?? [:]
        let pack = registry.pack
        let charger = battery["ChargerData"] as? [String: Any] ?? [:]

        percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        isCharging = batteryRegistryBool(battery["IsCharging"]) ?? false
        isPluggedIn = batteryRegistryBool(battery["ExternalConnected"]) ?? false
        isFullyCharged = batteryRegistryBool(battery["FullyCharged"]) ?? false
        timeToFullMinutes = batteryMinutes(battery["AvgTimeToFull"])
        timeToEmptyMinutes = batteryMinutes(battery["AvgTimeToEmpty"])

        // Apple Silicon keeps real mAh under BatteryData; older Macs had them at the top.
        currentCapacityMilliampHours = batteryRegistryInt(data["AppleRawCurrentCapacity"])
            ?? batteryRegistryInt(battery["AppleRawCurrentCapacity"])
        fullChargeCapacityMilliampHours = batteryRegistryInt(data["AppleRawMaxCapacity"])
            ?? batteryRegistryInt(battery["AppleRawMaxCapacity"])
        designCapacityMilliampHours = batteryRegistryInt(data["DesignCapacity"])
            ?? batteryRegistryInt(battery["DesignCapacity"])
        nominalCapacityMilliampHours = batteryRegistryInt(data["NominalChargeCapacity"])
            ?? batteryRegistryInt(battery["NominalChargeCapacity"])
        cycleCount = batteryRegistryInt(battery["CycleCount"])
        designCycleCount = batteryRegistryInt(battery["DesignCycleCount9C"])

        voltage = batteryRegistryInt(battery["Voltage"]).map { Double($0) / 1000 }
        amperage = batteryRegistrySigned(battery["Amperage"] ?? battery["InstantAmperage"]).map { Double($0) / 1000 }

        // Hundredths of a degree, on the pack for Apple Silicon and at the top on Intel.
        temperatureCelsius = (batteryRegistryInt(pack["Temperature"]) ?? batteryRegistryInt(battery["Temperature"]))
            .map { Double($0) / 100 }
        cellVoltages = registry.cellVoltagesMillivolts.map { Double($0) / 1000 }

        if let details = battery["AdapterDetails"] as? [String: Any],
           let watts = batteryRegistryInt(details["Watts"]), watts > 0 {
            adapter = BatteryAdapter(
                watts: watts,
                voltage: batteryRegistryInt(details["AdapterVoltage"]).map { Double($0) / 1000 },
                current: batteryRegistryInt(details["Current"]).map { Double($0) / 1000 },
                description: batteryAdapterDescription(details["Description"] as? String),
                isWireless: batteryRegistryBool(details["IsWireless"]) ?? false
            )
        } else {
            adapter = nil
        }

        // PowerTelemetryData is one consistent reading of where the power goes. Without it,
        // volts times amps still says what the battery is doing.
        if let telemetry = battery["PowerTelemetryData"] as? [String: Any] {
            systemLoadWatts = batteryRegistryInt(telemetry["SystemLoad"]).map { Double($0) / 1000 }
            adapterPowerWatts = batteryRegistryInt(telemetry["SystemPowerIn"]).map { Double($0) / 1000 }
            batteryPowerWatts = batteryRegistrySigned(telemetry["BatteryPower"]).map { Double($0) / 1000 }
        } else {
            systemLoadWatts = nil
            adapterPowerWatts = nil
            batteryPowerWatts = nil
        }
        if batteryPowerWatts == nil, let voltage, let amperage {
            batteryPowerWatts = voltage * amperage
        }

        notChargingReason = batteryRegistryInt(charger["NotChargingReason"]) ?? 0
        slowChargingReason = batteryRegistryInt(charger["SlowChargingReason"]) ?? 0
        thermallyLimitedSeconds = batteryRegistryInt(charger["TimeChargingThermallyLimited"]) ?? 0

        todayLowPercent = batteryRegistryInt(pack["DailyMinSoc"])
        todayHighPercent = batteryRegistryInt(pack["DailyMaxSoc"])
        if let lifetime = pack["LifetimeData"] as? [String: Any],
           let low = batteryRegistryInt(lifetime["MinimumTemperature"]),
           let high = batteryRegistryInt(lifetime["MaximumTemperature"]),
           low <= high {
            lifetimeTemperatureRange = low...high
        } else {
            lifetimeTemperatureRange = nil
        }
        serial = battery["Serial"] as? String
        self.isLowPowerMode = isLowPowerMode
    }

    /// Matches System Settings' "Maximum Capacity", which never goes over 100%.
    var healthPercent: Int? {
        guard let design = designCapacityMilliampHours, design > 0,
              let capacity = nominalCapacityMilliampHours ?? fullChargeCapacityMilliampHours
        else {
            return nil
        }
        return min(100, Int((Double(capacity) / Double(design) * 100).rounded()))
    }

    var watthoursRemaining: Double? {
        guard let mah = currentCapacityMilliampHours, let voltage else { return nil }
        return Double(mah) / 1000 * voltage
    }

    /// macOS's own estimate when it has one, otherwise what the present current works out to.
    var estimatedMinutesToFull: Int? {
        if let timeToFullMinutes { return timeToFullMinutes }
        guard let amperage, amperage > 0.05,
              let current = currentCapacityMilliampHours,
              let full = fullChargeCapacityMilliampHours,
              full > current
        else {
            return nil
        }
        return Int((Double(full - current) / 1000 / amperage * 60).rounded())
    }

    var estimatedMinutesToEmpty: Int? {
        if let timeToEmptyMinutes { return timeToEmptyMinutes }
        guard let amperage, amperage < -0.05, let current = currentCapacityMilliampHours else { return nil }
        return Int((Double(current) / 1000 / -amperage * 60).rounded())
    }
}

func batteryRegistryInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
}

/// IOKit stores signed values like Amperage and BatteryPower as unsigned 64-bit numbers.
func batteryRegistrySigned(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
        return Int(truncatingIfNeeded: number.int64Value)
    }
    return value as? Int
}

func batteryRegistryBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    return (value as? NSNumber)?.boolValue
}

/// 65535 is how the battery says it doesn't have an estimate yet.
private func batteryMinutes(_ value: Any?) -> Int? {
    guard let minutes = batteryRegistryInt(value), minutes > 0, minutes < 65535 else { return nil }
    return minutes
}

private func batteryAdapterDescription(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "pd charger":
        return "USB-C PD"
    case "magsafe", "magsafe 3":
        return "MagSafe"
    default:
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

func batteryAdapterText(_ adapter: BatteryAdapter) -> String {
    var text = "\(adapter.watts) W"
    if let description = adapter.description {
        text += " \(description)"
    }
    if adapter.isWireless {
        text += " (wireless)"
    }
    if let voltage = adapter.voltage, let current = adapter.current, voltage > 0, current > 0 {
        text += ", \(formattedBatteryNumber(voltage)) V at \(formattedBatteryNumber(current)) A"
    }
    return text
}

func formattedBatteryNumber(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    if rounded == rounded.rounded() {
        return String(Int(rounded))
    }
    return String(format: "%g", rounded)
}

func formattedBatteryDuration(minutes: Int) -> String {
    let hours = minutes / 60
    let remaining = minutes % 60
    return hours > 0 ? "\(hours)h \(remaining)m" : "\(remaining)m"
}

func formattedBatteryWatts(_ watts: Double) -> String {
    let magnitude = abs(watts)
    return magnitude >= 10 || magnitude == 0 ? String(format: "%.0f W", magnitude) : String(format: "%.1f W", magnitude)
}

// MARK: - What's going on, in words

enum BatteryPowerState: Equatable {
    case onBattery
    case charging
    case chargerTooWeak
    case onHold
    case full
}

struct BatteryPowerStatus: Equatable {
    let state: BatteryPowerState
    let title: String
    let explanation: String?
    let timeValue: String
    let timeCaption: String
}

func batteryPowerStatus(_ details: BatteryDetails) -> BatteryPowerStatus {
    let batteryWatts = details.batteryPowerWatts ?? (details.amperage ?? 0) * (details.voltage ?? 0)
    let emptyTime = details.estimatedMinutesToEmpty.map(formattedBatteryDuration) ?? "--"

    guard details.isPluggedIn else {
        let explanation = details.systemLoadWatts.map { "The Mac is using \(formattedBatteryWatts($0))." }
            ?? (batteryWatts < 0 ? "Drawing \(formattedBatteryWatts(batteryWatts)) from the battery." : nil)
        return BatteryPowerStatus(
            state: .onBattery,
            title: "On battery",
            explanation: explanation,
            timeValue: emptyTime,
            timeCaption: "until empty"
        )
    }

    if details.isCharging {
        var explanation = details.adapter.map { "\($0.watts) W charger" } ?? "Charging"
        if batteryWatts > 0.5 {
            explanation += ", \(formattedBatteryWatts(batteryWatts)) going into the battery."
        } else {
            explanation += "."
        }
        if details.thermallyLimitedSeconds > 0 {
            explanation += " Slowed down because it's warm."
        }
        return BatteryPowerStatus(
            state: .charging,
            title: "Charging",
            explanation: explanation,
            timeValue: details.estimatedMinutesToFull.map(formattedBatteryDuration) ?? "--",
            timeCaption: "until full"
        )
    }

    if batteryWatts < -1 {
        var explanation = details.adapter.map { "The \($0.watts) W charger can't keep up." } ?? "The charger can't keep up."
        if let load = details.systemLoadWatts {
            explanation += " The Mac is using \(formattedBatteryWatts(load)), so the battery covers the other \(formattedBatteryWatts(batteryWatts))."
        }
        return BatteryPowerStatus(
            state: .chargerTooWeak,
            title: "Plugged in, still draining",
            explanation: explanation,
            timeValue: emptyTime,
            timeCaption: "until empty"
        )
    }

    if details.isFullyCharged || details.percentage >= 100 {
        return BatteryPowerStatus(
            state: .full,
            title: "Fully charged",
            explanation: details.systemLoadWatts.map { "Running on the charger, using \(formattedBatteryWatts($0))." },
            timeValue: "Full",
            timeCaption: "on power"
        )
    }

    return BatteryPowerStatus(
        state: .onHold,
        title: "Plugged in, not charging",
        explanation: "macOS is holding the charge here, usually Optimised Battery Charging or a charge limit.",
        timeValue: "Paused",
        timeCaption: "on power"
    )
}

// MARK: - Reading it

func currentBatteryDetails() -> BatteryDetails? {
    guard let registry = readBatteryRegistry() else { return nil }
    return BatteryDetails(registry: registry, isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
}

private func readBatteryRegistry() -> BatteryRegistryReading? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let battery = batteryRegistryProperties(service) else { return nil }

    var reading = BatteryRegistryReading(battery: battery)
    // Pack and bank data hang below the battery in the service plane on Apple Silicon.
    var iterator: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(
        service,
        kIOServicePlane,
        IOOptionBits(kIORegistryIterateRecursively),
        &iterator
    ) == KERN_SUCCESS else {
        return reading
    }
    defer { IOObjectRelease(iterator) }

    while case let child = IOIteratorNext(iterator), child != 0 {
        defer { IOObjectRelease(child) }
        guard let properties = batteryRegistryProperties(child),
              let data = properties["BatteryData"] as? [String: Any]
        else {
            continue
        }
        if IOObjectConformsTo(child, "AppleSmartBatteryPack") != 0 {
            reading.pack = data
        } else if IOObjectConformsTo(child, "AppleSmartBatteryBank") != 0,
                  let millivolts = batteryRegistryInt(data["CellVoltage"]) {
            reading.cellVoltagesMillivolts.append(millivolts)
        }
    }
    return reading
}

private func batteryRegistryProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dictionary = properties?.takeRetainedValue() as? [String: Any]
    else {
        return nil
    }
    return dictionary
}
