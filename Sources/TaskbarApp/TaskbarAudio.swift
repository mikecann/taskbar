import AppKit
import CoreAudio
import Darwin

// Every now and then an agent left a YouTube video playing and Mike couldn't
// tell where the sound was coming from (20 Nov 2026). So any app sending sound
// to a speaker gets a small speaker on its icon.
//
// macOS 14 lists the processes playing through Core Audio, with no permission
// needed. Browsers play from a helper (Chrome's audio service, WebKit's GPU
// process), so each is credited to the app macOS holds responsible for it.
//
// The usual culprit is BrowserBear's agent browser, which the taskbar leaves
// off (AgentChrome.swift). While it plays it gets a button of its own, and
// since its windows are parked out of sight, clicking it pauses its media.

/// A process sending sound to an output, and the app responsible for it.
struct AudioOutputProcess: Equatable {
    let pid: pid_t
    let responsiblePID: pid_t
}

func taskbarAudioAppPIDs(_ processes: [AudioOutputProcess]) -> Set<pid_t> {
    var pids = Set<pid_t>()
    for process in processes {
        pids.insert(process.pid)
        if process.responsiblePID > 0 { pids.insert(process.responsiblePID) }
    }
    return pids
}

func applyingAudioPlaying(_ pids: Set<pid_t>, to items: [TaskbarItem]) -> [TaskbarItem] {
    items.map { item in
        var item = item
        item.isPlayingAudio = item.pid.map(pids.contains) ?? false
        return item
    }
}

// Private but long-standing; Activity Monitor and most process tools use it.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibilityGetPIDResponsibleForPID(_ pid: pid_t) -> pid_t

/// The apps playing sound right now. Empty before macOS 14.
func collectAudioPlayingPIDs() -> Set<pid_t> {
    guard #available(macOS 14.0, *) else { return [] }
    func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    let system = AudioObjectID(kAudioObjectSystemObject)
    var listAddress = address(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &objects) == noErr else { return [] }

    var playing: [AudioOutputProcess] = []
    for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
        var outputAddress = address(kAudioProcessPropertyIsRunningOutput)
        var isRunningOutput: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &outputAddress, 0, nil, &valueSize, &isRunningOutput) == noErr,
              isRunningOutput != 0 else { continue }
        var pidAddress = address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        valueSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &valueSize, &pid) == noErr, pid > 0 else { continue }
        playing.append(AudioOutputProcess(pid: pid, responsiblePID: responsibilityGetPIDResponsibleForPID(pid)))
    }
    return taskbarAudioAppPIDs(playing)
}

final class TaskbarAudioSampler: TaskbarBackgroundSampler<Set<pid_t>> {
    static let shared = TaskbarAudioSampler()

    init() {
        super.init(initial: [], interval: 1, collect: collectAudioPlayingPIDs)
    }
}

// MARK: - The agent browser's button

/// Buttons for agent browsers playing sound. They sit after everything else,
/// never pinned, labelled so it's plain whose sound it is.
func taskbarAgentAudioItems(_ apps: [TaskbarRunningApp], pausePending: Set<pid_t>) -> [TaskbarItem] {
    apps.map { app in
        var item = TaskbarItem(
            owner: "Agent browser", pid: app.pid, title: "Agent browser", windowCount: 0,
            windowIDs: [], windowBounds: nil, accessibilitySignature: "",
            isFrontmost: false, isMinimized: false,
            bundleID: app.bundleID, appPath: app.appPath,
            isPinned: false, pinOrder: nil
        )
        item.isPlayingAudio = true
        item.isAgentBrowser = true
        item.isAudioPausePending = pausePending.contains(app.pid)
        return item
    }
}

/// How long a click's pause counts as on its way. Chrome and Helium hold the
/// sound output open about 5 seconds after the last media pauses (measured
/// 20 Nov 2026), so it's longer than that; short enough that a pause that
/// didn't land lets Mike click again.
let taskbarAudioPauseWait: TimeInterval = 10

