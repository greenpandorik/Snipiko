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
    @State private var sharing = false
    @State private var recognizing = false
    @State private var recognitionNote: String?

    private func recognizeText() {
        guard let image = item.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        recognizing = true
        recognitionNote = nil
        WindowManager.shared.holdPreview()
        Task {
            defer { recognizing = false }
            do {
                let text = try await TextRecognizer.recognize(in: image)
                guard !text.isEmpty else {
                    recognitionNote = "Текст на снимке не найден."
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let lines = text.split(separator: "\n").count
                recognitionNote = "Скопировано строк: \(lines)."
            } catch {
                recognitionNote = "Не удалось распознать текст."
            }
        }
    }

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
                    guard let image = item.image else { return }
                    WindowManager.shared.dismissPreview()
                    PinnedCaptures.shared.pin(image)
                } label: { Image(systemName: "pin") }
                    .buttonStyle(.bordered)
                    .help("Закрепить поверх экрана")
                Button { recognizeText() } label: {
                    Image(systemName: recognizing ? "hourglass" : "text.viewfinder")
                }
                .buttonStyle(.bordered)
                .disabled(recognizing)
                .help("Скопировать текст со снимка")
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .help("Поделиться")
                    .background(SharePicker(isPresented: $sharing, items: [item.url]))
                Button { WindowManager.shared.dismissPreview() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .help("Закрыть превью")
            }
            if let recognitionNote {
                Text(recognitionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
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
    @State private var query = ""
    @State private var favouritesOnly = false
    @State private var sharing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("История").font(.title2.weight(.semibold))
                Spacer()
                Toggle(isOn: $favouritesOnly) {
                    Label("Только избранное", systemImage: "star")
                }
                .toggleStyle(.button)
                .help("Показывать только отмеченные снимки")
                Button("Очистить", role: .destructive) { history.clear() }
                    .disabled(history.items.allSatisfy(\.isFavourite))
                    .help("Удаляет всё, кроме избранного")
            }
            .padding(20)

            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: query.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { item in
                        HistoryRow(item: item) { history.setFavourite(!item.isFavourite, for: item) }
                            .tag(item.id)
                            .contextMenu {
                                Button("Открыть в редакторе") { WindowManager.shared.showEditor(item) }
                                Button("Скопировать") { AppController.shared.copy(item) }
                                Button("Закрепить поверх экрана") {
                                    if let image = item.image { PinnedCaptures.shared.pin(image) }
                                }
                                Button(item.isFavourite ? "Убрать из избранного" : "В избранное") {
                                    history.setFavourite(!item.isFavourite, for: item)
                                }
                                Divider()
                                Button("Удалить", role: .destructive) { history.delete(item) }
                            }
                            .onTapGesture(count: 2) { WindowManager.shared.showEditor(item) }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Поиск по дате, размеру или имени файла")
        .frame(minWidth: 620, minHeight: 430)
        .toolbar {
            ToolbarItemGroup {
                Button { if let item = selectedItem { WindowManager.shared.showEditor(item) } } label: { Label("Разметить", systemImage: "pencil") }
                    .disabled(selectedItem == nil)
                Button { if let item = selectedItem { AppController.shared.copy(item) } } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    .disabled(selectedItem == nil)
                Button {
                    if let image = selectedItem?.image { PinnedCaptures.shared.pin(image) }
                } label: { Label("Закрепить", systemImage: "pin") }
                    .disabled(selectedItem == nil)
                Button { sharing = true } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }
                    .disabled(selectedItem == nil)
                    .background(SharePicker(isPresented: $sharing, items: selectedItem.map { [$0.url] } ?? []))
            }
        }
    }

    /// Matches the visible description of a capture rather than only its file name:
    /// the name is an internal identifier, so searching "1280" or "09-16" is what
    /// someone actually reaches for.
    private var filtered: [CaptureItem] {
        let base = favouritesOnly ? history.items.filter(\.isFavourite) : history.items
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return base }
        return base.filter { item in
            let haystack = [
                item.filename,
                HistoryStore.filenameFormatter.string(from: item.createdAt),
                "\(item.width)x\(item.height)",
                "\(item.width) × \(item.height)"
            ].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "Ничего не найдено" }
        return favouritesOnly ? "В избранном пусто" : "Снимков пока нет"
    }

    private var emptyDescription: String {
        if !query.isEmpty { return "Попробуйте другой запрос." }
        return favouritesOnly
            ? "Отметьте снимок звёздочкой, и он не будет удаляться при переполнении истории."
            : "Новый снимок появится здесь автоматически."
    }

    private var selectedItem: CaptureItem? { history.items.first { $0.id == selection } }
}

