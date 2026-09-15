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
            while items.count > 50 {
                let old = items.removeLast()
                try? FileManager.default.removeItem(at: old.url)
            }
            save()
            return item
        } catch {
            return nil
        }
    }

    func delete(_ item: CaptureItem) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for item in items { try? FileManager.default.removeItem(at: item.url) }
        items.removeAll()
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

    func autoSaveImage(_ image: CGImage) {
        guard autoSave, let folder = autoSaveFolder else { return }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let name = "Snipiko-\(HistoryStore.filenameFormatter.string(from: Date())).\(exportFormat.fileExtension)"
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
final class HotKeyManager {
    static let shared = HotKeyManager()
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?

    func registerAll() {
        unregisterAll()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            Task { @MainActor in
                guard let action = ShortcutAction.allCases[safe: Int(hotKeyID.id)] else { return }
                AppController.shared.perform(action)
            }
            return noErr
        }, 1, &eventType, nil, &handler)

        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = AppSettings.shared.shortcuts[action] ?? nil else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534E4950), id: UInt32(index))
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
                refs.append(ref)
            }
        }
    }

    func unregisterAll() {
        refs.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        refs.removeAll()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
