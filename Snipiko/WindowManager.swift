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

    func save(_ image: CGImage, suggestedName: String = "Snipiko.png") {
        let settings = AppSettings.shared
        let panel = NSSavePanel()
        let base = (suggestedName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(settings.exportFormat.fileExtension)"
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
                size: NSSize(width: 480, height: 360),
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
            historyWindow = makeWindow(title: "История", size: NSSize(width: 720, height: 510), rootView: AnyView(HistoryView()))
        }
        show(historyWindow)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Настройки", size: NSSize(width: 590, height: 470), rootView: AnyView(SettingsView()))
        }
        show(settingsWindow)
    }

    func showWindowPicker() {
        pickerWindow = makeWindow(title: "Выберите окно", size: NSSize(width: 590, height: 460), rootView: AnyView(WindowPickerView()))
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
            size: NSSize(width: 980, height: 680),
            rootView: AnyView(EditorView(source: image, filename: item.filename))
        )
        controller.window?.minSize = NSSize(width: 680, height: 480)
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

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snipiko"
        alert.informativeText = message
        alert.addButton(withTitle: "Понятно")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func makeWindow(title: String, size: NSSize, rootView: AnyView) -> NSWindowController {
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
        window.center()
        return NSWindowController(window: window)
    }

    private func show(_ controller: NSWindowController?) {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
