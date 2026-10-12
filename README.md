# Greyscale Schedule

A local macOS 26 utility that enables the system greyscale display filter on a
schedule and exposes a native Control Centre control.

## Install with Homebrew

Requires Apple Silicon and macOS 26 or later.

```sh
brew install --cask niconekoru/tap/greyscale-schedule
```

If macOS blocks the first launch, remove the quarantine attribute from this app.

```sh
xattr -rd com.apple.quarantine /Applications/Greyscale\ Schedule.app
```

Open Greyscale Schedule once, choose a schedule and click Save Schedule, then
click Add Control if its tile isn't already in Control Centre. Refresh Control
is under Setup and maintenance. Later tile clicks stay windowless.

The default schedule turns greyscale on at 10 PM and off at 5 AM in the Mac's
local time zone. Sunset to Sunrise uses macOS's current sun times without a
separate location prompt or requiring Night Shift to be enabled. Settings remain
local to the Mac. Changes are drafts until Save Schedule is clicked. Saving an
enabled schedule applies it immediately; Off stops automation and leaves the
current display alone. Equal custom times mean an all-day schedule.

Use Uninstall under Setup and maintenance to remove its schedule and Control Centre tile.
Then remove the Homebrew installation record and remaining local settings with
`brew uninstall --cask --zap greyscale-schedule`.

## Repository layout

| Location | Contents |
| --- | --- |
| `Sources/GreyscaleSchedule/` | App, helper, and Control Centre Swift source |
| `Configuration/` | App and extension plists and widget entitlements |
| `Resources/AppIcon.iconset/` | Source icon assets |
| `GreyscaleSchedule.xcodeproj/` | App and extension build targets |
| `Tests/` | Core regression tests |
| `scripts/` | Test, build, and packaging entry points |
| `docs/README.txt` | Read Me included in the installer |
| `.build/` | Generated Xcode products, test builds, and module caches, ignored by Git |
| `outputs/` | Current installer output, ignored by Git |
| `archive/` | Local historical builds, backups, and diagnostics, described in its README |

The build does not use anything in `archive/`. A fresh checkout contains all
required source and assets. Signing still uses a local Apple Development identity.

## Architecture

- `DisplayState.swift` serializes display operations and verifies actual state
  before publishing changes. The backend and clock are injectable for tests.
- `DisplayFilter.swift` contains the private macOS compatibility boundary.
  It reads the migrated MediaAccessibility preference with an explicit refresh,
  falling back to UniversalAccess on systems without that preference.
- `ControlService.swift` runs an on-demand per-user XPC helper. It accepts only
  the app or widget signed by the same development team. It also observes changes
  made outside the app and refreshes the control when actual state changes.
  macOS can discard a refresh while the tile is hidden. One coalesced retry runs
  every two seconds until the tile's value provider samples the confirmed state.
  App/status reads cannot acknowledge that refresh. Retries stop after sampling
  or removal of the tile, and helper restarts publish their first confirmed state.
- `ControlRequest.swift` contains the shared XPC interface, cancellable client,
  exactly-once reply handling, and headless execution tracker. There is no file
  queue or response polling. Existing legacy queue files are not replayed.
- `ControlExtension.swift` reads fresh state from that helper. Its `SetValueIntent`
  uses the same helper as the app, URLs and schedule. Dynamic dispatch starts
  headlessly and never requests foregrounding. The execution tracker prevents
  automatic settings-window presentation and waits for all outstanding commands.
  A background-only mode was rejected by this Mac before `perform()` with a
  missing action binding, so it is deliberately not used.
- `Schedule.swift` saves one complete versioned settings record and migrates older
  records and keys without losing custom times or the enabled setting.
  Disabled automation has no calendar agent and never changes a manual choice.
  Manual changes last until the next scheduled boundary or an explicit save of an
  enabled schedule.
