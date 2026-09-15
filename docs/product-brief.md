# Snipiko — product brief

## Product

Snipiko is a compact native macOS screenshot utility built around the flow: capture, mark up, copy, send.

The app uses Swift and SwiftUI, with AppKit where macOS-specific window, menu bar, shortcut, and capture behavior requires it.

## Primary workflow

1. The user presses a configurable global shortcut.
2. The user captures an area, a window, or a display.
3. Snipiko immediately copies the image to the clipboard and shows a small preview.
4. The user can drag, save, dismiss, or open the screenshot in the editor.
5. The editor provides arrows, rectangles, text, highlighting, redaction, and cropping.

## Permissions and first launch

- On every launch, Snipiko checks whether Screen Recording access is available.
- On first launch, Snipiko explains why the permission is needed before macOS shows its system prompt.
- If access is missing, capture actions show a clear blocked state with a button that opens the correct System Settings page.
- After access is granted, Snipiko explains when macOS requires the app to restart and provides a restart action.
- Permission checks must never trap the user in a modal loop. Settings and Quit remain available.
- Global shortcuts should use the native hotkey registration mechanism and must not require Accessibility permission merely to observe arbitrary keyboard input.
- A save-folder choice is requested only when the user enables automatic saving or chooses a custom destination.

## Application lifecycle

- Snipiko is primarily a menu bar app.
- Closing the editor, history, settings, onboarding, or permission window hides that window and leaves Snipiko running.
- The menu bar icon remains available while Snipiko is running.
- Clicking the menu bar icon opens capture commands, the latest capture, history, settings, and Quit.
- The application exits only through Quit Snipiko or `Command-Q`.
- Closing an editor must not lose the capture: the latest capture remains available in local history.
- Launch at Login is optional and controlled in Settings.
- The Dock icon is hidden during ordinary menu bar operation. Snipiko may temporarily behave as a foreground app while an editor or settings window is active if required for correct macOS focus and keyboard behavior.

## Shortcuts

The user can independently assign or disable shortcuts for:

- Capture Area
- Capture Window
- Capture Display
- Open History

The recorder accepts function keys or combinations containing Command, Option, or Control. It detects conflicts between Snipiko actions and explains that macOS cannot reliably enumerate every shortcut registered by other apps.

## Visual direction

Snipiko uses compact native macOS proportions, San Francisco typography, restrained neutral surfaces, one interface accent, and separate annotation colors. The screenshot remains the visual focus. Light and dark appearances follow the system.

## Initial release

- Area, window, and display capture
- Configurable global shortcuts
- Clipboard copy and optional file saving
- Small dismissible preview with drag support
- Lightweight annotation editor
- Local history of the latest 50 captures
- PNG and JPEG export
- Menu bar operation and optional Launch at Login
- Screen Recording permission onboarding and recovery states

OCR, scrolling capture, video recording, WebP export, and presentation backgrounds are deferred.
