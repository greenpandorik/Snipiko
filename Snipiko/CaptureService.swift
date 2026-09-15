import AppKit
import Carbon
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayUnavailable
    case cancelled
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Нет доступа к записи экрана. Разрешите его в Системных настройках."
        case .displayUnavailable: "Не удалось найти экран для снимка."
        case .cancelled: "Снимок отменён."
        case .captureFailed: "Не удалось сделать снимок. Попробуйте ещё раз."
        }
    }
}

enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class CaptureService {
    static let shared = CaptureService()

    func captureDisplay() async throws -> CGImage {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let mainID = NSScreen.main?.displayID,
              let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw CaptureError.displayUnavailable
        }
        return try await captureWhole(display)
    }

    func captureAllDisplays() async throws -> CGImage {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let canvas = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !canvas.isNull else { throw CaptureError.displayUnavailable }
        // Compose at the sharpest scale in use so the Retina display keeps its
        // detail; lower-scale displays are drawn upscaled rather than everything
        // being flattened down to 1x.
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        var shots: [(screen: NSScreen, image: CGImage)] = []
        for display in content.displays {
            guard let screen = screen(for: display) else { continue }
            shots.append((screen, try await captureWhole(display)))
        }
        guard !shots.isEmpty else { throw CaptureError.displayUnavailable }

        guard let context = CGContext(
            data: nil,
            width: Int((canvas.width * scale).rounded()),
            height: Int((canvas.height * scale).rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureError.captureFailed }

        // Displays rarely tile the bounding box exactly; the gaps stay black.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))

        // CGContext and NSScreen both put the origin at the bottom left, so the
        // screen layout maps straight across.
        for shot in shots {
            context.draw(shot.image, in: CGRect(
                x: (shot.screen.frame.minX - canvas.minX) * scale,
                y: (shot.screen.frame.minY - canvas.minY) * scale,
                width: shot.screen.frame.width * scale,
                height: shot.screen.frame.height * scale
            ))
        }

        guard let composed = context.makeImage() else { throw CaptureError.captureFailed }
        return composed
    }

    /// Captures one whole display at its native pixel size.
    ///
    /// `SCDisplay.width`/`height` are in points, so they have to be multiplied by
    /// the screen's backing scale -- otherwise a Retina display is captured at
    /// half its real resolution.
    private func captureWhole(_ display: SCDisplay) async throws -> CGImage {
        let scale = screen(for: display)?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = max(1, Int(CGFloat(display.width) * scale))
        config.height = max(1, Int(CGFloat(display.height) * scale))
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == display.displayID }
    }

    /// Finds the screen a captured window sits on.
    ///
    /// `SCWindow.frame` uses CoreGraphics global coordinates -- origin at the top
    /// left of the primary display, y growing downward -- while `NSScreen.frame`
    /// puts the origin at the bottom left, so the screens have to be flipped
    /// before the two can be compared.
    private func screen(for windowFrame: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        return NSScreen.screens
            .map { screen -> (screen: NSScreen, overlap: CGFloat) in
                let flipped = CGRect(
                    x: screen.frame.minX,
                    y: primary.frame.maxY - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
                let shared = flipped.intersection(windowFrame)
                return (screen, shared.isNull ? 0 : shared.width * shared.height)
            }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .screen
    }

    func captureArea() async throws -> CGImage {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        guard let selection = await AreaSelectionCoordinator.shared.selectArea() else { throw CaptureError.cancelled }
        try await Task.sleep(for: .milliseconds(120))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = selection.screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureError.displayUnavailable
        }

        let screenFrame = selection.screen.frame
        let rect = selection.rect
        let sourceRect = CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let scale = selection.screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func availableWindows() async throws -> [SCWindow] {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter {
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
            $0.frame.width >= 120 && $0.frame.height >= 80 &&
            ($0.title?.isEmpty == false || $0.owningApplication?.applicationName.isEmpty == false)
        }
    }

    func capture(window: SCWindow) async throws -> CGImage {
        let config = SCStreamConfiguration()
        // The scale of the screen the window is actually on, not the main one --
        // otherwise a window on a 1x display is captured at the built-in
        // display's 2x and comes out upscaled.
        let scale = screen(for: window.frame)?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

struct AreaSelection {
    let screen: NSScreen
    let rect: CGRect
}

@MainActor
final class AreaSelectionCoordinator {
    static let shared = AreaSelectionCoordinator()
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<AreaSelection?, Never>?
    private var escapeMonitor: Any?
    func selectArea() async -> AreaSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            NSApp.activate(ignoringOtherApps: true)
            windows = NSScreen.screens.map { screen in
                let view = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.onComplete = { [weak self] localRect in
                    guard let self else { return }
                    let globalRect = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    self.finish(AreaSelection(screen: screen, rect: globalRect))
                }
                // No `screen:` argument here on purpose: when one is passed, AppKit
                // treats contentRect as relative to that screen's origin, so handing
                // it the already-global screen.frame doubles the offset and the
                // overlay lands off the display it belongs to.
                let window = OverlayWindow(
                    contentRect: screen.frame,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                window.setFrame(screen.frame, display: false)
                window.level = .screenSaver
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = false
                window.ignoresMouseEvents = false
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.acceptsMouseMovedEvents = true
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                return window
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == UInt16(kVK_Escape) { self?.finish(nil); return nil }
                return event
            }
        }
    }

    private func finish(_ result: AreaSelection?) {
        NSCursor.arrow.set()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// A borderless `NSWindow` refuses to become key, which leaves the app with no key
/// window at all -- and cursor rects, `cursorUpdate` and key events all run off the
/// key window. Without this the overlay can never show a crosshair or catch Escape.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class AreaSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var hover: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    // Not resetCursorRects(): those apply only to the key window, and just one of
    // the per-screen overlays can be key, so the rest would keep the arrow. Setting
    // the cursor here also survives AppKit resetting it on every mouse move.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        claimCursor()
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        claimCursor()
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    /// Only one window can be key, so the overlay the pointer is currently over has
    /// to take that role -- otherwise the crosshair would appear on one screen only.
    private func claimCursor() {
        if window?.isKeyWindow == false { window?.makeKey() }
        NSCursor.crosshair.set()
    }

    // Without this the badge would stay frozen on whichever screen the pointer left.
    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        hover = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        let rect = selectionRect.integral.intersection(bounds)
        if rect.width >= 4, rect.height >= 4 { onComplete?(rect) }
        else { start = nil; current = nil; needsDisplay = true }
    }

    private var selectionRect: CGRect {
        guard let start, let current else { return .zero }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = selectionRect
        NSColor.black.withAlphaComponent(0.34).setFill()
        guard !rect.isEmpty else {
            bounds.fill()
            drawHint()
            drawCoordinates()
            return
        }

        let dimmingPath = NSBezierPath(rect: bounds)
        dimmingPath.appendRect(rect)
        dimmingPath.windingRule = .evenOdd
        dimmingPath.fill()

        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        drawSize(for: rect)
        drawCoordinates()
    }

    /// Badge that follows the pointer, showing where it is on this screen.
    ///
    /// Reported with the origin at the top-left corner, which is how the resulting
    /// image is addressed -- the view itself is unflipped, so y is inverted here.
    private func drawCoordinates() {
        guard let hover else { return }
        let text = "\(Int(hover.x)), \(Int(bounds.height - hover.y))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        var box = CGRect(x: hover.x + 16, y: hover.y - 16 - 24, width: size.width + 16, height: 24)
        // Keep it on screen when the pointer nears an edge.
        if box.maxX > bounds.maxX - 4 { box.origin.x = hover.x - 16 - box.width }
        if box.minY < 4 { box.origin.y = hover.y + 16 }
        if box.maxY > bounds.maxY - 4 { box.origin.y = hover.y - 16 - box.height }
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 5), withAttributes: attrs)
    }

    private func drawHint() {
        let text = "Потяните, чтобы выбрать область  ·  Esc — отмена"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 13, y: bounds.midY - 18, width: size.width + 26, height: 36)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: box.minX + 13, y: box.minY + 10), withAttributes: attrs)
    }

    private func drawSize(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        var box = CGRect(x: rect.minX, y: rect.minY - 28, width: size.width + 16, height: 24)
        if box.minY < 4 { box.origin.y = rect.maxY + 4 }
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 5), withAttributes: attrs)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
