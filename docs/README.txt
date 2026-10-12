Greyscale Schedule 1.10.0 for macOS 26

Install
1. Drag Greyscale Schedule to Applications.
2. Open it, choose a schedule and click Save Schedule.
3. Click Add Control if Greyscale is not already in Control Centre.

Control Centre
- Click the signed Greyscale control to toggle the display filter immediately.
- The app and control are signed for this Mac with the configured Apple Development team.
- Control Centre clicks run entirely in the background and never open settings.
- The tile and app read the same confirmed system state from the background helper.
- Scheduled updates retry while the tile is hidden, until its provider samples the new state.
- Opening the app shows settings on the first launch, without needing a second click.
- Save Schedule does not recreate or move your Control Centre tile.
- Refresh Control under Setup and maintenance keeps an existing tile's size and placement.
- Command-line installation opens the app once before enabling the tile. Later refreshes stay windowless.
- Open the app once before adding its tile directly from the Control Centre gallery.
- Turning automation off leaves your manual greyscale choice alone.
- Update preparation replaces stale control extensions rather than leaving a blank tile.

If macOS blocks the first launch, run this command, then open the app again.
xattr -rd com.apple.quarantine /Applications/Greyscale\ Schedule.app
- Manual changes last until the next scheduled boundary or saving an enabled schedule.

Defaults
- Greyscale on: 10:00 PM
- Greyscale off: 5:00 AM
- The schedule follows the Mac's current local time zone.
- Sunset to Sunrise uses macOS's current sun times without a separate location prompt.
- Solar scheduling works with settings closed and respects manual choices until the next boundary.
- Unavailable system sun times are reported inline rather than replaced with guessed times.
- Equal custom times mean greyscale all day.
- Changes are saved only by clicking Save Schedule. A small dot marks unsaved changes.

Uninstall
Open Greyscale Schedule, expand Setup and maintenance and click Uninstall. This removes the login schedule,
Control Centre control, local settings and caches, then moves the app to the Trash.
If a cleanup step fails, the app reports the error rather than claiming success.
If installed with Homebrew, its installation record remains until removed with brew uninstall.

This locally built utility requires macOS 26 or later.
