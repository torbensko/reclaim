# Reclaim 1.2.0

Reclaim now keeps its storage readings current after cleanup and supports signed in-app updates.

- Add Sparkle update checks for published releases, with a Check for Updates menu and signed update downloads. Existing installations need this release installed manually once.
- Separate Reclaim Dev builds from the production app and show build details in About.
- Refresh all source inventories after cleanup, immediately update free space and watch for delayed disk-space release. Show which sources are still loading and when space was last checked.
- Find old, unused Docker images even when tagged, deduplicate their aliases, and recheck every reference before removal.
- Lead each source with its reclaimable-space figure, retain protected items below safe items, and provide a Safe only filter and Select all control.

Requires macOS 14 or later. The app and background helper include Apple Silicon and Intel binaries. Interactive verification has been on Apple Silicon with macOS 27; Intel and older supported versions have not received the same hands-on testing.

Removing local snapshots permanently removes those restore points. External Time Machine backups are excluded. Reported footprints are not a promise of recovered space.
