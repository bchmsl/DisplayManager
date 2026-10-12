# DisplayManager

A small macOS menu bar app that saves display layouts and applies them again with one click, a keyboard
shortcut, or automatically when the right monitors are connected to the right ports.

It uses [displayplacer](https://github.com/jakehilborn/displayplacer) to read and change the display
configuration. DisplayManager never installs anything by itself.

## Features

- Saves the current arrangement, resolution, refresh rate, scaling, rotation, mirroring and main display as a
  named **layout**.
- Applies a layout from the menu bar, the Layout Manager, or an optional global keyboard shortcut.
- Shows which saved layout is active right now (exact comparison, no guessing).
- Applies a layout automatically when its displays are connected, at app launch, and after wake, with loop
  protection.
- Can require a monitor to be connected through a specific physical port (for example "USB-C Port 3"), learned
  from the real connection.
- Imports and exports layouts as versioned JSON files.
- Can start at login (SMAppService). The toggle always shows the real system state.

## Requirements

- macOS 14 Sonoma or newer. Built and tested on macOS 27 on an Apple silicon Mac.
- displayplacer 1.4.0 or newer.
- To build: Xcode (recommended) or the Command Line Tools, with Swift 6.0 or newer. With only the Command Line
  Tools on the macOS 27 SDK, the build uses their previous macOS SDK (see [Build from source](#build-from-source)).

### Install displayplacer

```bash
brew install displayplacer
```

DisplayManager looks for it in this order: a custom path set in Settings › displayplacer, `/opt/homebrew/bin`,
`/usr/local/bin`, the directories in `PATH`, `~/.local/bin`, `~/bin`, `/opt/local/bin`. Settings › displayplacer
shows what was found, the version, and where it links to.

Without displayplacer the app still runs. The menu shows "displayplacer not found" and applying or saving
layouts is disabled until it is installed. Click **Re-check** after installing.

## Install

From the project folder:

```bash
./install.sh
```

Options:

| Option | Effect |
|---|---|
| `--no-launch` | Install but do not start the app |
| `--help` | Show usage |

What the installer does:

1. Checks macOS version, `codesign`, `plutil`, `ditto`, `pgrep`, and a Swift toolchain and macOS SDK that can build
   the app (see [Build from source](#build-from-source)).
2. Checks that no source files are evicted by iCloud Drive (see [iCloud Drive](#icloud-drive)).
3. Checks that `/Applications` is writable. If it is not, it stops with an explanation.
4. Checks for displayplacer. If it is missing, it prints the Homebrew command and continues.
5. Builds a Release app bundle in `~/Library/Caches/DisplayManager-build` (outside the source folder) and signs it
   ad-hoc.
6. Quits a running DisplayManager (your data is saved on every change, so nothing is lost).
7. Copies the new app to a staging folder, verifies its signature, then swaps it into
   `/Applications/DisplayManager.app`. If the swap fails, the previous app is restored.
8. Verifies the installed bundle (executable, signature, bundle id, version) and opens the app.

What the installer never does: use `sudo`, install Homebrew or displayplacer, change system settings, or turn on
Launch at Login.

## Using the menu bar item

The icon is a template SF Symbol (`display`), so it follows light and dark menu bars. It shows a warning badge
while an automatic apply failure is not yet acknowledged.

If you do not see the icon, the menu bar may be full (on Macs with a notch, items can hide behind it), or
DisplayManager may be turned off in System Settings › Menu Bar › Allow in the Menu Bar. Opening the app again from
Finder or Spotlight shows the Layout Manager, and the app logs "Menu bar item is not visible" in this case.

| Action | Result |
|---|---|
| Left click | Opens the menu |
| Right click, or Control-click | Opens System Settings › Displays. The menu is not shown |

The menu contains:

- **Current Layout** status: the active layout name, "Custom", or "Applying …".
- A warning line after a failed apply ("Couldn't apply … – Details…") and a Resume item if automation was paused.
- **Layouts**: every saved layout. Click to apply. The active one has a check mark. A layout whose displays are
  not connected is disabled, with the reason in its tooltip.
- **Save Current Layout…** and **Layout Manager…**
- **Auto Apply**, **Reapply After Wake**, **Launch at Login** toggles.
- **Displays Settings…**, **Settings…** (⌘,), **Quit DisplayManager** (⌘Q).

## Saving a layout

1. Arrange your displays in System Settings › Displays.
2. Choose **Save Current Layout…** from the menu (or **+** in the Layout Manager).
3. Enter a name. Optionally tick "Apply automatically when connected like this".
4. If the name already exists, you are asked before it is replaced. Replacing keeps the layout's rule and shortcut.

## Layout Manager

Open it from the menu. It has:

- **Current Displays**: a live preview and the details of every connected display: resolution, refresh rate,
  scaling, color depth, rotation, origin, mirroring, identity (persistent id, serial, EDID vendor/product) and the
  physical connection. It also shows the current displayplacer command.
- **Layouts**: drag to reorder. Right-click a layout for Apply, Rename…, Duplicate, Export… and Delete….
- **Layout details**:
  - editable name, "Active" badge, **Apply Layout** button, last apply result;
  - a proportional preview (main display has a menu-bar strip; rotated displays show a badge; displays that are
    not connected are dashed; disabled displays are listed below);
  - the display list with connection state;
  - the Auto Apply rule, the keyboard shortcut;
  - Advanced: the raw displayplacer command (show and copy) and **Update From Current Layout…**.

Duplicate copies the displays and settings. It does not copy the Auto Apply rule or the shortcut, so the copy never
competes with the original.

## Auto Apply

Turn on **Apply automatically when these displays are connected** in a layout's Auto Apply section.

A rule matches only when the connected displays are exactly the layout's displays. Monitors are recognized by
their identity (persistent id, with the EDID serial as fallback). Optionally, each external monitor can also be
required to use a specific port.

Triggers per rule:

| Trigger | Also needs |
|---|---|
| At app launch | Auto Apply on in the menu |
| When displays connect or change | Auto Apply on in the menu |
| After wake from sleep | Reapply After Wake on in the menu |

How it stays safe:

- It waits until the displays stop changing (debounce plus a stability check), then applies.
- Automatic applies retry a bounded number of times and verify the result after each attempt.
- Changes caused by its own apply, or by you in System Settings, never trigger a new apply.
- It applies once per connection change. Unplug and plug in again to re-trigger.
- After 3 automatic applies within 2 minutes, the next one is skipped and automation pauses. The menu then shows a
  Resume item.
- If several rules match, the one with more port requirements wins. If still tied, the layout higher in the list
  wins. The rule editor warns when two rules have the same conditions.

**Settings › Automation › Wait for displays after wake** adds extra time after wake for slow monitors (default 2 s).

## Learn Current Port and port names

macOS reports which receptacle a display is connected through, for example `Port-USB-C@3`. DisplayManager shows
this as "USB-C Port 3". It is macOS's own number. It is **not** a physical position, so the app never says "left"
or "right".

To require a port:

1. Connect the monitor through the port you want.
2. In the layout's Auto Apply section, click **Learn Current Port** next to the monitor.
3. Give the port a name if you like, for example "Desk Port". Names appear in the menu, the rule editor and the
   Current Displays view.

You can also pick a learned port from the list, or choose "Any port". Learned ports and their names are managed in
Settings › Automation › Learned Ports. Port numbers are stored with the Mac model, because they only mean something
on the same model.

With a port requirement:

- the same monitor on another port does not match;
- a different monitor on the learned port does not match;
- a display whose port cannot be identified never satisfies a port requirement (identity-only rules still work).

## Keyboard shortcuts

Each layout can have one global shortcut. Click the recorder field and press the keys. Esc cancels, Delete clears.
A shortcut needs ⌘, ⌥ or ⌃.

Shortcuts use Carbon hot keys, so no Accessibility or Input Monitoring permission is needed. Before accepting a
shortcut, the app checks enabled macOS shortcuts and shortcuts that other apps registered exclusively. It registers
its own shortcuts non-exclusively, so it never blocks another app. Apps that watch keys in other ways (event taps)
cannot be detected. If such an app uses the same keys, both react.

## Import and export

- **Export** (all layouts, or one layout from its menu) writes a versioned JSON file with layouts, their rules and
  port names.
- **Import** validates the whole file first. Invalid files are refused and nothing is changed.
  - **Add** keeps your layouts. Name conflicts are renamed, rules with the same conditions as an existing rule are
    turned off, and shortcuts already in use are removed. A summary lists what changed.
  - **Replace All** replaces layouts, rules and learned ports. A backup of the current file is saved first
    (`layouts.backup-<timestamp>.json`, newest 5 kept).

## Settings

| Tab | Contents |
|---|---|
| General | Launch at Login (with "Open Login Items…" when approval is needed), Auto Apply, Reapply After Wake, version |
| Automation | Wait after wake, Learned Ports, Recent Activity, Show/Copy Diagnostics |
| displayplacer | Status, path, version, custom path (Choose…/Reset), Re-check, install instructions |
| Data | Counts, data file path, Show Data Folder, Import…, Export… |

## Data and logs

- Layouts, rules and port names: `~/Library/Application Support/DisplayManager/layouts.json` (written atomically on
  every change).
- Preferences: the `com.bachana.DisplayManager` defaults domain.
- Logs use the unified log. No secrets or personal data are logged; hardware identifiers are private by default.

```bash
log stream --predicate 'subsystem == "com.bachana.DisplayManager"' --level info
```

Settings › Automation › **Copy Diagnostics** copies app and macOS versions, the Mac model, displayplacer details,
the current displays and ports, recent apply attempts and recent events. Check it before sharing, because it
contains display identifiers.

## Limitations

- **Port detection** reads IORegistry properties with public IOKit APIs, but these properties are not a documented
  Apple contract. A future macOS may change them. When that happens, ports show as unknown and port rules stop
  matching. Identity-only rules keep working.
- **Verified hardware**: port detection was verified on one Mac (Apple silicon, macOS 27) with a monitor on USB-C
  (DisplayPort Alt Mode). Not verified: Thunderbolt docks (tunneled DisplayPort), MST or daisy chains, HDMI with a
  connected display, Intel Macs, macOS 14 and 15.
- **Identical monitors**: two monitors with identical EDID data cannot be told apart for port rules. Those port
  rules never match.
- **Moving a monitor to another port**: the monitor is expected to keep its persistent id. This was not verified
  with a cable move.
- **displayplacer** uses private CoreGraphics APIs and can break after a macOS update. `enabled:false` may need a
  replug to turn the display back on. Rotating the built-in display can crash displayplacer (its own warning).
  Resolution semantics for rotated displays were not verified.
- **Timing**: debounce and wait times are heuristics. Slow monitors may need a longer wait after wake.
- **Displays deep link**: the System Settings link is undocumented. The app falls back to the Displays pane file and
  then to System Settings itself. It cannot detect if macOS opens the wrong pane.
- **Clamshell and mirroring** follow displayplacer's behavior and were tested with synthetic data only.

### Ad-hoc signing

The app is signed ad-hoc (no Developer ID):

- A locally built app has no quarantine flag, so Gatekeeper does not block it.
- If you copy the app to another Mac through a download, macOS adds quarantine. Right-click the app and choose Open
  once.
- After a reinstall, macOS may treat the new signature as a new app for Login Items. If the Launch at Login toggle
  shows off, turn it on again. Launch at Login works best when the app runs from `/Applications`.

### iCloud Drive

If the project folder is in iCloud Drive with "Optimize Mac Storage", macOS can evict source files. The installer
detects this and stops. Download the folder first (in Finder, "Download Now"), or keep the project in a local
folder. Build products are always written to `~/Library/Caches/DisplayManager-build`.

## Uninstall

1. Turn off **Launch at Login** in the menu (or remove DisplayManager in System Settings › General › Login Items).
2. Quit DisplayManager from its menu.
3. Remove the app, the data and the preferences:

```bash
rm -rf /Applications/DisplayManager.app
```

```bash
rm -rf ~/Library/Application\ Support/DisplayManager
```

```bash
defaults delete com.bachana.DisplayManager
```

Optionally remove the build cache:

```bash
rm -rf ~/Library/Caches/DisplayManager-build
```

## Build from source

The project is a Swift package (Swift 6 language mode, strict concurrency). The scripts keep build products outside
the source folder and choose a toolchain for their own process only. They never run `xcode-select` or change system
settings. They try, in order:

1. the active developer directory (`DEVELOPER_DIR` or `xcode-select -p`);
2. an Xcode in `/Applications` or `~/Applications`, even when it is not selected;
3. the Command Line Tools.

On the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode. When a toolchain cannot build
SwiftUI with its default SDK, the scripts use its previous macOS SDK instead and print a note. The Command Line Tools
install the current and the previous SDK. If nothing works, the scripts list what they checked and how to fix it.

| Task | Command |
|---|---|
| Debug build | `Scripts/swift.sh build` |
| Unit tests | `Scripts/swift.sh test` |
| App bundle | `Scripts/build-app.sh release` (or `debug`) |
| Regenerate the app icon | `Scripts/generate-icon.sh` |

Project layout:

| Path | Contents |
|---|---|
| `Sources/DisplayManagerCore` | Pure logic: models, displayplacer parsing and commands, matching, automation policy, persistence format. Fully unit tested |
| `Sources/DisplayManager` | The app: AppKit/SwiftUI UI, menu bar, system adapters (CoreGraphics, IOKit, SMAppService, Carbon hot keys) |
| `Tests/DisplayManagerCoreTests` | Swift Testing unit tests with fixtures |
| `Packaging` | `Info.plist` and the app icon |
| `Scripts` | Toolchain selection, build, icon generation |
| `install.sh` | Build and install into `/Applications` |