func taskbarPendingAudioPauses(_ requestedAt: [pid_t: TimeInterval], now: TimeInterval) -> Set<pid_t> {
    Set(requestedAt.filter { now - $0.value < taskbarAudioPauseWait }.keys)
}

func remoteDebuggingPort(_ arguments: [String]) -> Int? {
    let prefix = "--remote-debugging-port="
    guard let argument = arguments.last(where: { $0.hasPrefix(prefix) }),
          let port = Int(argument.dropFirst(prefix.count)), port > 0 else { return nil }
    return port
}

/// The DevTools sockets of the agent browser's pages and embedded frames.
/// A YouTube embed is its own frame, out of reach of the page around it.
func devToolsMediaTargets(_ json: Data) throws -> [URL] {
    struct Target: Decodable {
        let type: String
        let webSocketDebuggerUrl: String?
    }
    return try JSONDecoder().decode([Target].self, from: json).compactMap { target in
        guard target.type == "page" || target.type == "iframe",
              let socket = target.webSocketDebuggerUrl else { return nil }
        return URL(string: socket)
    }
}

/// What a pause click got to: how many pages and frames answered, and how
/// many players and Web Audio graphs it stopped.
struct AgentAudioPauseResult: Equatable {
    var reached = 0
    var paused = 0
}

/// The result of a DevTools reply, or nil if it failed or the page threw.
func devToolsResult(_ reply: [String: Any]) -> [String: Any]? {
    guard reply["error"] == nil,
          let result = reply["result"] as? [String: Any],
          result["exceptionDetails"] == nil else { return nil }
    return result
}

/// The page's own JavaScript worlds, one per frame in this process. Same-site
/// iframes share their page's process, so they have no DevTools target of
/// their own. Extension worlds are left alone.
func devToolsPageContextIDs(_ events: [[String: Any]]) -> [Int] {
    events.compactMap { event in
        guard event["method"] as? String == "Runtime.executionContextCreated",
              let context = (event["params"] as? [String: Any])?["context"] as? [String: Any],
              (context["auxData"] as? [String: Any])?["isDefault"] as? Bool == true else { return nil }
        return context["id"] as? Int
    }
}

/// Everything that makes sound: media elements, attached or not
/// (`new Audio()` plays without ever joining the page), and Web Audio graphs.
private let taskbarSoundPrototypes = [
    "HTMLMediaElement.prototype",
    "(globalThis.BaseAudioContext || globalThis.AudioContext).prototype"
]

private let taskbarSilenceFunction = """
function() {
  let n = 0;
  for (const s of this) {
    try {
      if (typeof s.pause === 'function') { if (!s.paused) { s.pause(); n++; } }
      else if (s.state === 'running') { s.suspend(); n++; }
    } catch (e) {}
  }
  return n;
}
"""

/// One DevTools connection, used by one task at a time. Replies are matched
/// to commands by id; events that arrive in between are kept.
private final class DevToolsConnection {
    private let task: URLSessionWebSocketTask
    private var nextID = 0
    private(set) var events: [[String: Any]] = []

