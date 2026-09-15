import AppKit
import CoreGraphics
import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, text, highlight, redact, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: "Выбор"
        case .arrow: "Стрелка"
        case .rectangle: "Рамка"
        case .text: "Текст"
        case .highlight: "Маркер"
        case .redact: "Скрыть"
        case .crop: "Обрезать"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .redact: "eye.slash"
        case .crop: "crop"
        }
    }
}

enum Annotation: Identifiable {
    case arrow(id: UUID, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case rectangle(id: UUID, rect: CGRect, color: NSColor, width: CGFloat)
    case highlight(id: UUID, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat)
    case redact(id: UUID, rect: CGRect)
    case text(id: UUID, point: CGPoint, text: String, color: NSColor)

    var id: UUID {
        switch self {
        case let .arrow(id, _, _, _, _), let .rectangle(id, _, _, _), let .highlight(id, _, _, _, _),
             let .redact(id, _), let .text(id, _, _, _): id
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var image: CGImage
    @Published var annotations: [Annotation] = []
    @Published var tool: EditorTool = .arrow
    private var redoStack: [Annotation] = []

    /// Bumped whenever a stored style changes, so SwiftUI redraws the toolbar --
    /// `color` and `lineWidth` read through to `AnnotationStyle` and cannot be
    /// `@Published` themselves.
    @Published private var styleRevision = 0

    /// Colour and width belong to the selected tool, so switching back to the arrow
    /// brings back the arrow's colour rather than whatever the marker was last set to.
    var color: NSColor {
        get { AnnotationStyle.color(for: tool) }
        set { AnnotationStyle.setColor(newValue, for: tool); styleRevision += 1 }
    }

    var lineWidth: CGFloat {
        get { AnnotationStyle.width(for: tool) }
        set { AnnotationStyle.setWidth(newValue, for: tool); styleRevision += 1 }
    }

    init(image: CGImage) { self.image = image }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
    }

    func undo() {
        guard let annotation = annotations.popLast() else { return }
        redoStack.append(annotation)
    }

    func redo() {
        guard let annotation = redoStack.popLast() else { return }
        annotations.append(annotation)
    }

    func crop(to normalized: CGRect) {
        let rect = normalized.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard rect.width > 0.02, rect.height > 0.02 else { return }
        let pixelRect = CGRect(
            x: rect.minX * CGFloat(image.width),
            y: rect.minY * CGFloat(image.height),
            width: rect.width * CGFloat(image.width),
            height: rect.height * CGFloat(image.height)
        ).integral
        if let cropped = image.cropping(to: pixelRect) {
            image = cropped
            annotations.removeAll()
            redoStack.removeAll()
            tool = .arrow
        }
    }

    func renderedImage() -> CGImage? {
        let size = NSSize(width: image.width, height: image.height)
        let output = NSImage(size: size)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
        for annotation in annotations { draw(annotation, size: size) }
        output.unlockFocus()
        return output.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func draw(_ annotation: Annotation, size: NSSize) {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
        func rect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
        }
        switch annotation {
        case let .arrow(_, from, to, color, width):
            let start = point(from), end = point(to)
            color.setStroke()
            let path = NSBezierPath(); path.move(to: start); path.line(to: end); path.lineWidth = width; path.lineCapStyle = .round; path.stroke()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(12, width * 4)
            let head = NSBezierPath(); head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
            head.move(to: end)
            head.line(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
            head.lineWidth = width; head.lineCapStyle = .round; head.stroke()
        case let .rectangle(_, normalized, color, width):
            color.setStroke(); let path = NSBezierPath(roundedRect: rect(normalized), xRadius: 3, yRadius: 3); path.lineWidth = width; path.stroke()
        case let .highlight(_, from, to, color, width):
            color.withAlphaComponent(0.36).setStroke(); let path = NSBezierPath(); path.move(to: point(from)); path.line(to: point(to)); path.lineWidth = width; path.lineCapStyle = .round; path.stroke()
        case let .redact(_, normalized):
            NSColor.black.setFill(); rect(normalized).fill()
        case let .text(_, normalized, text, color):
            let p = point(normalized)
            text.draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: max(18, size.width / 60), weight: .semibold), .foregroundColor: color])
        }
    }
}

struct EditorView: View {
    @StateObject private var model: EditorModel
    let filename: String