private struct HistoryRow: View {
    let item: CaptureItem
    let onToggleFavourite: () -> Void

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
            Button(action: onToggleFavourite) {
                Image(systemName: item.isFavourite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavourite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(item.isFavourite ? "Убрать из избранного" : "В избранное — снимок не будет удалён при переполнении")
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
    /// Sections live in a sidebar rather than tabs: tabs stop scaling past a
    /// handful, and more sections are coming. A section is only listed once it has
    /// content -- an empty "History" placeholder would be worse than its absence.
    private enum Section: String, CaseIterable, Identifiable {
        case general, capture, shortcuts, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "Основные"
            case .capture: "Съёмка"
            case .shortcuts: "Хоткеи"
            case .history: "История"
            }
        }
        var symbol: String {
            switch self {
            case .general: "switch.2"
            case .capture: "camera"
            case .shortcuts: "keyboard"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(selection.title).font(.title2.weight(.semibold))
                    switch selection {
                    case .general: GeneralSettings()
                    case .capture: CaptureSettings()
                    case .shortcuts: ShortcutSettings()
                    case .history: HistorySettings()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(26)
            }
        }
    }
}

/// A titled block of related settings with an explanatory footer, replacing the
/// run of bare dividers the old settings used.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 13) { content }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = AppController.shared

    var body: some View {
        SettingsGroup(title: "Запуск", footer: "Snipiko живёт в строке меню и не занимает место в Dock.") {
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.setLaunchAtLogin($0) }
            ))
        }
        SettingsGroup(
            title: "Доступ к записи экрана",
            footer: "macOS применяет это разрешение только после перезапуска приложения."
        ) {
            HStack {
                Label(
                    controller.hasScreenPermission ? "Разрешён" : "Не разрешён",
                    systemImage: controller.hasScreenPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(controller.hasScreenPermission ? Color.green : Color.orange)
                Spacer()
                Button("Системные настройки…") { ScreenPermission.openSettings() }
            }
        }
    }
}