    init(_ task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let body: Data
            switch try await task.receive() {
            case .string(let text): body = Data(text.utf8)
            case .data(let data): body = data
            @unknown default: continue
            }
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { continue }
            if message["id"] as? Int == id { return message }
            if message["method"] != nil { events.append(message) }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// Stops the sound in one page or frame target. Nil if it couldn't be reached.
private func silenceDevToolsTarget(_ socket: URL, session: URLSession) async -> Int? {
    let connection = DevToolsConnection(session.webSocketTask(with: socket))
    defer { connection.close() }
    do {
        // Enabling Runtime announces every existing world before it replies.
        guard devToolsResult(try await connection.call("Runtime.enable")) != nil else { return nil }
        var reached = false
        var paused = 0
        for context in devToolsPageContextIDs(connection.events) {
            for prototype in taskbarSoundPrototypes {
                // queryObjects walks the heap for everything built on that
                // prototype, which is how detached players are found.
                guard let found = devToolsResult(try await connection.call("Runtime.evaluate", [
                          "expression": prototype, "contextId": context, "objectGroup": "taskbar"
                      ]))?["result"] as? [String: Any],
                      let prototypeID = found["objectId"] as? String,
                      let objects = devToolsResult(try await connection.call("Runtime.queryObjects", [
                          "prototypeObjectId": prototypeID, "objectGroup": "taskbar"
                      ]))?["objects"] as? [String: Any],
                      let arrayID = objects["objectId"] as? String,
                      let silenced = devToolsResult(try await connection.call("Runtime.callFunctionOn", [
                          "objectId": arrayID, "functionDeclaration": taskbarSilenceFunction, "returnByValue": true
                      ]))?["result"] as? [String: Any]
                else { continue }
                reached = true
                paused += silenced["value"] as? Int ?? 0
            }
        }
        return reached ? paused : nil
    } catch {
        return nil
    }
}

/// Stops every player and Web Audio graph in the agent browser, through the
/// DevTools port BrowserBear started it with.
func pauseAgentBrowserMedia(pid: pid_t) async -> AgentAudioPauseResult {
    guard let port = processArguments(pid: pid).flatMap(remoteDebuggingPort),
          let listURL = URL(string: "http://127.0.0.1:\(port)/json/list") else { return AgentAudioPauseResult() }
    let session = URLSession(configuration: .ephemeral)
    // A page that never answers mustn't hold the click up: cancelling the
    // session ends every wait on it.
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        session.invalidateAndCancel()
    }
    defer {
        watchdog.cancel()
        session.invalidateAndCancel()
    }
    var request = URLRequest(url: listURL)
    request.timeoutInterval = 2
    guard let (data, _) = try? await session.data(for: request),
          let sockets = try? devToolsMediaTargets(data) else { return AgentAudioPauseResult() }
    return await withTaskGroup(of: Int?.self) { group in
        for socket in sockets {
            group.addTask { await silenceDevToolsTarget(socket, session: session) }
        }
        var result = AgentAudioPauseResult()
        for await paused in group {
            guard let paused else { continue }
            result.reached += 1
            result.paused += paused
        }
        return result
    }
}

func pauseAgentBrowserMedia(pid: pid_t, completion: @escaping (AgentAudioPauseResult) -> Void) {
    Task.detached(priority: .utility) {
        let result = await pauseAgentBrowserMedia(pid: pid)
        DispatchQueue.main.async { completion(result) }
    }
}

// MARK: - Drawing

/// The speaker sits on the top-left corner of the icon. The Dock badge owns the
/// top-right, the profile picture the bottom-right and the pin the bottom-left.
func taskbarAudioMarkerRect(in iconRect: NSRect) -> NSRect? {
    guard iconRect.width >= 16 else { return nil }
    let size = (iconRect.width * 0.46).rounded()
    return NSRect(x: iconRect.minX - 2, y: iconRect.maxY + 2 - size, width: size, height: size)
}

func drawTaskbarAudioMarker(for item: TaskbarItem, in iconRect: NSRect) {
    guard item.isPlayingAudio, let rect = taskbarAudioMarkerRect(in: iconRect) else { return }

    // Blue so it catches the eye among the dark pin and red badge.
    let disc = NSBezierPath(ovalIn: rect)
    NSColor.systemBlue.withAlphaComponent(item.isAudioPausePending ? 0.5 : 1).setFill()
    disc.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.45).setStroke()
    disc.lineWidth = 0.75
    disc.stroke()

    let name = item.isAudioPausePending ? "speaker.slash.fill" : "speaker.wave.2.fill"
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.height * 0.5, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Playing sound")?
        .withSymbolConfiguration(configuration) else { return }
    let size = symbol.size
    symbol.draw(in: NSRect(
        x: rect.midX - size.width / 2,
        y: rect.midY - size.height / 2,
        width: size.width,
        height: size.height
    ))
}
