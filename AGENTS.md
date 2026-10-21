# Product intent that must survive development

Read `docs/PRODUCT.md` before changing storage, snapshot, or purge behaviour.

The user experiences builds stopping for lack of disk space when Finder still
shows 100+ GB available but only roughly 5 GB is physically free. Coding/build
tools do not always cause macOS to reclaim purgeable storage in time. This app
exists to make that distinction visible and let the user request reclamation of
known local sources before continuing work. Preserve this motivation as the
app expands beyond Time Machine.

Reclaim is an opinionated developer-storage utility. It covers local Time Machine
snapshots, selected Xcode generated build/index data, local Docker images and
build cache, and identified browser artifacts. Inspect only known source roots;
do not perform broad disk scans. Time Machine scope stays on the internal startup
Data volume: `/System/Volumes/Data`. Do not enumerate or delete external backups
or network destinations. Do not describe all local
snapshots as definitely pending backup: macOS does not expose that per-snapshot
state, and it also retains snapshots after successful backups.

Preserve these constraints:

- Distinguish actually free APFS container space from the OS's available-space
  estimate, which includes potentially reclaimable data.
- Do not claim that their difference is all Time Machine data or that each
  snapshot has a known reclaimable size.
- The primary action asks macOS to thin local snapshots for a requested amount.
  Reclamation is best effort, not a guarantee.
- Individual deletion is constrained to exact, validated Time Machine snapshot
  names on the local Data volume. Never use `tmutil deletelocalsnapshots <date>`:
  it affects matching dates on all mounted disks.
- No cleanup on app launch and no backup-setting changes. Automatic cleanup
  requires an explicitly confirmed schedule; Time Machine always stays manual.
- Confirm manual purges in the app. Use system authorization for snapshot
  operations, never for scheduled cleanup.
- During development, use mocks for destructive command tests. Read-only live
  checks are permitted. Do not delete the user's actual snapshots to test code.

Build with `swift build`, test with `swift test`, package with
`./scripts/build-app.sh`. This is a SwiftUI macOS app, not a website.

Use Activity Monitor as the UI reference: Overview first, source tabs in the top
toolbar, a native table, compact storage figures and source-specific controls.
No navigation sidebar or dashboard cards. Put explanations in help/details.

Reclaim is a conservative safety net. Coding tools should own worktree and cache
lifecycle; do not continually clear data belonging to active development. Unknown
ownership or failed usage checks mean keep the data. Apply the same policy to
manual and scheduled cleanup, and revalidate before removal.

Xcode cleanup may remove only Build and Index.noindex/Index inside recognized
DerivedData projects whose source workspace AND parent folder are confirmed gone,
not associated with any registered worktree, and inactive for at least seven days.
Inspect direct repositories in ~/repos and ask Git for registered worktrees,
including missing and external paths. Any surviving source or registered worktree
is protected regardless of age. Require complete inventory, no Xcode/build tools
running and no process/open-file references. Preserve SourcePackages, archives,
source projects, and simulator data. Reject symlinks and volume crossings.

Docker commands must pin a local Unix socket rather than use the active context.
Relay Docker's usage definition: both running and stopped containers count. Only
untagged images older than 24 hours with zero container references and no reported
active builder are manual candidates. Tagged images remain protected even when
Docker says unused. Build cache is inspection-only because ownership cannot be
verified; never prune it, containers or volumes, or force image removal.

Browser caches are inspection-only. Chrome signing copies in the exact per-user
code_sign_clone root require strict bundle validation, at least 24 hours of age,
and no matching executable, mapped-file or open-file references. Match individual
copies to process IDs; unrelated Chrome instances can remain running. Failed or
incomplete inspection keeps the copy. Do not follow symlinks or cross volumes.

Allocated file footprints can overlap. Use macOS ATTR_CMNEXT_PRIVATESIZE for
separate private-file byte counts; unsupported values stay unknown. Exclude
multiply linked files from private totals and explain that group deletion can
free additional shared blocks. Never present either figure as guaranteed recovery.
Time Machine's listing command lacks these sizes, though Disk Utility exposes
Private Size and Cumulative Size. Do not imply macOS cannot measure them; do not
substitute the free/available gap or sum cumulative sizes.

Schedules must be off by default, use only these allowlisted sources, prevent
overlapping runs, and offer explicit backed-up takeover of the recognized legacy
Chrome service. Never enable a real schedule or replace the user's service as a
development test. Test job registration and rollback with mocked launchctl.
Test destructive paths only with generated fixtures or mocked commands.
