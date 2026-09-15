import AppKit
import Carbon
import CoreGraphics
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

struct CaptureItem: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let filename: String
    let width: Int
    let height: Int
    /// Favourites survive the history limit and are never trimmed automatically.
    /// Decoded with a default so histories written before this existed still load.
    var isFavourite = false

    var url: URL { HistoryStore.capturesDirectoryURL.appendingPathComponent(filename) }
    var image: NSImage? { NSImage(contentsOf: url) }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    nonisolated static let capturesDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Snipiko/Captures", isDirectory: true)
    @Published private(set) var items: [CaptureItem] = []

    let capturesDirectory: URL
    private let indexURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        capturesDirectory = Self.capturesDirectoryURL
        indexURL = support.appendingPathComponent("Snipiko/history.json")
        try? FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true)
        load()
    }

    @discardableResult
    func add(_ image: CGImage) -> CaptureItem? {
        let id = UUID()
        let filename = "Snipiko-\(Self.filenameFormatter.string(from: Date()))-\(id.uuidString.prefix(6)).png"
        let item = CaptureItem(id: id, createdAt: Date(), filename: filename, width: image.width, height: image.height)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: item.url, options: .atomic)
            items.insert(item, at: 0)
            trim()
            save()
            return item
        } catch {
            return nil
        }
    }

    /// Drops the oldest ordinary captures past the limit. Favourites are skipped
    /// entirely, so marking one is a promise that it stays.
    private func trim() {
        let limit = AppSettings.shared.historyLimit
        var ordinary = items.filter { !$0.isFavourite }.count
        guard ordinary > limit else { return }
        for item in items.reversed() where ordinary > limit {
            guard !item.isFavourite else { continue }
            try? FileManager.default.removeItem(at: item.url)
            items.removeAll { $0.id == item.id }
            ordinary -= 1
        }
    }

    func setFavourite(_ isFavourite: Bool, for item: CaptureItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavourite = isFavourite
        if !isFavourite { trim() }
        save()
    }

    /// Applies the limit after it is changed in Settings.
    func applyHistoryLimit() {
        trim()
        save()
    }

    func delete(_ item: CaptureItem) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Clears everything except favourites -- losing a deliberately kept capture to
    /// a single button would be the worst kind of surprise.
    func clear() {
        for item in items where !item.isFavourite {
            try? FileManager.default.removeItem(at: item.url)
        }
        items.removeAll { !$0.isFavourite }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([CaptureItem].self, from: data) else { return }
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return formatter
    }()
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let captureArea = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey))

    var displayValue: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        value += KeyName.name(for: keyCode)
        return value
    }
}

/// Shortcuts macOS claims for itself, for warning before a combination is assigned.
///
/// The list is static by necessity. Snipiko is sandboxed, and the real table in
/// `com.apple.symbolichotkeys` is unreachable from inside a container -- verified
/// that `UserDefaults(suiteName:)`, `CFPreferencesCopyAppValue` and reading the
/// plist directly all come back empty, because the home directory is redirected.
///
/// So this warns about the common cases and cannot know about combinations the
/// user has remapped, nor about other applications. It never blocks an
/// assignment; `HotKeyManager.probe(_:)` is what actually settles the question.
enum SystemShortcuts {
    private struct Known {
        let keyCode: Int
        let modifiers: Int
        let owner: String
    }

    private static let known: [Known] = [
        Known(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey, owner: "снимком всего экрана"),
        Known(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey | controlKey, owner: "снимком экрана в буфер"),
        Known(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey, owner: "снимком области"),
        Known(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey | controlKey, owner: "снимком области в буфер"),
        Known(keyCode: kVK_ANSI_5, modifiers: cmdKey | shiftKey, owner: "панелью съёмки экрана"),
        Known(keyCode: kVK_Space, modifiers: cmdKey, owner: "Spotlight"),
        Known(keyCode: kVK_Space, modifiers: controlKey, owner: "сменой раскладки"),
        Known(keyCode: kVK_Tab, modifiers: cmdKey, owner: "переключением программ"),
        Known(keyCode: kVK_ANSI_Q, modifiers: cmdKey, owner: "выходом из программы"),
        Known(keyCode: kVK_ANSI_W, modifiers: cmdKey, owner: "закрытием окна")
    ]

    /// What macOS uses this combination for, or nil when it looks free.
    static func owner(of shortcut: Shortcut) -> String? {
        known.first {
            UInt32($0.keyCode) == shortcut.keyCode && UInt32($0.modifiers) == shortcut.modifiers
        }?.owner
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    // New cases go at the end: HotKeyManager derives hot-key ids from this order.
    case captureArea, captureWindow, captureDisplay, openHistory, captureAllDisplays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .captureArea: "Снять область"
        case .captureWindow: "Снять окно"
        case .captureDisplay: "Снять экран"
        case .openHistory: "Открыть историю"
        case .captureAllDisplays: "Снять все экраны"
        }
    }
}

