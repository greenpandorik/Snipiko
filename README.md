# Snipiko

Snipiko is a native macOS screenshot utility for quickly capturing, marking up, copying, and sharing screenshots.

## Requirements

- macOS 14 or later
- Xcode 16 or later

## Run

Snipiko must be signed with a stable certificate, otherwise macOS forgets the
Screen Recording grant after every rebuild (see [Code signing](#code-signing)).

```sh
scripts/make-signing-cert.sh   # once, creates a local signing identity
scripts/build.sh               # build, install to /Applications, launch
```

Grant Screen Recording access when Snipiko asks for it, then restart the app.

To work in Xcode instead, open `Snipiko.xcodeproj` and press Run — the project is
already pinned to the `Snipiko Local Dev` identity, so run the certificate script
first. Keep DerivedData at its default location: building inside `~/Desktop` makes
codesign fail, because macOS stamps `com.apple.provenance` on everything created
in protected folders.

## Code signing

The project has no Apple Developer team, so it is signed with a self-signed
certificate kept in the login keychain.

This is not cosmetic. macOS stores the Screen Recording grant against the app's
*designated requirement*. Without a certificate the requirement degrades to the
exact `cdhash` of the binary, which changes on every build — so the grant silently
stops matching and the onboarding window comes back. With the certificate the
requirement is `identifier "com.mihailvolkov.snipiko" and certificate root = H"..."`,
which survives rebuilds.

Consequences: the app runs only on this machine. Distributing it needs a real
Apple Developer ID — set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in the
project. If the grant ever misbehaves, reset it and rebuild:

```sh
tccutil reset ScreenCapture com.mihailvolkov.snipiko
scripts/build.sh
```

Snipiko runs in the macOS menu bar. Closing its windows leaves it running; use **Завершить Snipiko** in the menu or `Command-Q` to quit.

## Current MVP

- Area, window, and display capture through ScreenCaptureKit, at native Retina resolution
- All-displays capture, composited into a single image in the real monitor layout
- Automatic clipboard copy and a dismissible preview
- Local history limited to 50 screenshots
- Configurable global shortcuts without Accessibility permission
- Annotation editor with arrows, rectangles, text, highlighting, opaque redaction, cropping, undo, and redo
- Optional Launch at Login
- Screen Recording permission onboarding and recovery

---

# Snipiko (по-русски)

Snipiko — нативная утилита для macOS: быстро снять скриншот, разметить его, скопировать и поделиться.

## Требования

- macOS 14 или новее
- Xcode 16 или новее

## Запуск

Snipiko обязательно нужно подписывать стабильным сертификатом, иначе macOS будет
забывать разрешение на запись экрана после каждой пересборки (подробнее — в разделе
[Подпись кода](#подпись-кода)).

```sh
scripts/make-signing-cert.sh   # один раз, создаёт локальную подпись
scripts/build.sh               # сборка, установка в /Applications, запуск
```

Выдайте доступ к записи экрана, когда Snipiko его попросит, и перезапустите приложение.

Если хотите работать из Xcode — откройте `Snipiko.xcodeproj` и нажмите Run: проект уже
привязан к подписи `Snipiko Local Dev`, так что сначала выполните скрипт с сертификатом.
DerivedData оставьте в стандартном месте: при сборке внутри `~/Desktop` codesign падает,
потому что macOS вешает `com.apple.provenance` на всё, что создаётся в защищённых папках.

## Подпись кода

Аккаунта Apple Developer у проекта нет, поэтому подпись самоподписанная и лежит в связке
ключей login.

Это не косметика. macOS хранит разрешение на запись экрана привязанным к *designated
requirement* приложения. Без сертификата это требование вырождается в точный `cdhash`
бинарника, а он меняется при каждой сборке — разрешение перестаёт подходить, и окно
онбординга возвращается. С сертификатом требование выглядит как
`identifier "com.mihailvolkov.snipiko" and certificate root = H"..."` и переживает пересборки.

Ограничения: приложение работает только на этой машине. Чтобы раздавать его другим, нужен
настоящий Apple Developer ID — тогда пропишите `DEVELOPMENT_TEAM` и `CODE_SIGN_IDENTITY`
в проекте. Если разрешение всё-таки начнёт чудить, сбросьте его и пересоберите:

```sh
tccutil reset ScreenCapture com.mihailvolkov.snipiko
scripts/build.sh
```

Snipiko живёт в строке меню macOS. Закрытие окон не выключает приложение: чтобы выйти, используйте пункт **Завершить Snipiko** в меню или `Command-Q`.

## Что уже умеет MVP

- Съёмка области, окна и целого экрана через ScreenCaptureKit в родном разрешении Retina
- Снимок всех мониторов сразу — склеивается в одно изображение по реальному расположению экранов
- Автоматическое копирование в буфер обмена и превью, которое можно закрыть
- Локальная история на 50 последних скриншотов
- Настраиваемые глобальные горячие клавиши без разрешения Accessibility
- Редактор разметки: стрелки, прямоугольники, текст, выделение маркером, непрозрачное затирание, обрезка, отмена и повтор действия
- Опциональный автозапуск при входе в систему
- Онбординг и восстановление разрешения на запись экрана
