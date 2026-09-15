import AppKit
import Carbon
import ScreenCaptureKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var controller = AppController.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Button { controller.perform(.captureArea) } label: {
            Label("Снять область", systemImage: "viewfinder")
            shortcutLabel(for: .captureArea)
        }
        Button { controller.perform(.captureWindow) } label: {
            Label("Снять окно", systemImage: "macwindow")
            shortcutLabel(for: .captureWindow)
        }
        Button { controller.perform(.captureDisplay) } label: {
            Label("Снять экран", systemImage: "display")
            shortcutLabel(for: .captureDisplay)
        }
        .disabled(controller.isCapturing)
        if NSScreen.screens.count > 1 {
            Button { controller.perform(.captureAllDisplays) } label: {
                Label("Снять все экраны", systemImage: "rectangle.on.rectangle")
                shortcutLabel(for: .captureAllDisplays)
            }
            .disabled(controller.isCapturing)
        }

        Divider()
        if let latest = history.items.first {
            Button {
                WindowManager.shared.showEditor(latest)
            } label: {
                Label("Последний снимок", systemImage: "photo")
            }
            Button {
                controller.copy(latest)
            } label: {
                Label("Скопировать последний", systemImage: "doc.on.doc")
            }
        }
        Button { WindowManager.shared.showHistory() } label: {
            Label("История", systemImage: "clock.arrow.circlepath")
            shortcutLabel(for: .openHistory)
        }

        Divider()
        if !controller.hasScreenPermission {
            Button { WindowManager.shared.showPermission() } label: {
                Label("Разрешить доступ к экрану…", systemImage: "exclamationmark.shield")
            }
        }
        Button { WindowManager.shared.showSettings() } label: {
            Label("Настройки…", systemImage: "gearshape")
        }
        Divider()
        Button("Завершить Snipiko") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func shortcutLabel(for action: ShortcutAction) -> some View {
        if let shortcut = settings.shortcuts[action] ?? nil { Text(shortcut.displayValue) }
    }
}

struct PermissionView: View {
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            Image(systemName: controller.hasScreenPermission ? "checkmark.shield.fill" : "rectangle.inset.filled.and.cursorarrow")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(controller.hasScreenPermission ? Color.green : Color.accentColor)
                .accessibilityHidden(true)
            Text(controller.hasScreenPermission ? "Доступ к экрану разрешён" : "Разрешите снимать экран")
                .font(.title2.weight(.semibold))
                .padding(.top, 18)
            Text(controller.hasScreenPermission
                 ? "Snipiko готов делать снимки. Окно можно закрыть — приложение останется в строке меню."
                 : "Snipiko видит экран только в момент снимка и хранит историю локально на этом Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.top, 8)
            Spacer(minLength: 26)
            if controller.hasScreenPermission {
                Button("Начать") { NSApp.keyWindow?.close() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button("Разрешить доступ") { controller.requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Открыть Системные настройки") { ScreenPermission.openSettings() }
                    .buttonStyle(.link)
                    .padding(.top, 8)
            }
            Text("Снимки не отправляются в интернет")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 20)
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 36)
        .frame(minWidth: 440, minHeight: 330)
    }
}

struct CapturePreviewView: View {
    let item: CaptureItem
    @State private var copied = true

    var body: some View {
        VStack(spacing: 0) {
            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 158)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .draggable(item.url)
            }
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark.circle.fill" : "photo")
                    .foregroundStyle(copied ? .green : .secondary)
                Text(copied ? "Скопировано" : "Готово")
                Spacer()
                Text("\(item.width) × \(item.height)").foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.vertical, 9)

            HStack(spacing: 7) {
                Button {
                    WindowManager.shared.dismissPreview()
                    WindowManager.shared.showEditor(item)
                } label: {
                    Label("Разметить", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    if let image = item.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        AppController.shared.save(image, suggestedName: item.filename)
                    }
                } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.bordered)
                    .help("Сохранить копию")
                Button { WindowManager.shared.dismissPreview() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .help("Закрыть превью")
            }
        }
        // An explicit width is what makes the thumbnail exist at all: inside a
        // hosting controller nothing constrains the width, so the image's
        // `maxWidth: .infinity` collapsed to zero and the row of buttons became the
        // whole panel.
        .frame(width: 282)
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.separator.opacity(0.7)))
        .padding(1)
        .onHover { inside in
            // Don't let the panel vanish from under the pointer while it is being
            // reached for or dragged.
            if inside { WindowManager.shared.holdPreview() } else { WindowManager.shared.releasePreview() }
        }
    }
}

