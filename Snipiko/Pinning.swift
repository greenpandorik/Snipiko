import AppKit
import SwiftUI
import Vision

/// A capture pinned on top of everything else.
///
/// The point is to keep a reference in view while working in another app, so the
/// window is deliberately chrome-free: no title bar, drag it anywhere by its body,
/// and it follows across Spaces and full-screen apps.
@MainActor
final class PinnedCaptures {
    static let shared = PinnedCaptures()
    private var panels: [NSPanel] = []

    func pin(_ image: NSImage, at rect: CGRect? = nil) {
        let screen = WindowManager.screenUnderPointer
        let size = Self.fittedSize(for: image.size, on: screen)
        let origin = rect?.origin ?? NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: PinnedCaptureView(image: image) { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            PinnedCaptures.shared.panels.removeAll { $0 === panel }
        })
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    func closeAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    var hasPinned: Bool { !panels.isEmpty }

    /// Shrinks oversized captures to fit, keeping the aspect ratio. A full-screen
    /// shot pinned at full size would cover the screen it is meant to sit beside.
    private static func fittedSize(for imageSize: NSSize, on screen: NSScreen) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return NSSize(width: 320, height: 240) }
        let bounds = screen.visibleFrame.insetBy(dx: 80, dy: 80).size
        let scale = min(1, min(bounds.width / imageSize.width, bounds.height / imageSize.height))
        return NSSize(width: max(120, imageSize.width * scale), height: max(90, imageSize.height * scale))
    }
}

private struct PinnedCaptureView: View {
    let image: NSImage
    let onClose: () -> Void
    @State private var hovering = false
    @State private var opacity = 1.0

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.35)))
            .opacity(opacity)
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 6) {
                        // Fading a pinned capture lets it sit over the thing being
                        // compared against instead of hiding it.
                        Button { opacity = opacity > 0.55 ? 0.45 : 1 } label: {
                            Image(systemName: opacity > 0.55 ? "circle.lefthalf.filled" : "circle.fill")
                        }
                        .help("Полупрозрачность")
                        Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                            .help("Открепить")
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .padding(8)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// Text recognition over a capture, using the on-device Vision engine -- nothing
/// leaves the machine.
enum TextRecognizer {
    static func recognize(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Russian first: the app's own interface is Russian, and Vision needs the
            // language listed explicitly to recognise Cyrillic at all.
            request.recognitionLanguages = ["ru-RU", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Wraps `NSSharingServicePicker`, which has no SwiftUI equivalent that accepts an
/// arbitrary file URL on macOS.
struct SharePicker: NSViewRepresentable {
    @Binding var isPresented: Bool
    let items: [Any]

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard isPresented, !items.isEmpty else { return }
        DispatchQueue.main.async {
            isPresented = false
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}