- `SolarSchedule.swift` isolates a read-only CoreBrightness compatibility boundary.
  It validates current absolute sunrise/sunset dates from `BlueLightSunSchedule`.
  Missing, stale or contradictory data fails closed, with no guessed times or
  silent custom-time fallback. Solar mode has a separate background launch agent
  that rechecks system dates within a minute and schedules the exact next boundary.
  Wall-clock deadlines catch up after sleep or clock changes. Polls do not undo
  manual choices. Confirmed boundaries are persisted so a scheduler restart also
  preserves a manual choice until the next boundary. Explicit saves reapply the
  current phase and recheck it if a slow write crosses a boundary.
- `ControlCenterIntegration.swift` isolates the private layout format. Refresh
  keeps the tile identifier, size and position. Both preference blobs are validated
  before changes, with exact-byte rollback on write failure. Unrelated controls
  and unknown fields are preserved. Saving a schedule never installs a tile.
  Legacy tiles are migrated in place or removed when a current tile already exists.
  The obsolete extension is disabled to prevent backup builds appearing in the gallery.
  Command-line installation opens the app once through Launch Services before
  enabling the tile. Later refreshes and tile actions do not open settings.
- `ControlRequestAgent.swift` refreshes the helper on a same-path app upgrade
  and retires a running control extension whose signature no longer matches
  the installed files. It checks the exact executable path and verifies the
  replacement before stopping anything. Up-to-date extensions and other apps are
  left alone. CodeDirectory hashes also catch a still-valid process kept alive
  by a moved backup of the previous app. The helper's signing requirements stay
  unchanged.
- `SettingsWindow.swift` contains the native settings window and its presentation
  state. It uses a native pop-up for Off, Custom and Sunset to Sunrise, an explicit
  Save button, a reserved unsaved-change dot, and one confirmed-state manual button.
  Setup and maintenance starts collapsed. Errors and recovery appear inline.
- `AppDelegate.swift` coordinates settings actions and legacy URL-command handling.
  Failed state reads appear as unavailable, not off. Installation work runs away
  from the UI thread, and uninstall errors are surfaced rather than ignored.
  Normal launches show settings without waiting for activation. Intent launches
  stay headless, and an explicit reopen can show settings after a tile action.
  The window is laid out and drawn before showing, with no redundant activation
  when the app is already active.
  Slow status reads are coalesced, cancelled when superseded by an action, and
  cannot overwrite a newer confirmed state or an in-progress time edit. Draft
  controls are locked while saving. A failed display update is distinguished
  from an unsaved configuration.
- `GreyscaleSchedule.xcodeproj` builds and embeds both executable targets.

The extension must be built by Xcode because WidgetKit extensions require the
`_NSExtensionMain` entry point. Do not compile it as a standalone Swift binary.

## Build

```sh
./scripts/build.sh
```

The script uses `/Applications/Xcode.app`, locates an Apple Development signing
identity, builds the app and extension, adds the icon, signs both bundles, and
runs the regression suite and internal invariants. It also checks the extension
entry point and headless dynamic intent metadata. Override the defaults with
`DEVELOPER_DIR` or `GREYSCALE_SIGN_IDENTITY` when needed.
After removing the build product's temporary registration, the script restores
the installed app's registration and prepares its helper and control runtime.
This keeps its tile's action binding intact and retires a stale widget process.
After replacing an installed app, run its `--install-helper` command before the
one-time normal open. Registration alone can leave the previous extension
running and produce a blank tile.

## Package

```sh
./scripts/package.sh
```

The installable DMG is written to `outputs/GreyscaleSchedule-v1.10.0-macos-arm64.dmg`.

## Publish a release

Keep the existing release tag and asset immutable. For a new version, update the
Xcode app and extension version together and update the installer Read Me. Commit
and tag that source, then run `./scripts/package.sh` from the tagged checkout.
The package script runs the tests, verifies both signatures, checks the headless
intent metadata, and verifies the DMG.

Upload `GreyscaleSchedule-vVERSION-macos-arm64.dmg` to the matching `vVERSION`
GitHub release. Use `gh release create --verify-tag` after pushing the tag to
avoid publishing from the wrong source revision.

