import AppKit

// Chrome runs every profile in one process, so its windows all look the same
// on the taskbar. When more than one profile exists, Chrome ends each window's
// accessibility title with the profile, e.g.
// "Inbox - Google Chrome – Michael (cannstudios.com)". That is enough to find
// the profile's Google picture and draw it on the window's icon.

private let chromeUserDataDirectories: [String: String] = [
    "com.google.Chrome": "Google/Chrome",
    "com.google.Chrome.beta": "Google/Chrome Beta",
    "com.google.Chrome.dev": "Google/Chrome Dev",
    "com.google.Chrome.canary": "Google/Chrome Canary"
]

func chromeUserDataDirectoryName(bundleID: String) -> String? {
    chromeUserDataDirectories[bundleID]
}

/// The profile Chrome appends to a window's accessibility title, or nil when
/// the window isn't Chrome's or Chrome didn't add one (a single profile).
func chromeWindowProfileName(accessibilityTitle: String, bundleID: String) -> String? {
    guard chromeUserDataDirectoryName(bundleID: bundleID) != nil else { return nil }
    // Tab titles can contain " – " too (" – Pinned", say), so anchor on the
    // last "Google Chrome" (with an optional channel word) before the en dash.
    guard let match = accessibilityTitle.range(
        of: #"Google Chrome(?: (?:Beta|Dev|Canary))? – (.+)$"#,
        options: [.regularExpression, .backwards]
    ) else { return nil }
    let suffix = accessibilityTitle[match]
    guard let dash = suffix.range(of: " \u{2013} ") else { return nil }
    let name = suffix[dash.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

struct ChromeProfileEntry: Equatable {
    let directory: String
    let name: String
    let givenName: String
    let pictureFileName: String?
}

func parseChromeLocalState(_ data: Data) -> [ChromeProfileEntry] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let profile = root["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: [String: Any]]
    else { return [] }
    return cache.map { directory, info in
        let picture = (info["gaia_picture_file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ChromeProfileEntry(
            directory: directory,
            name: info["name"] as? String ?? "",
            givenName: info["gaia_given_name"] as? String ?? "",
            pictureFileName: picture
        )
    }
    .sorted { $0.directory < $1.directory }
}

/// Chrome shows a signed-in profile as "Given (Profile name)", or just the
/// profile name when the two are the same.
func matchChromeProfile(windowProfile: String, in entries: [ChromeProfileEntry]) -> ChromeProfileEntry? {
    if let entry = entries.first(where: { !$0.givenName.isEmpty && "\($0.givenName) (\($0.name))" == windowProfile }) {
        return entry
    }
    return entries.first { $0.name == windowProfile }
}

struct TaskbarProfileBadge: Equatable {
    let initial: String
    let picturePath: String?
    // Part of equality so the taskbar redraws once the picture has loaded.
    let pictureReady: Bool
}

final class ChromeProfileStore {
    static let shared = ChromeProfileStore()

    private let applicationSupport: URL
    private let readData: (URL) -> Data?
    private let modificationDate: (URL) -> Date?
    private let loadPicture: (String) -> CGImage?
    private let schedule: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var localStates: [String: (modified: Date?, entries: [ChromeProfileEntry], checkedAt: Date)] = [:]
    private var pictures: [String: CGImage] = [:]
    private var loadingPictures: Set<String> = []
    private var failedPictures: Set<String> = []
    var onChange: (() -> Void)?

    init(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        readData: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) },
        modificationDate: @escaping (URL) -> Date? = { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        },
        loadPicture: @escaping (String) -> CGImage? = ChromeProfileStore.loadPicture(at:),
        schedule: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.applicationSupport = applicationSupport
        self.readData = readData
        self.modificationDate = modificationDate
        self.loadPicture = loadPicture
        self.schedule = schedule
    }

    func badge(windowProfile: String, bundleID: String, now: Date = Date()) -> TaskbarProfileBadge? {
        guard let userData = chromeUserDataDirectoryName(bundleID: bundleID) else { return nil }
        let userDataURL = applicationSupport.appendingPathComponent(userData, isDirectory: true)
        let entry = matchChromeProfile(windowProfile: windowProfile, in: entries(userDataURL: userDataURL, now: now))
        let initial = String((entry?.name ?? windowProfile).prefix(1)).uppercased()
        guard let entry, let pictureFileName = entry.pictureFileName else {
            return TaskbarProfileBadge(initial: initial, picturePath: nil, pictureReady: false)
        }
        let path = userDataURL
            .appendingPathComponent(entry.directory, isDirectory: true)
            .appendingPathComponent(pictureFileName)
            .path
        return TaskbarProfileBadge(initial: initial, picturePath: path, pictureReady: picture(at: path) != nil)
    }

    func picture(at path: String) -> CGImage? {
        lock.lock()
        if let image = pictures[path] {
            lock.unlock()
            return image
        }
        let shouldLoad = !loadingPictures.contains(path) && !failedPictures.contains(path)
        if shouldLoad { loadingPictures.insert(path) }
        lock.unlock()

        if shouldLoad {
            // Decoding a PNG is too slow for the refresh or a draw pass.
            schedule { [weak self] in
                guard let self else { return }
                let image = self.loadPicture(path)
                self.lock.lock()
                self.loadingPictures.remove(path)
                if let image { self.pictures[path] = image } else { self.failedPictures.insert(path) }
                self.lock.unlock()
                if image != nil {
                    DispatchQueue.main.async { [weak self] in self?.onChange?() }
                }
            }
        }
        return nil
    }

    // Local State is small, but Chrome rewrites it often. Only look at its
    // modification date every few seconds and reparse when it changed.
    private func entries(userDataURL: URL, now: Date) -> [ChromeProfileEntry] {
        let key = userDataURL.path
        lock.lock()
        if let cached = localStates[key], now.timeIntervalSince(cached.checkedAt) < 10 {
            lock.unlock()
            return cached.entries
        }
        lock.unlock()

        let localState = userDataURL.appendingPathComponent("Local State")
        let modified = modificationDate(localState)
        lock.lock()
        if let cached = localStates[key], cached.modified == modified {
            localStates[key] = (modified, cached.entries, now)
            lock.unlock()
            return cached.entries
        }
        lock.unlock()

        let entries = readData(localState).map(parseChromeLocalState) ?? []
        lock.lock()
        // A changed profile picture keeps its file name, so drop cached images.
        if localStates[key] != nil { pictures = pictures.filter { !$0.key.hasPrefix(key) } }
        failedPictures = failedPictures.filter { !$0.hasPrefix(key) }
        localStates[key] = (modified, entries, now)
        lock.unlock()
        return entries
    }

    private static func loadPicture(at path: String) -> CGImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var rect = NSRect(origin: .zero, size: NSSize(width: 64, height: 64))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

func applyingChromeProfiles(to items: [TaskbarItem], store: ChromeProfileStore = .shared) -> [TaskbarItem] {
    items.map { item in
        guard let profile = item.browserProfileName else { return item }
        var item = item
        item.profileBadge = store.badge(windowProfile: profile, bundleID: item.bundleID)
        return item
    }
}

/// The bottom-right corner of the icon. The Dock badge owns the top-right and
/// the pin the bottom-left, so all three can show at once.
func taskbarProfileBadgeRect(in iconRect: NSRect) -> NSRect? {
    guard iconRect.width >= 16 else { return nil }
    let size = (iconRect.width * 0.5).rounded()
    return NSRect(x: iconRect.maxX - size + 2, y: iconRect.minY - 2, width: size, height: size)
}

func drawTaskbarProfileBadge(_ badge: TaskbarProfileBadge?, in iconRect: NSRect, store: ChromeProfileStore = .shared) {
    guard let badge, let rect = taskbarProfileBadgeRect(in: iconRect),
          let context = NSGraphicsContext.current?.cgContext else { return }
    let disc = NSBezierPath(ovalIn: rect)

    if let path = badge.picturePath, let picture = store.picture(at: path) {
        context.saveGState()
        disc.addClip()
        context.interpolationQuality = .high
        context.draw(picture, in: rect)
        context.restoreGState()
    } else {
        // No Google picture (a profile that isn't signed in): use its initial.
        NSColor(calibratedWhite: 0.30, alpha: 1.0).setFill()
        disc.fill()
        let font = NSFont.systemFont(ofSize: rect.height * 0.6, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (badge.initial as NSString).size(withAttributes: attributes)
        (badge.initial as NSString).draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    // A dark edge, like the pin's, separates the face from the Chrome icon on
    // both the dark bar and the light selected tile.
    NSColor(calibratedWhite: 0.12, alpha: 0.9).setStroke()
    disc.lineWidth = 1
    disc.stroke()
}
