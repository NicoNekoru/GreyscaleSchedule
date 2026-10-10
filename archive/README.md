# Local archive

These files predate the repository cleanup. They are preserved for recovery and
debugging, excluded from Git, and unused by the current build scripts.

- `builds/` contains old app products, Xcode DerivedData, and test caches.
- `backups/` contains previous installed apps and saved upgrade settings.
- `installers/` contains old disk images and packaging staging directories.
- `diagnostics/preferences/` contains captured Control Centre layouts and settings.
- `diagnostics/control-archives/` contains earlier native action-binding snapshots.
- `diagnostics/probes/` contains experimental programs and inspection scripts.
- `diagnostics/screenshots/` contains old screen captures.
- `diagnostics/signing/` contains local signing experiments and certificates.

Do not launch or register the old apps or probes. They may use obsolete widget
identities or change system settings. Historical tools can refer to their original
paths and are not maintained entry points.

Only this README is tracked. Signing material and machine-specific preferences
must stay local. Current builds go into `.build/`, and current installers go into
`outputs/` at the repository root.