The `update greyscale cask` workflow in
[NicoNekoru/homebrew-tap](https://github.com/NicoNekoru/homebrew-tap) accepts the
release version. It downloads the published asset and calculates its SHA-256
before updating the cask. It also accepts a `greyscale-schedule-release`
repository dispatch with a `version` field.

Verify each update without replacing the maintainer's installed app or altering
the real display filter.

```sh
brew audit --cask --strict niconekoru/tap/greyscale-schedule
brew fetch --cask niconekoru/tap/greyscale-schedule
brew install --cask --dry-run niconekoru/tap/greyscale-schedule
```

## Tests

```sh
./scripts/test.sh
```

The XCTest suite compiles the production core with fake display and preference
backends. It covers confirmation/reload ordering, external changes, overlapping
commands, failures, cancellation and deadlines, XPC round trips, hidden-tile refresh
retries and acknowledgements, helper restarts, first-open behaviour, headless lifetime,
the settings window's first frame, stable dirty/save layout, native control alignment,
draft/save failures, slow and stale status replies, and manual-control errors,
schedule boundaries and disabled automation, settings migration, stable tile
placement, legacy migration, malformed layouts, ownership, idempotence and rollback. It does not
change the real display filter, Control Centre layout or installed agents.
Solar tests cover exact boundaries, unavailable/stale dates, wake catch-up, expired
snapshots, manual choices across polls and restarts, and versioned settings migration.

For native integration verification, click the installed tile on and off and
check the `Control intent requested` and `Tile sampled confirmed` log events.
This check is separate from the fake-backend suite and catches OS action-binding
or extension-discovery failures that a direct helper test cannot detect.
Also check a scheduled change with settings closed and Control Centre hidden.
On revealing the tile, it should refresh without a click. Reload requests repeat
every two seconds, though macOS can throttle when it processes them.
The helper logs `refresh acknowledged` when the provider reads that state.

Cancellation or expiry prevents a command that has not committed from writing.
Once macOS has accepted a write, the helper completes verification even if the
caller disconnects. It never rolls back over a newer command. Read errors and
unconfirmed writes are returned to the caller.

## Compatibility

macOS has no public greyscale setter, system solar-times API, or API for inserting
an arbitrary control into its layout. Those private boundaries remain isolated and can change with an
OS update. The widget stays sandboxed with one named Mach-service lookup exception.
No app group, global file access or network permission is required.

Project names and internal identifiers use Grey spelling. The two private Apple
function names in `DisplayFilter.swift` retain their exact SDK spelling because
symbol lookup must match macOS. Archived signed builds remain unchanged.

Background execution follows Apple's
[App Intents runtime modes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes).
The helper uses a
[Mach-service XPC listener](https://developer.apple.com/documentation/foundation/nsxpclistener).

## Runtime checks

```sh
"/path/to/Greyscale Schedule.app/Contents/MacOS/Greyscale Schedule" --self-test
"/path/to/Greyscale Schedule.app/Contents/MacOS/Greyscale Schedule" --status
"/path/to/Greyscale Schedule.app/Contents/MacOS/Greyscale Schedule" --read-system-state
"/path/to/Greyscale Schedule.app/Contents/MacOS/Greyscale Schedule" --solar-status
```

`--status` reads through the helper. `--read-system-state` is a read-only diagnostic
that bypasses it. `--solar-status` validates system sun dates without changing the
schedule, display or Night Shift settings. `--install-control` installs or repairs the helper and native tile
without replacing an existing tile. Its first run opens settings before publishing
the tile because macOS rejects App Intent actions from an app that has never been
opened normally. Opening settings manually also completes this one-time step.
If the launch fails, installation stops and reports the error. Later refreshes and
all tile actions remain windowless. `--install-schedule` saves the current local
settings independently of Control Centre.

For an explicitly requested identifier migration, `--migrate-control-identity`
takes the previous app identifier, extension identifier, control kind, and display
name. It changes only matching archived identities and their standard labels.
Tile identifiers, placement, sizes, custom names, and unrelated controls remain
unchanged. Settings and login-agent migration are separate installation steps.