    init(source: CGImage, filename: String) {
        _model = StateObject(wrappedValue: EditorModel(image: source))
        self.filename = filename
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            AnnotationCanvas(model: model)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack {
                Text("\(model.image.width) × \(model.image.height) px · PNG")
                Spacer()
                Text("⌘C — копировать")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let image = model.renderedImage() { AppController.shared.save(image, suggestedName: filename) }
                } label: { Label("Сохранить", systemImage: "square.and.arrow.down") }
                Button {
                    if let image = model.renderedImage() { AppController.shared.processEditedImage(image) }
                } label: { Label("Копировать", systemImage: "doc.on.doc") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("c")
            }
        }
    }

    private var editorToolbar: some View {
        HStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                Button { model.tool = tool } label: {
                    Image(systemName: tool.symbol).frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .background(model.tool == tool ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(model.tool == tool ? Color.accentColor : Color.primary)
                .help(tool.title)
                .accessibilityLabel(tool.title)
            }
            Divider().frame(height: 20).padding(.horizontal, 7)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).help("Отменить").keyboardShortcut("z")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).help("Повторить").keyboardShortcut("z", modifiers: [.command, .shift])
            Spacer()
            if model.tool != .crop && model.tool != .redact && model.tool != .select {
                ColorButton(color: Binding(get: { model.color }, set: { model.color = $0 }))
            }
            if [.arrow, .rectangle, .highlight].contains(model.tool) {
                ThicknessPicker(
                    width: Binding(get: { model.lineWidth }, set: { model.lineWidth = $0 }),
                    color: Color(nsColor: model.color),
                    tool: model.tool
                )
            }
            Text(model.tool.title).font(.caption).foregroundStyle(.secondary).frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

/// Swatch of the current colour that opens a palette, instead of the system colour
/// well that only ever led to the separate macOS colour panel.
private struct ColorButton: View {
    @Binding var color: NSColor
    @State private var showsPalette = false

    private static let presets: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
        .systemBlue, .systemPurple, .systemPink, .white, .black
    ]

    var body: some View {
        Button { showsPalette.toggle() } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: color))
                .frame(width: 26, height: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator)
                )
        }
        .buttonStyle(.plain)
        .help("Цвет пометки")
        .accessibilityLabel("Цвет пометки")
        .popover(isPresented: $showsPalette, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 5), spacing: 8) {
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            color = preset
                            showsPalette = false
                        } label: {
                            Circle()
                                .fill(Color(nsColor: preset))
                                .frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.separator))
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                        .padding(-3)
                                        .opacity(preset.isVisuallyEqual(to: color) ? 1 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.accessibilityName)
                    }
                }
                Divider()
                ColorPicker("Другой цвет", selection: Binding(
                    get: { Color(nsColor: color) },
                    set: { color = NSColor($0) }
                ))
                .font(.caption)
            }
            .padding(12)
            .frame(width: 194)
        }
    }
}

/// Four stroke samples drawn at the width they actually produce, so the choice is
/// visible rather than spelled out as a pixel count.
private struct ThicknessPicker: View {
    @Binding var width: CGFloat
    let color: Color
    let tool: EditorTool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationStyle.widths, id: \.self) { option in
                Button { width = option } label: {
                    Capsule()
                        .fill(color)
                        .frame(width: 22, height: previewThickness(for: option))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    width == option ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .help("Толщина \(Int(AnnotationStyle.effectiveWidth(option, for: tool))) px")
                .accessibilityLabel("Толщина \(Int(AnnotationStyle.effectiveWidth(option, for: tool))) px")
            }
        }
    }

    /// The real stroke can be far taller than the toolbar, so the samples keep the
    /// proportions between the options while fitting the row.
    private func previewThickness(for option: CGFloat) -> CGFloat {
        let real = AnnotationStyle.effectiveWidth(option, for: tool)
        let largest = AnnotationStyle.effectiveWidth(AnnotationStyle.widths.last ?? 8, for: tool)
        let smallest = AnnotationStyle.effectiveWidth(AnnotationStyle.widths.first ?? 2, for: tool)
        guard largest > smallest else { return 2 }
        let position = (real - smallest) / (largest - smallest)
        return 2 + position * 8
    }
}

private extension NSColor {
    func isVisuallyEqual(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }
}

