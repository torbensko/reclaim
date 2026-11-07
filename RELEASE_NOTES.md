# Reclaim 1.3.0

Reclaim now finds more old developer output and puts individual cleanup suggestions together in Overview.

- Review Recommended, Review first and Protected items across sources, select individual items, and confirm a batch cleanup. Source tabs retain the detailed breakdowns and protection reasons.
- Lead Overview with Recommended and All options reclaimable estimates, keeping physically free SSD space and macOS's available-space estimate alongside. Docker estimates and unknown snapshot sizes remain separate.
- Find recognised Swift build output, Next.js caches and Node dependencies in repositories and registered worktrees. Generated output must be unchanged for at least seven days and pass current-use checks; dependencies require review before removal.
- Offer manual removal of old Xcode build and index data even when the source project still exists. Active work stays protected; scheduled Xcode cleanup remains limited to orphaned output.
- Inspect known Codex and Claude data locations. Diagnostic logs unchanged for 30 days may be reviewed for cleanup; conversation history remains protected because it cannot be rebuilt.
- Add a confirmed, administrator-authorized shortcut to macOS's automatic Time Machine backup setting, with read-back verification. Cleanup never changes that setting.
- Keep local builds named Reclaim in the dist folder, with a separate internal identity and build provenance in About. Signed releases continue to receive in-app updates.

Requires macOS 14 or later. The app and background helper include Apple Silicon and Intel binaries. Interactive verification has been on Apple Silicon with macOS 27; Intel and older supported versions have not received the same hands-on testing.

Removing local snapshots permanently removes those restore points. External Time Machine backups are excluded. Reported footprints are not a promise of recovered space.