/// Per-tool colour and stroke width for the annotation editor, kept across launches.
///
/// Colours are stored as sRGB components rather than archived `NSColor`s so the
/// defaults stay readable and survive any future change of colour space handling.
enum AnnotationStyle {
    static let widths: [CGFloat] = [2, 3, 5, 8]

    static func defaultColor(for tool: EditorTool) -> NSColor {
        tool == .highlight ? .systemYellow : .systemRed
    }

    static func color(for tool: EditorTool) -> NSColor {
        guard let parts = UserDefaults.standard.array(forKey: colorKey(tool)) as? [Double],
              parts.count == 4 else { return defaultColor(for: tool) }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }

    static func setColor(_ color: NSColor, for tool: EditorTool) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        UserDefaults.standard.set(
            [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent],
            forKey: colorKey(tool)
        )
    }

    static func width(for tool: EditorTool) -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: widthKey(tool))
        return stored > 0 ? CGFloat(stored) : 3
    }

    static func setWidth(_ width: CGFloat, for tool: EditorTool) {
        UserDefaults.standard.set(Double(width), forKey: widthKey(tool))
    }

    /// What a stroke of this width actually measures on the image. The marker is
    /// drawn far thicker than the nominal value, so showing the raw number would
    /// misreport it.
    static func effectiveWidth(_ width: CGFloat, for tool: EditorTool) -> CGFloat {
        tool == .highlight ? max(16, width * 6) : width
    }

    private static func colorKey(_ tool: EditorTool) -> String { "annotationColor.\(tool.rawValue)" }
    private static func widthKey(_ tool: EditorTool) -> String { "annotationWidth.\(tool.rawValue)" }
}

/// Stock sounds usable as a shutter click.
enum CaptureSound {
    static let defaultName = "Tink"

    /// Names of the sounds shipped in /System/Library/Sounds, as `NSSound(named:)`
    /// expects them. Read from disk rather than hardcoded, since the set differs
    /// between macOS releases.
    static let available: [String] = {
        let directory = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()

    static func play(_ name: String?) {
        guard let name, let sound = NSSound(named: name) else { return }
        sound.stop()
        sound.play()
    }
}

/// Pattern for naming saved files.
enum FilenameTemplate {
    static let `default` = "Snipiko-{date}-{time}"

    /// Token, what it produces, shown in Settings so the syntax is discoverable.
    static let tokens: [(token: String, meaning: String)] = [
        ("{date}", "дата, 2026-09-16"),
        ("{time}", "время, 14.05.33"),
        ("{width}", "ширина в пикселях"),
        ("{height}", "высота в пикселях"),
        ("{n}", "счётчик, растёт с каждым снимком")
    ]

