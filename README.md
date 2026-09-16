# Snipiko

Snipiko is a native macOS screenshot utility for quickly capturing, marking up, copying, and sharing screenshots.

## Install

Download the latest DMG from [Releases](../../releases), drag Snipiko into
Applications, and open it.

macOS will say it cannot verify the developer. That is expected: the app is
signed, but not notarized by Apple, because the project has no paid Apple
Developer ID. To allow it, open **System Settings → Privacy & Security**, scroll
to the bottom and press **Open Anyway** next to Snipiko. If that does not work:

```sh
xattr -dr com.apple.quarantine /Applications/Snipiko.app
```

Then grant Screen Recording access and restart Snipiko.

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

Consequences: Gatekeeper on anyone else's Mac rejects the app until they allow
it by hand — verified with `spctl`, which reports `rejected, origin=Snipiko
Local Dev` even though the signature itself is valid. Clean, warning-free
installs need a paid Apple Developer ID and notarization; set
`DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in the project and run the DMG
through `notarytool`.

## Releasing

`scripts/package.sh [version]` builds a signed DMG into `dist/`. Pushing a tag
runs the same script on CI and attaches the result to a GitHub release:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Without a `SIGNING_CERTIFICATE_P12` repository secret, CI generates a throwaway
certificate for each build. That works, but the app's identity changes every
release, and macOS ties the Screen Recording grant to that identity — so users
would have to grant it again after each update. Storing the certificate as a
secret avoids that. If the grant ever misbehaves, reset it and rebuild:

```sh
tccutil reset ScreenCapture com.mihailvolkov.snipiko
scripts/build.sh
```

Snipiko runs in the macOS menu bar. Closing its windows leaves it running; use **Завершить Snipiko** in the menu or `Command-Q` to quit.

## Current MVP

- Area, window, and display capture through ScreenCaptureKit, at native Retina resolution
- All-displays capture, composited into a single image in the real monitor layout
- Automatic clipboard copy and a dismissible preview
- Pin a capture on top of every window, with adjustable opacity
- Text recognition on a capture through on-device Vision, nothing leaves the Mac
- Share straight from the preview via AirDrop, Mail and the rest
- Local history with search, favourites that are never trimmed, and a configurable size
- Configurable global shortcuts without Accessibility permission, with conflict warnings and a live check
- Optional shutter sound and an outline tracing the captured area
- Filename template with date, time, size and counter tokens
- Windows sized from the display they open on, remembering where you left them
- Annotation editor with arrows, rectangles, text, highlighting, opaque redaction, cropping, undo, and redo
- Optional Launch at Login
- Screen Recording permission onboarding and recovery

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Mihail Volkov.

---

# Snipiko (по-русски)

Snipiko — нативная утилита для macOS: быстро снять скриншот, разметить его, скопировать и поделиться.

## Установка

Скачайте свежий DMG из раздела [Releases](../../releases), перетащите Snipiko в
Applications и запустите.

macOS скажет, что не может проверить разработчика. Так и должно быть:
приложение подписано, но не заверено в Apple — платного Apple Developer ID у
проекта нет. Чтобы разрешить запуск, откройте **Системные настройки →
Конфиденциальность и безопасность**, пролистайте вниз и нажмите **«Открыть всё
равно»** рядом со Snipiko. Если не помогает:

```sh
xattr -dr com.apple.quarantine /Applications/Snipiko.app
```

Дальше выдайте доступ к записи экрана и перезапустите Snipiko.

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

Последствия: на чужом Mac Gatekeeper отказывается открывать приложение, пока человек не
разрешит его вручную — проверено через `spctl`, который выдаёт `rejected, origin=Snipiko
Local Dev`, хотя сама подпись при этом корректна. Чтобы установка шла без единого
предупреждения, нужен платный Apple Developer ID и нотаризация: прописать
`DEVELOPMENT_TEAM` и `CODE_SIGN_IDENTITY` в проекте и прогнать DMG через `notarytool`.

## Выпуск релиза

`scripts/package.sh [версия]` собирает подписанный DMG в `dist/`. Пуш тега запускает тот же
скрипт на CI и прикрепляет результат к релизу на GitHub:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Без секрета `SIGNING_CERTIFICATE_P12` в репозитории CI генерирует одноразовый сертификат на
каждую сборку. Это работает, но личность приложения меняется от релиза к релизу, а macOS
привязывает к ней разрешение на запись экрана — значит после каждого обновления его придётся
выдавать заново. Сертификат, положенный в секрет, эту проблему снимает. Если разрешение всё-таки начнёт чудить, сбросьте его и пересоберите:

```sh
tccutil reset ScreenCapture com.mihailvolkov.snipiko
scripts/build.sh
```

Snipiko живёт в строке меню macOS. Закрытие окон не выключает приложение: чтобы выйти, используйте пункт **Завершить Snipiko** в меню или `Command-Q`.

## Что уже умеет MVP

- Съёмка области, окна и целого экрана через ScreenCaptureKit в родном разрешении Retina
- Снимок всех мониторов сразу — склеивается в одно изображение по реальному расположению экранов
- Автоматическое копирование в буфер обмена и превью, которое можно закрыть
- Закрепление снимка поверх всех окон с регулируемой прозрачностью
- Распознавание текста на снимке через системный Vision — ничего не уходит с компьютера
- Отправка прямо из превью: AirDrop, Почта и остальное
- Локальная история с поиском, избранным, которое не удаляется, и настраиваемым размером
- Настраиваемые глобальные горячие клавиши без разрешения Accessibility, с предупреждением о конфликтах и живой проверкой
- Необязательный звук затвора и обводка снятой области
- Шаблон имени файла с подстановками даты, времени, размера и счётчика
- Размер окон считается от экрана, на котором они открываются, и запоминается
- Редактор разметки: стрелки, прямоугольники, текст, выделение маркером, непрозрачное затирание, обрезка, отмена и повтор действия
- Опциональный автозапуск при входе в систему
- Онбординг и восстановление разрешения на запись экрана

## Лицензия

MIT — см. [LICENSE](LICENSE). Copyright (c) 2026 Mihail Volkov.

Пользоваться, изменять и распространять можно свободно, в том числе в коммерческих
проектах. Единственное условие — сохранять текст лицензии и указание авторства в копиях
и производных работах.
