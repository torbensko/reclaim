# Reclaim 1.1.0

First public release of Reclaim, a native Mac utility for known developer storage sources.

- Show physically free SSD space separately from macOS's available-space estimate.
- Inspect local Time Machine snapshots, Xcode build data, Docker usage and Chrome signing copies.
- Protect active projects, registered worktrees and data still in use; keep data when checks are incomplete.
- Request local snapshot reclamation manually, or opt into conservative scheduled cleanup for eligible Xcode and Chrome data.
- Use a compact native interface and the purple Reclaim icon.

Requires macOS 14 or later. The app and background helper include Apple Silicon and Intel binaries. Interactive verification has been on Apple Silicon with macOS 27; Intel and older supported versions have not received the same hands-on testing.

Removing local snapshots permanently removes those restore points. External Time Machine backups are excluded. Reported footprints are not a promise of recovered space.
