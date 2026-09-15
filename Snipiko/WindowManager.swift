import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()
    @Published var hasScreenPermission = ScreenPermission.isGranted
    @Published var isCapturing = false
    @Published var errorMessage: String?

    func refreshPermission() {
        hasScreenPermission = ScreenPermission.isGranted
    }

    func requestPermission() {
        _ = ScreenPermission.request()
        refreshPermission()
        if hasScreenPermission { WindowManager.shared.showRestartRequired() }
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .captureArea: startCapture { try await CaptureService.shared.captureArea() }
        case .captureDisplay: startCapture { try await CaptureService.shared.captureDisplay() }
        case .captureAllDisplays: startCapture { try await CaptureService.shared.captureAllDisplays() }
        case .captureWindow:
            guard ensurePermission() else { return }
            WindowManager.shared.showWindowPicker()
        case .openHistory: WindowManager.shared.showHistory()
        }
    }

    func capture(window: SCWindow) {
        WindowManager.shared.closeWindowPicker()
        startCapture { try await CaptureService.shared.capture(window: window) }
    }

    func processEditedImage(_ image: CGImage) {
        copyToClipboard(image)
        if let item = HistoryStore.shared.add(image) {
            WindowManager.shared.showPreview(item)
        }
    }

    func copy(_ item: CaptureItem) {
        guard let cgImage = item.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        copyToClipboard(cgImage)
    }

    /// The suggested name comes from the user's template. History file names are
    /// internal identifiers and mean nothing to whoever is picking a folder.
    func save(_ image: CGImage) {
        let settings = AppSettings.shared
        let panel = NSSavePanel()
        panel.nameFieldStringValue = settings.filename(width: image.width, height: image.height)
        panel.allowedContentTypes = [settings.exportFormat.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = ImageExporter.data(for: image, format: settings.exportFormat, jpegQuality: settings.jpegQuality) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func startCapture(_ operation: @escaping () async throws -> CGImage) {
        guard ensurePermission(), !isCapturing else { return }
        isCapturing = true
        Task {
            do {
                let image = try await operation()
                processCapturedImage(image)
            } catch CaptureError.cancelled {
                // Cancellation is an ordinary outcome.
            } catch {
                errorMessage = error.localizedDescription
                WindowManager.shared.showError(error.localizedDescription)
            }
            isCapturing = false
        }
    }

    private func processCapturedImage(_ image: CGImage) {
        CaptureSound.play(AppSettings.shared.captureSound)
        copyToClipboard(image)
        guard let item = HistoryStore.shared.add(image) else {
            WindowManager.shared.showError("Снимок скопирован, но не сохранился в истории.")
            return
        }
        AppSettings.shared.autoSaveImage(image)
        WindowManager.shared.showPreview(item)
    }

    private func copyToClipboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    private func ensurePermission() -> Bool {
        refreshPermission()
        if !hasScreenPermission { WindowManager.shared.showPermission() }
        return hasScreenPermission
    }
}

/// How a window sizes and places itself the first time it opens.
///
/// Absolute point sizes do not travel between displays: 980x680 fills a 1512x982
/// built-in screen but sits in the corner of a 2560x1440 monitor. Each window
/// instead takes a share of whatever screen it opens on, bounded at both ends.
enum WindowPlacement {
    case editor, history, settings, picker, permission

    var autosaveName: String {
        switch self {
        case .editor: "Snipiko.editor"
        case .history: "Snipiko.history"
        case .settings: "Snipiko.settings"
        case .picker: "Snipiko.picker"
        case .permission: "Snipiko.permission"
        }
    }

    /// Share of the target screen's `visibleFrame`.
    var fraction: CGSize {
        switch self {
        case .editor: CGSize(width: 0.80, height: 0.80)
        case .history: CGSize(width: 0.62, height: 0.60)
        case .settings: CGSize(width: 0.52, height: 0.58)
        case .picker: CGSize(width: 0.50, height: 0.52)
        case .permission: CGSize(width: 0, height: 0)
        }
    }

    var minSize: NSSize {
        switch self {
        case .editor: NSSize(width: 680, height: 480)
        case .history: NSSize(width: 620, height: 440)
        case .settings: NSSize(width: 640, height: 480)
        case .picker: NSSize(width: 560, height: 420)
        case .permission: NSSize(width: 480, height: 360)
        }
    }

    var maxSize: NSSize {
        switch self {
        case .editor: NSSize(width: 1800, height: 1150)
        case .history: NSSize(width: 1400, height: 900)
        case .settings: NSSize(width: 1000, height: 760)
        case .picker: NSSize(width: 900, height: 700)
        case .permission: NSSize(width: 480, height: 360)
        }
    }

    /// A plain dialog has nothing to gain from scaling.
    var isFixedSize: Bool { self == .permission }

    func defaultSize(on screen: NSScreen) -> NSSize {
        guard !isFixedSize else { return minSize }
        let visible = screen.visibleFrame.size
        return NSSize(
            width: min(max(visible.width * fraction.width, minSize.width), maxSize.width),
            height: min(max(visible.height * fraction.height, minSize.height), maxSize.height)
        )
    }
}

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var permissionWindow: NSWindowController?
    private var historyWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    private var pickerWindow: NSWindowController?
    private var editorWindows: [UUID: NSWindowController] = [:]
    private var previewPanel: NSPanel?
    private var previewDismissTask: Task<Void, Never>?

    func showPermission() {
        if permissionWindow == nil {
            permissionWindow = makeWindow(
                title: "Доступ к экрану",
                placement: .permission,
                rootView: AnyView(PermissionView())
            )
        }
        show(permissionWindow)
    }

    func showRestartRequired() {
        let alert = NSAlert()
        alert.messageText = "Перезапустите Snipiko"
        alert.informativeText = "macOS применит доступ к записи экрана после перезапуска приложения."
        alert.addButton(withTitle: "Перезапустить")
        alert.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let appURL = Bundle.main.bundleURL
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", appURL.path]
            try? process.run()
            NSApp.terminate(nil)
        }
    }

    func showHistory() {
        if historyWindow == nil {
            historyWindow = makeWindow(title: "История", placement: .history, rootView: AnyView(HistoryView()))
        }
        show(historyWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Настройки", placement: .settings, rootView: AnyView(SettingsView()))
        }
        show(settingsWindow)
    }

    func showWindowPicker() {
        pickerWindow = makeWindow(title: "Выберите окно", placement: .picker, rootView: AnyView(WindowPickerView()))
        show(pickerWindow)
    }

    func closeWindowPicker() {
        pickerWindow?.close()
        pickerWindow = nil
    }

    func showEditor(_ item: CaptureItem) {
        guard let image = item.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let controller = makeWindow(
            title: item.filename,
            placement: .editor,
            rootView: AnyView(EditorView(source: image, filename: item.filename))
        )
        editorWindows[item.id] = controller
        show(controller)
    }

    func showPreview(_ item: CaptureItem) {
        previewDismissTask?.cancel()
        previewPanel?.orderOut(nil)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 238),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Size the panel from the content rather than trusting the contentRect above:
        // assigning a hosting controller resizes the window to whatever SwiftUI asks
        // for, so the position has to be computed from the settled size.
        let hosting = NSHostingController(rootView: CapturePreviewView(item: item))
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)

        // The screen under the pointer, not NSScreen.main -- with no key window that
        // one is the menu bar's screen, which is where the panel used to land no
        // matter which display the shot came from.
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let inset: CGFloat = 18
            // Bottom right, then pulled back inside the screen in case the panel is
            // taller or wider than the gap that leaves.
            let origin = NSPoint(
                x: max(visible.maxX - panel.frame.width - inset, visible.minX + inset),
                y: max(visible.minY + inset, visible.minY)
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        previewPanel = panel
        schedulePreviewDismiss()
    }

    /// Stops the countdown while the pointer is on the panel, so it cannot disappear
    /// mid-drag.
    func holdPreview() {
        previewDismissTask?.cancel()
    }

    func releasePreview() {
        schedulePreviewDismiss()
    }

    private func schedulePreviewDismiss() {
        previewDismissTask?.cancel()
        guard let panel = previewPanel else { return }
        previewDismissTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    func dismissPreview() {
        previewDismissTask?.cancel()
        previewPanel?.orderOut(nil)
    }

    /// Outlines the area just captured and fades the outline out.
    ///
    /// Deliberately an outline and not a wash of colour: it says exactly what was
    /// taken without repainting the screen. `rect` is in global AppKit coordinates.
    func flash(_ rect: CGRect) {
        guard AppSettings.shared.flashOnCapture, rect.width > 2, rect.height > 2 else { return }
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(rect, display: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear

        let outline = NSView(frame: NSRect(origin: .zero, size: rect.size))
        outline.wantsLayer = true
        outline.layer?.borderWidth = 2
        outline.layer?.borderColor = NSColor.white.cgColor
        outline.layer?.cornerRadius = 4
        // A hairline of shadow keeps the outline readable over white content too.
        outline.layer?.shadowColor = NSColor.black.cgColor
        outline.layer?.shadowOpacity = 0.55
        outline.layer?.shadowRadius = 2
        outline.layer?.shadowOffset = .zero
        panel.contentView = outline

        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snipiko"
        alert.informativeText = message
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func makeWindow(title: String, placement: WindowPlacement, rootView: AnyView) -> NSWindowController {
        let screen = Self.screenUnderPointer
        let size = placement.defaultSize(on: screen)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: rootView)
        window.minSize = placement.minSize

        // A frame saved while a monitor was attached can land nowhere once it is
        // unplugged, so a restored frame is only kept if it is still reachable.
        let restored = window.setFrameUsingName(NSWindow.FrameAutosaveName(placement.autosaveName))
        if !restored || !Self.isOnAnyScreen(window.frame) {
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
            window.setFrameOrigin(Self.centeredOrigin(for: size, on: screen))
        }
        window.setFrameAutosaveName(NSWindow.FrameAutosaveName(placement.autosaveName))
        return NSWindowController(window: window)
    }

    /// Windows used to call `center()`, which centres on the screen holding the key
    /// window -- with no key window, the menu bar's screen. On a multi-display setup
    /// that meant every window opened on the built-in display regardless of where
    /// the work was happening.
    static var screenUnderPointer: NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static func centeredOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.minX + (visible.width - size.width) / 2,
            y: visible.minY + (visible.height - size.height) / 2
        )
    }

    /// True when enough of the frame overlaps a screen to be grabbable.
    private static func isOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let shared = screen.visibleFrame.intersection(frame)
            return !shared.isNull && shared.width >= 120 && shared.height >= 60
        }
    }

    private func show(_ controller: NSWindowController?) {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