    /// Fills the template. Anything a file name cannot contain is replaced, and an
    /// empty result falls back to the default, so a template cannot produce an
    /// unopenable file.
    static func filename(_ template: String, width: Int, height: Int, date: Date = Date(), counter: Int) -> String {
        let filled = template
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: date))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: date))
            .replacingOccurrences(of: "{width}", with: String(width))
            .replacingOccurrences(of: "{height}", with: String(height))
            .replacingOccurrences(of: "{n}", with: String(counter))

        let cleaned = filled
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Snipiko" : cleaned
    }

    /// A monotonically growing number for `{n}`, kept across launches.
    static func nextCounter() -> Int {
        let next = UserDefaults.standard.integer(forKey: "filenameCounter") + 1
        UserDefaults.standard.set(next, forKey: "filenameCounter")
        return next
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH.mm.ss"
        return formatter
    }()
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var contentType: UTType { self == .png ? .png : .jpeg }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var shortcuts: [ShortcutAction: Shortcut?] = [:] { didSet { persistShortcuts() } }
    @Published var launchAtLogin = false
    @Published var exportFormat: ExportFormat = .png { didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: "exportFormat") } }
    @Published var jpegQuality: Double = 0.9 { didSet { UserDefaults.standard.set(jpegQuality, forKey: "jpegQuality") } }
    @Published var autoSave = false { didSet { UserDefaults.standard.set(autoSave, forKey: "autoSave") } }
    @Published private(set) var autoSaveFolder: URL?
    @Published var includeCursor = false { didSet { UserDefaults.standard.set(includeCursor, forKey: "includeCursor") } }
    @Published var flashOnCapture = true { didSet { UserDefaults.standard.set(flashOnCapture, forKey: "flashOnCapture") } }
    /// Name of a sound in /System/Library/Sounds, or nil for silence. The shutter
    /// sound macOS itself uses lives inside the system Screenshot app and is not
    /// reachable from a sandboxed process, so one of the stock sounds stands in.
    @Published var captureSound: String? = CaptureSound.defaultName {
        didSet { UserDefaults.standard.set(captureSound, forKey: "captureSound") }
    }
    @Published var filenameTemplate = FilenameTemplate.default {
        didSet { UserDefaults.standard.set(filenameTemplate, forKey: "filenameTemplate") }
    }
    /// How many non-favourite captures the history keeps.
    @Published var historyLimit = 50 {
        didSet { UserDefaults.standard.set(historyLimit, forKey: "historyLimit") }
    }

    private init() {
        shortcuts[.captureArea] = .captureArea
        shortcuts[.captureWindow] = nil
        shortcuts[.captureDisplay] = nil
        shortcuts[.openHistory] = nil
        shortcuts[.captureAllDisplays] = nil
        if let data = UserDefaults.standard.data(forKey: "shortcuts"),
           let decoded = try? JSONDecoder().decode([String: Shortcut?].self, from: data) {
            for (key, value) in decoded where ShortcutAction(rawValue: key) != nil {
                shortcuts[ShortcutAction(rawValue: key)!] = value
            }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if let raw = UserDefaults.standard.string(forKey: "exportFormat"), let format = ExportFormat(rawValue: raw) { exportFormat = format }
        if UserDefaults.standard.object(forKey: "jpegQuality") != nil { jpegQuality = UserDefaults.standard.double(forKey: "jpegQuality") }
        autoSave = UserDefaults.standard.bool(forKey: "autoSave")
        includeCursor = UserDefaults.standard.bool(forKey: "includeCursor")
        if UserDefaults.standard.object(forKey: "flashOnCapture") != nil {
            flashOnCapture = UserDefaults.standard.bool(forKey: "flashOnCapture")
        }
        if UserDefaults.standard.object(forKey: "captureSound") != nil {
            captureSound = UserDefaults.standard.string(forKey: "captureSound")
        }
        if let stored = UserDefaults.standard.string(forKey: "filenameTemplate"), !stored.isEmpty {
            filenameTemplate = stored
        }
        let storedLimit = UserDefaults.standard.integer(forKey: "historyLimit")
        if storedLimit > 0 { historyLimit = storedLimit }
        restoreAutoSaveFolder()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func resetShortcuts() {
        shortcuts = [.captureArea: .captureArea, .captureWindow: nil, .captureDisplay: nil,
                     .openHistory: nil, .captureAllDisplays: nil]
    }

    func chooseAutoSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: "autoSaveFolderBookmark")
            autoSaveFolder = url
        } catch { autoSaveFolder = nil }
    }

    /// Name for a saved file, from the user's template.
    func filename(width: Int, height: Int) -> String {
        let base = FilenameTemplate.filename(
            filenameTemplate, width: width, height: height, counter: FilenameTemplate.nextCounter()
        )
        return "\(base).\(exportFormat.fileExtension)"
    }

    func autoSaveImage(_ image: CGImage) {
        guard autoSave, let folder = autoSaveFolder else { return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let name = filename(width: image.width, height: image.height)
        let url = folder.appendingPathComponent(name)
        if let data = ImageExporter.data(for: image, format: exportFormat, jpegQuality: jpegQuality) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func persistShortcuts() {
        let mapped = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(mapped) { UserDefaults.standard.set(data, forKey: "shortcuts") }
    }

    private func restoreAutoSaveFolder() {
        guard let data = UserDefaults.standard.data(forKey: "autoSaveFolderBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
            autoSaveFolder = url
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: "autoSaveFolderBookmark")
            }
        }
    }
}

enum ImageExporter {
    static func data(for image: CGImage, format: ExportFormat, jpegQuality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        }
    }
}

enum KeyName {
    static func name(for code: UInt32) -> String {
        let names: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z", UInt32(kVK_ANSI_0): "0",
            UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_Space): "Space"
        ]
        return names[code] ?? "Key \(code)"
    }
}

@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    /// Actions whose shortcut could not be registered. Previously the failure was
    /// dropped on the floor, so a shortcut could sit in Settings looking assigned
    /// while never firing.
    @Published private(set) var failedRegistrations: Set<ShortcutAction> = []

    /// While a shortcut is being tested, firing it records the hit instead of
    /// running the action -- otherwise testing the area-capture shortcut would take
    /// a screenshot on every press.
    private var probedAction: ShortcutAction?
    private var probeHit = false

    func registerAll() {
        unregisterAll()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            Task { @MainActor in
                guard let action = ShortcutAction.allCases[safe: Int(hotKeyID.id)] else { return }
                HotKeyManager.shared.handleFire(of: action)
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        var failures: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = AppSettings.shared.shortcuts[action] ?? nil else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534E4950), id: UInt32(index))
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
                refs.append(ref)
            } else {
                failures.insert(action)
            }
        }
        failedRegistrations = failures
    }

    private func handleFire(of action: ShortcutAction) {
        if probedAction == action {
            probeHit = true
            return
        }
        AppController.shared.perform(action)
    }

    /// Presses the shortcut for `action` reach Snipiko?
    ///
    /// `RegisterEventHotKey` reports success even for combinations macOS itself
    /// owns -- verified on macOS 26.4 with Shift-Cmd-3/4/5 -- so the only reliable
    /// answer comes from asking the user to press it and seeing whether it arrives.
    func probe(_ action: ShortcutAction, timeout: Duration = .seconds(5)) async -> Bool {
        probedAction = action
        probeHit = false
        defer { probedAction = nil }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if probeHit { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return probeHit
    }

    func unregisterAll() {
        refs.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        refs.removeAll()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
