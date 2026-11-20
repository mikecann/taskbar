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

/// Pauses every video and audio element in the agent browser, through the
/// DevTools port BrowserBear started it with. Calls back on the main queue
/// with how many pages and frames it reached.
func pauseAgentBrowserMedia(pid: pid_t, completion: @escaping (Int) -> Void) {
    let finish: (Int) -> Void = { count in DispatchQueue.main.async { completion(count) } }
    guard let port = processArguments(pid: pid).flatMap(remoteDebuggingPort),
          let listURL = URL(string: "http://127.0.0.1:\(port)/json/list") else {
        finish(0)
        return
    }
    let session = URLSession(configuration: .ephemeral)
    var request = URLRequest(url: listURL)
    request.timeoutInterval = 2
    session.dataTask(with: request) { data, _, _ in
        guard let data, let sockets = try? devToolsMediaTargets(data), !sockets.isEmpty else {
            session.invalidateAndCancel()
            finish(0)
            return
        }
        // URLSession answers on its own queue, so wait for the sockets elsewhere.
        DispatchQueue.global(qos: .utility).async {
            let message = #"{"id":1,"method":"Runtime.evaluate","params":{"expression":"document.querySelectorAll('video,audio').forEach(m=>m.pause())"}}"#
            let group = DispatchGroup()
            let lock = NSLock()
            var reached = 0
            for socket in sockets {
                group.enter()
                let task = session.webSocketTask(with: socket)
                task.resume()
                task.send(.string(message)) { error in
                    guard error == nil else {
                        task.cancel()
                        group.leave()
                        return
                    }
                    // Wait for the reply so the page has run it before we hang up.
                    task.receive { result in
                        if case .success = result {
                            lock.lock()
                            reached += 1
                            lock.unlock()
                        }
                        task.cancel(with: .normalClosure, reason: nil)
                        group.leave()
                    }
                }
            }
            if group.wait(timeout: .now() + 3) == .timedOut {
                log("agent browser pause: some pages didn't answer in time")
            }
            session.invalidateAndCancel()
            lock.lock()
            let count = reached
            lock.unlock()
            finish(count)
        }
    }.resume()
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