private struct AnnotationCanvas: View {
    @ObservedObject var model: EditorModel
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(imageSize: CGSize(width: model.image.width, height: model.image.height), in: proxy.size)
            ZStack {
                Color.clear
                Image(decorative: model.image, scale: 1)
                    .resizable().scaledToFit().frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                Canvas { context, _ in
                    for annotation in model.annotations { draw(annotation, in: imageRect, context: &context) }
                    if let start = dragStart, let current = dragCurrent {
                        drawPreview(from: start, to: current, in: imageRect, context: &context)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: model.tool == .text ? 0 : 2)
                .onChanged { value in
                    guard imageRect.contains(value.startLocation) else { return }
                    dragStart = normalize(value.startLocation, in: imageRect)
                    dragCurrent = normalize(value.location, in: imageRect)
                }
                .onEnded { value in
                    guard let start = dragStart, let current = dragCurrent else { resetDrag(); return }
                    commit(from: start, to: current)
                    resetDrag()
                })
        }
        .padding(20)
    }

    private func commit(from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        switch model.tool {
        case .arrow: model.add(.arrow(id: UUID(), from: start, to: end, color: model.color, width: model.lineWidth))
        case .rectangle where rect.width > 0.005 && rect.height > 0.005: model.add(.rectangle(id: UUID(), rect: rect, color: model.color, width: model.lineWidth))
        case .highlight: model.add(.highlight(id: UUID(), from: start, to: end, color: model.color, width: AnnotationStyle.effectiveWidth(model.lineWidth, for: .highlight)))
        case .redact where rect.width > 0.005 && rect.height > 0.005: model.add(.redact(id: UUID(), rect: rect))
        case .crop: model.crop(to: rect)
        case .text:
            let alert = NSAlert(); alert.messageText = "Добавить текст"; alert.addButton(withTitle: "Добавить"); alert.addButton(withTitle: "Отмена")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.placeholderString = "Текст пометки"; alert.accessoryView = field
            if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.add(.text(id: UUID(), point: start, text: field.stringValue, color: model.color))
            }
        default: break
        }
    }

    private func draw(_ annotation: Annotation, in rect: CGRect, context: inout GraphicsContext) {
        func p(_ point: CGPoint) -> CGPoint { CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height) }
        func r(_ normalized: CGRect) -> CGRect { CGRect(x: rect.minX + normalized.minX * rect.width, y: rect.minY + normalized.minY * rect.height, width: normalized.width * rect.width, height: normalized.height * rect.height) }
        switch annotation {
        case let .arrow(_, from, to, color, width): drawArrow(from: p(from), to: p(to), color: Color(nsColor: color), width: width, context: &context)
        case let .rectangle(_, normalized, color, width): context.stroke(Path(roundedRect: r(normalized), cornerRadius: 3), with: .color(Color(nsColor: color)), lineWidth: width)
        case let .highlight(_, from, to, color, width): var path = Path(); path.move(to: p(from)); path.addLine(to: p(to)); context.stroke(path, with: .color(Color(nsColor: color).opacity(0.36)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        case let .redact(_, normalized): context.fill(Path(r(normalized)), with: .color(.black))
        case let .text(_, point, text, color): context.draw(Text(text).font(.system(size: 18, weight: .semibold)).foregroundColor(Color(nsColor: color)), at: p(point), anchor: .topLeading)
        }
    }

    private func drawPreview(from: CGPoint, to: CGPoint, in rect: CGRect, context: inout GraphicsContext) {
        let annotation: Annotation
        let box = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y))
        switch model.tool {
        case .arrow: annotation = .arrow(id: UUID(), from: from, to: to, color: model.color, width: model.lineWidth)
        case .rectangle, .crop: annotation = .rectangle(id: UUID(), rect: box, color: model.tool == .crop ? .controlAccentColor : model.color, width: model.tool == .crop ? 1.5 : model.lineWidth)
        case .highlight: annotation = .highlight(id: UUID(), from: from, to: to, color: model.color, width: AnnotationStyle.effectiveWidth(model.lineWidth, for: .highlight))
        case .redact: annotation = .redact(id: UUID(), rect: box)
        default: return
        }
        draw(annotation, in: rect, context: &context)
    }

    private func drawArrow(from: CGPoint, to: CGPoint, color: Color, width: CGFloat, context: inout GraphicsContext) {
        var path = Path(); path.move(to: from); path.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x), length = max(12, width * 4)
        path.move(to: to); path.addLine(to: CGPoint(x: to.x - length * cos(angle - .pi / 6), y: to.y - length * sin(angle - .pi / 6)))
        path.move(to: to); path.addLine(to: CGPoint(x: to.x - length * cos(angle + .pi / 6), y: to.y - length * sin(angle + .pi / 6)))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)), y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }
    private func aspectFitRect(imageSize: CGSize, in size: CGSize) -> CGRect {
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
    private func resetDrag() { dragStart = nil; dragCurrent = nil }
}