private struct CaptureSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup(title: "Съёмка", footer: "Курсор попадает в кадр во всех режимах — области, окна и экрана.") {
            Toggle("Показывать курсор на снимке", isOn: $settings.includeCursor)
            Toggle("Обводить снятую область", isOn: $settings.flashOnCapture)
            HStack {
                Toggle("Звук затвора", isOn: Binding(
                    get: { settings.captureSound != nil },
                    set: { settings.captureSound = $0 ? CaptureSound.defaultName : nil }
                ))
                Spacer()
                Picker("Звук", selection: Binding(
                    get: { settings.captureSound ?? CaptureSound.defaultName },
                    set: { settings.captureSound = $0 }
                )) {
                    ForEach(CaptureSound.available, id: \.self) { name in Text(name).tag(name) }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(settings.captureSound == nil)
                Button {
                    CaptureSound.play(settings.captureSound ?? CaptureSound.defaultName)
                } label: { Image(systemName: "play.circle") }
                .buttonStyle(.plain)
                .help("Прослушать")
            }
        }
        SettingsGroup(title: "Имя файла", footer: filenameFooter) {
            TextField("Шаблон", text: $settings.filenameTemplate)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Пример:").foregroundStyle(.secondary)
                Text(examplePreview).monospaced()
                Spacer()
                Button("По умолчанию") { settings.filenameTemplate = FilenameTemplate.default }
                    .disabled(settings.filenameTemplate == FilenameTemplate.default)
            }
            .font(.caption)
        }
        SettingsGroup(title: "Формат файлов", footer: "Снимок всегда попадает в буфер обмена в PNG; формат влияет на сохранение в файл.") {
            HStack {
                Text("Формат")
                Spacer()
                Picker("Формат", selection: $settings.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in Text(format.title).tag(format) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            if settings.exportFormat == .jpeg {
                HStack {
                    Text("Качество")
                    Slider(value: $settings.jpegQuality, in: 0.5...1, step: 0.05)
                    Text("\(Int(settings.jpegQuality * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
        SettingsGroup(title: "Автосохранение", footer: "Каждый снимок дополнительно сохраняется в выбранную папку, не спрашивая.") {
            Toggle("Сохранять снимки автоматически", isOn: $settings.autoSave)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Папка")
                    Text(settings.autoSaveFolder?.path(percentEncoded: false) ?? "Не выбрана")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Выбрать…") { settings.chooseAutoSaveFolder() }
            }
            .disabled(!settings.autoSave)
        }
    }

    private var filenameFooter: String {
        "Подстановки: " + FilenameTemplate.tokens.map { "\($0.token) — \($0.meaning)" }.joined(separator: ", ")
            + ". Применяется к автосохранению и к диалогу сохранения."
    }

    /// Rendered with the counter left alone, so opening Settings does not advance it.
    private var examplePreview: String {
        let base = FilenameTemplate.filename(
            settings.filenameTemplate,
            width: 1280,
            height: 800,
            counter: UserDefaults.standard.integer(forKey: "filenameCounter") + 1
        )
        return "\(base).\(settings.exportFormat.fileExtension)"
    }
}

private struct HistorySettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        SettingsGroup(
            title: "Размер истории",
            footer: "Когда обычных снимков становится больше лимита, самые старые удаляются. Отмеченные звёздочкой не удаляются никогда и в лимит не входят."
        ) {
            HStack {
                Text("Хранить снимков")
                Spacer()
                Picker("Хранить снимков", selection: $settings.historyLimit) {
                    ForEach([20, 50, 100, 250, 500], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                .onChange(of: settings.historyLimit) { history.applyHistoryLimit() }
            }
            Divider()
            HStack {
                Text("Сейчас в истории")
                Spacer()
                Text("\(history.items.count), из них избранных \(history.items.filter(\.isFavourite).count)")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        SettingsGroup(title: "Закреплённые снимки", footer: "Закреплённый снимок висит поверх всех окон, пока его не откроют.") {
            HStack {
                Text("Открепить все")
                Spacer()
                Button("Открепить") { PinnedCaptures.shared.closeAll() }
                    .disabled(!PinnedCaptures.shared.hasPinned)
            }
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @State private var conflictMessage: String?
    @State private var probing: ShortcutAction?
    @State private var probeResult: (action: ShortcutAction, reached: Bool)?

    var body: some View {
        SettingsGroup(
            title: "Назначения",
            footer: "Нажмите на сочетание и введите новое. Подойдёт F-клавиша либо сочетание с ⌘, ⌥ или ⌃."
        ) {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { Divider() }
                ShortcutRow(
                    action: action,
                    shortcut: settings.shortcuts[action] ?? nil,
                    systemOwner: (settings.shortcuts[action] ?? nil).flatMap(SystemShortcuts.owner(of:)),
                    registrationFailed: hotKeys.failedRegistrations.contains(action),
                    isProbing: probing == action,
                    probeReached: probeResult?.action == action ? probeResult?.reached : nil,
                    onChange: { assign($0, to: action) },
                    onProbe: { probe(action) }
                )
            }
            if let conflictMessage {
                Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        SettingsGroup(
            title: "Если сочетание не срабатывает",
            footer: "macOS обрабатывает свои сочетания раньше программ, и узнать заранее, занято ли сочетание сторонним приложением, невозможно. Кнопка «Проверить» отвечает фактом: нажмите сочетание и увидите, дошло ли оно до Snipiko."
        ) {
            HStack {
                Button("Сбросить все назначения") {
                    settings.resetShortcuts()
                    HotKeyManager.shared.registerAll()
                    probeResult = nil
                }
                Spacer()
            }
        }
    }

    private func assign(_ shortcut: Shortcut?, to action: ShortcutAction) {
        if let shortcut,
           let other = settings.shortcuts.first(where: { $0.key != action && $0.value == shortcut })?.key {
            conflictMessage = "\(shortcut.displayValue) уже используется для «\(other.title)»."
            return
        }
        conflictMessage = nil
        probeResult = nil
        settings.shortcuts[action] = shortcut
        HotKeyManager.shared.registerAll()
    }

    private func probe(_ action: ShortcutAction) {
        probing = action
        probeResult = nil
        Task {
            let reached = await HotKeyManager.shared.probe(action)
            probing = nil
            probeResult = (action, reached)
        }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcut: Shortcut?
    /// What macOS uses this combination for, when it is one of the known ones.
    let systemOwner: String?
    let registrationFailed: Bool
    let isProbing: Bool
    /// Result of the last check for this row: true when the press arrived.
    let probeReached: Bool?
    let onChange: (Shortcut?) -> Void
    let onProbe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(action.title)
                Spacer()
                if shortcut != nil {
                    Button(isProbing ? "Нажмите…" : "Проверить", action: onProbe)
                        .buttonStyle(.link)
                        .disabled(isProbing)
                }
                HotKeyRecorder(shortcut: shortcut, onChange: onChange)
                    .frame(width: 116, height: 28)
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Убрать назначение")
                    .disabled(shortcut == nil)
            }
            if let note {
                Label(note.text, systemImage: note.symbol)
                    .font(.caption)
                    .foregroundStyle(note.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

    /// At most one note per row, worst news first: a failed registration beats a
    /// suspected conflict, and both beat a stale check result.
    private var note: (text: String, symbol: String, tint: Color)? {
        if registrationFailed {
            return ("Не удалось зарегистрировать сочетание — его уже занял кто-то другой.",
                    "exclamationmark.triangle.fill", .orange)
        }
        if let systemOwner {
            return ("Обычно занято \(systemOwner) в macOS — нажатие может не дойти до Snipiko.",
                    "exclamationmark.triangle.fill", .orange)
        }
        if isProbing {
            return ("Нажмите сочетание — жду до пяти секунд.", "keyboard", .secondary)
        }
        switch probeReached {
        case true: return ("Сочетание доходит до Snipiko.", "checkmark.circle.fill", .green)
        case false: return ("Нажатие не дошло: сочетание перехватывает другая программа.",
                            "xmark.circle.fill", .orange)
        case nil: return nil
        }
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
