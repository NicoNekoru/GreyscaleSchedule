# Greyscale Schedule

A local macOS 26 utility that enables the system greyscale display filter on a
schedule and exposes a native Control Centre control.

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
- `ControlRequest.swift` contains the shared XPC interface, cancellable client,
  exactly-once reply handling, and headless execution tracker. There is no file
  queue or response polling. Existing legacy queue files are not replayed.
- `ControlExtension.swift` reads fresh state from that helper. Its `SetValueIntent`
  uses the same helper as the app, URLs and schedule. Dynamic dispatch starts
  headlessly and never requests foregrounding. The execution tracker prevents
  automatic settings-window presentation and waits for all outstanding commands.
  A background-only mode was rejected by this Mac before `perform()` with a
  missing action binding, so it is deliberately not used.
- `Schedule.swift` saves one complete settings record and migrates older keys.
  Disabled automation has no calendar agent and never changes a manual choice.
  Manual changes last until the next scheduled boundary or an explicit save of an
  enabled schedule.
- `ControlCenterIntegration.swift` isolates the private layout format. Refresh
  keeps the tile identifier, size and position. Both preference blobs are validated
  before changes, with exact-byte rollback on write failure. Unrelated controls
  and unknown fields are preserved. Saving a schedule never installs a tile.
  Legacy tiles are migrated in place or removed when a current tile already exists.
  The obsolete extension is disabled to prevent backup builds appearing in the gallery.
- `AppDelegate.swift` contains the settings UI and legacy URL-command handling.
  Failed state reads appear as unavailable, not off. Installation work runs away
  from the UI thread, and uninstall errors are surfaced rather than ignored.
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

## Package

```sh
./scripts/package.sh
```

The installable DMG is written to `outputs/Greyscale Schedule 1.9.dmg`.

## Tests

```sh
./scripts/test.sh
```

The XCTest suite compiles the production core with fake display and preference
backends. It covers confirmation/reload ordering, external changes, overlapping
commands, failures, cancellation and deadlines, XPC round trips, headless lifetime,
schedule boundaries and disabled automation, settings migration, stable tile
placement, legacy migration, malformed layouts, ownership, idempotence and rollback. It does not
change the real display filter, Control Centre layout or installed agents.

For native integration verification, click the installed tile on and off and
check the `Control intent requested` and `Tile sampled confirmed` log events.
This check is separate from the fake-backend suite and catches OS action-binding
or extension-discovery failures that a direct helper test cannot detect.

Cancellation or expiry prevents a command that has not committed from writing.
Once macOS has accepted a write, the helper completes verification even if the
caller disconnects. It never rolls back over a newer command. Read errors and
unconfirmed writes are returned to the caller.

## Compatibility

macOS has no public greyscale setter or API for inserting an arbitrary control
into its layout. Those private boundaries remain isolated and can change with an
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
```

`--status` reads through the helper. `--read-system-state` is a read-only diagnostic
that bypasses it. `--install-control` installs or repairs the helper and native tile
without replacing an existing tile. `--install-schedule` saves the current local
settings independently of Control Centre.

For an explicitly requested identifier migration, `--migrate-control-identity`
takes the previous app identifier, extension identifier, control kind, and display
name. It changes only matching archived identities and their standard labels.
Tile identifiers, placement, sizes, custom names, and unrelated controls remain
unchanged. Settings and login-agent migration are separate installation steps.