struct HistoryView: View {
    @ObservedObject private var history = HistoryStore.shared
    @State private var selection: CaptureItem.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("История").font(.title2.weight(.semibold))
                Spacer()
                Button("Очистить", role: .destructive) { history.clear() }
                    .disabled(history.items.isEmpty)
            }
            .padding(20)

            Divider()
            if history.items.isEmpty {
                ContentUnavailableView("Снимков пока нет", systemImage: "photo.on.rectangle.angled", description: Text("Новый снимок появится здесь автоматически."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(history.items) { item in
                        HistoryRow(item: item)
                            .tag(item.id)
                            .contextMenu {
                                Button("Открыть в редакторе") { WindowManager.shared.showEditor(item) }
                                Button("Скопировать") { AppController.shared.copy(item) }
                                Divider()
                                Button("Удалить", role: .destructive) { history.delete(item) }
                            }
                            .onTapGesture(count: 2) { WindowManager.shared.showEditor(item) }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 430)
        .toolbar {
            ToolbarItemGroup {
                Button { if let item = selectedItem { WindowManager.shared.showEditor(item) } } label: { Label("Разметить", systemImage: "pencil") }
                    .disabled(selectedItem == nil)
                Button { if let item = selectedItem { AppController.shared.copy(item) } } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    .disabled(selectedItem == nil)
            }
        }
    }

    private var selectedItem: CaptureItem? { history.items.first { $0.id == selection } }
}

private struct HistoryRow: View {
    let item: CaptureItem
    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let image = item.image { Image(nsImage: image).resizable().scaledToFill() }
                else { Color.secondary.opacity(0.12).overlay(Image(systemName: "photo")) }
            }
            .frame(width: 92, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.createdAt, format: .dateTime.day().month().hour().minute()).fontWeight(.medium)
                Text("\(item.width) × \(item.height) · PNG").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

struct WindowPickerView: View {
    @State private var windows: [SCWindow] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Выберите окно").font(.title2.weight(.semibold))
                    Text("Snipiko снимет только выбранное окно.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить")
            }.padding(20)
            Divider()
            Group {
                if loading { ProgressView("Ищем открытые окна…") }
                else if let error { ContentUnavailableView("Окна недоступны", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if windows.isEmpty { ContentUnavailableView("Нет доступных окон", systemImage: "macwindow") }
                else {
                    List(windows, id: \.windowID) { window in
                        Button { AppController.shared.capture(window: window) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "macwindow").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(window.title?.isEmpty == false ? window.title! : "Без названия").lineLimit(1)
                                    Text(window.owningApplication?.applicationName ?? "Приложение").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.contentShape(Rectangle()).padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 380)
        .task { await load() }
    }

    private func load() async {
        loading = true
        do { windows = try await CaptureService.shared.availableWindows(); error = nil }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var conflictMessage: String?

    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Горячие клавиши").font(.title2.weight(.semibold))
                Text("Нажмите на сочетание, затем введите новое. Можно использовать F-клавишу либо сочетание с ⌘, ⌥ или ⌃.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(ShortcutAction.allCases) { action in
                        ShortcutRow(action: action, shortcut: settings.shortcuts[action] ?? nil) { shortcut in
                            assign(shortcut, to: action)
                        }
                        if action != ShortcutAction.allCases.last { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                if let conflictMessage {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Сбросить назначения") { settings.resetShortcuts(); HotKeyManager.shared.registerAll() }
                    Spacer()
                }
                Spacer()
            }
            .padding(24)
            .tabItem { Label("Хоткеи", systemImage: "keyboard") }

            VStack(alignment: .leading, spacing: 20) {
                Text("Основные").font(.title2.weight(.semibold))
                Toggle("Запускать Snipiko при входе", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Доступ к записи экрана")
                        Text(AppController.shared.hasScreenPermission ? "Разрешён" : "Не разрешён")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Системные настройки…") { ScreenPermission.openSettings() }
                }
                Divider()
                HStack {
                    Text("Формат сохранения")
                    Spacer()
                    Picker("Формат сохранения", selection: $settings.exportFormat) {
                        ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                if settings.exportFormat == .jpeg {
                    HStack {
                        Text("Качество JPEG")
                        Slider(value: $settings.jpegQuality, in: 0.5...1, step: 0.05)
                        Text("\(Int(settings.jpegQuality * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                    }
                }
                Divider()
                Toggle("Автоматически сохранять снимки", isOn: $settings.autoSave)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Папка")
                        Text(settings.autoSaveFolder?.path(percentEncoded: false) ?? "Не выбрана")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Выбрать…") { settings.chooseAutoSaveFolder() }
                }
                Spacer()
            }
            .padding(24)
            .tabItem { Label("Основные", systemImage: "switch.2") }
        }
        .frame(minWidth: 540, minHeight: 400)
    }

    private func assign(_ shortcut: Shortcut?, to action: ShortcutAction) {
        if let shortcut,
           let other = settings.shortcuts.first(where: { $0.key != action && $0.value == shortcut })?.key {
            conflictMessage = "\(shortcut.displayValue) уже используется для «\(other.title)»."
            return
        }
        conflictMessage = nil
        settings.shortcuts[action] = shortcut
        HotKeyManager.shared.registerAll()
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            HotKeyRecorder(shortcut: shortcut, onChange: onChange)
                .frame(width: 116, height: 28)
            Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Убрать назначение")
                .disabled(shortcut == nil)
        }
        .padding(.vertical, 10)
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderView {
        let view = HotKeyRecorderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: HotKeyRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onChange = onChange
    }
}

private final class HotKeyRecorderView: NSView {
    var shortcut: Shortcut? { didSet { updateLabel() } }
    var onChange: ((Shortcut?) -> Void)?
    private let label = NSTextField(labelWithString: "Записать…")
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); label.frame = bounds.insetBy(dx: 6, dy: 5) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        label.stringValue = "Нажмите…"
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        if event.keyCode == UInt16(kVK_Escape) { finish(); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            onChange?(nil); finish(); return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isFunctionKey = Self.functionKeys.contains(UInt32(event.keyCode))
        guard isFunctionKey || flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            NSSound.beep(); return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        onChange?(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        finish()
    }

    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }

    private func finish() {
        recording = false
        layer?.borderColor = NSColor.separatorColor.cgColor
        updateLabel()
    }

    private func updateLabel() {
        guard !recording else { return }
        label.stringValue = shortcut?.displayValue ?? "Записать…"
        label.textColor = shortcut == nil ? .secondaryLabelColor : .labelColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private static let functionKeys: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5), UInt32(kVK_F6),
        UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12)
    ]
}
