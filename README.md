# Tuck

A tiny, native menu bar manager for macOS. Hide the menu bar icons you don't need, and reach them in one click.

[简体中文](README.zh-CN.md)

- **Small**: about 1 MB, universal (Apple silicon and Intel), no dependencies.
- **Native**: Swift, AppKit and SwiftUI. No Electron, no web views.
- **macOS 14 Sonoma and later**, including macOS 15 Sequoia and macOS 26 Tahoe.

## Features

- Hidden and always-hidden sections, separated by dividers you ⌘-drag like any icon.
- Show hidden icons by clicking the Tuck icon, a global hotkey, hovering over or clicking an empty part of the menu bar, or scrolling in the menu bar.
- **Tuck Bar**: a panel below the menu bar that lists hidden icons. Used automatically on screens with a notch.
- Layout editor: drag icons between the Visible, Hidden and Always Hidden rows.
- Hides again automatically: when the pointer leaves the menu bar, after a set time, or when you switch apps.
- Launch at login. English and Simplified Chinese.

## Install

1. Download `Tuck-x.y.z.zip` from [Releases](https://github.com/bitmanzzz/Tuck/releases) and unzip it.
2. Move `Tuck.app` to `/Applications`.
3. Tuck is not notarized by Apple, so macOS blocks the first launch. Either:
   - open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - run `xattr -dr com.apple.quarantine /Applications/Tuck.app` in Terminal.

## Use

Tuck adds two items to the menu bar: the Tuck icon (‹) and a thin divider (|) to its left.

1. Hold ⌘ and drag icons you want to hide to the left of the divider.
2. Click the Tuck icon to show or hide them. ⌥-click shows the always-hidden section; right-click opens the menu.
3. Set hotkeys, triggers and the layout editor in **Settings** (right-click the Tuck icon).

On first launch, every icon left of the Tuck icon is hidden. Open **Edit Layout…** or ⌘-drag to bring back the ones you want.

### Permissions

| Permission | Needed for | Required? |
| --- | --- | --- |
| Accessibility | Identifying, opening and moving other apps' icons; Tuck Bar; layout editor; hover and click triggers | For everything beyond basic hiding |
| Screen Recording | Showing real icon images in Tuck Bar and the layout editor | Optional; app icons are shown without it |

Tuck never records or uploads your screen.

## Build from source

Requires the Xcode Command Line Tools (Swift 6).

```sh
./scripts/setup-signing.sh      # optional, once: stable signature so permissions survive rebuilds
./scripts/build-app.sh          # universal build into build/Tuck.app
ARCHS=arm64 ./scripts/build-app.sh   # faster single-architecture build
open build/Tuck.app
```

`PACKAGE=1 VERSION=1.2.3 ./scripts/build-app.sh` also writes `dist/Tuck-1.2.3.zip`. Pushing a `v*` tag builds and publishes a GitHub release; add the `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD` secrets printed by `setup-signing.sh` so released builds keep the same signature.

## How it works

- **Hiding**: each divider is an `NSStatusItem`. Collapsing a section sets the divider's length to 10 000 pt, which pushes every item to its left off the screen.
- **Finding items**: the window server lists menu bar item windows and their frames. Since macOS 26 all of them belong to Control Center, so Tuck matches each window to its owning app through the Accessibility API (`AXExtrasMenuBar`).
- **Moving items**: Tuck replays a ⌘-drag, the same gesture you would use. The events name the item's window, so icons behind the notch or off screen can be moved too.
- **Opening items**: Tuck shows the section, then presses the item through Accessibility.
- **Images**: ScreenCaptureKit captures item windows, including ones that are off screen.

## Known limitations

- Tuck uses a few private CoreGraphics functions to list menu bar windows, so a future macOS release may break it.

## Credits

Inspired by [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird. Tuck is an independent implementation.

## License

[MIT](LICENSE)
