# Product intent that must survive development

Read `docs/PRODUCT.md` before changing storage, snapshot, or purge behaviour.

The user experiences builds stopping for lack of disk space when Finder still
shows 100+ GB available but only roughly 5 GB is physically free. Coding/build
tools do not always cause macOS to reclaim purgeable storage in time. This app
exists to make that distinction visible and let the user request reclamation of
known local sources before continuing work. Preserve this motivation as the
app expands beyond Time Machine.

Reclaim is an opinionated developer-storage utility for this user’s tools. It covers
local Time Machine snapshots, Xcode and repository-generated build data, local
Docker images and build cache, browser artifacts, and Codex/Claude diagnostic data. Inspect only known source roots;
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
- No cleanup on app launch. The October 26 request permits an explicit,
  confirmed shortcut to macOS's automatic-backup setting using tmutil enable/disable
  with system authorization. Label it as a macOS setting, read back before showing
  success, and keep unreadable state unknown. Never change it on launch, cleanup,
  or a schedule, and never change the user's real setting as a development test.
  Automatic cleanup requires an explicitly confirmed schedule; Time Machine
  cleanup always stays manual.
- Confirm manual purges in the app. Use system authorization for snapshot
  operations, never for scheduled cleanup.
- During development, use mocks for destructive command tests. Read-only live
  checks are permitted. Do not delete the user's actual snapshots to test code.
- After every cleanup outcome, rescan sources and measure free/available space
  independently, immediately and repeatedly for about a minute. Show unfinished
  scans, measurement time, and observed change without attributing it all to cleanup.
  Cancel old polling on new work; late readings must not overwrite new state.
  Failed readings stay unknown. Test delayed release and failures with mocks.

Build with `swift build`, test with `swift test`, package with
`./scripts/build-app.sh`. This is a SwiftUI macOS app, not a website.

Keep production and development separate. Local builds produce
`dist/Reclaim.app`, named Reclaim just like the release; do not add a Dev suffix
or create a second local app. The dist folder is the user's testing workflow.
Keep a distinct internal bundle ID to prevent launch/update collisions and show
the channel, version, build and location in About. Run local builds from dist instead
of replacing `/Applications/Reclaim.app`. Only signed, notarized releases belong
in Applications. Sparkle runs only in production (never previews, demo or tests),
uses the signed release feed, and waits for storage work before restarting.
Publish the exact notarized ZIP in both the download and update feed; validate its
Ed25519 signature against the committed public key. Never log or commit private
update keys. Preserve version, build channel, source revision and time in About.
Do not install a real update or change schedules as a development test.

Use Activity Monitor as the UI reference: Overview first, source tabs in the top
toolbar, a native table, compact storage figures and source-specific controls.
No navigation sidebar or dashboard cards. Put explanations in help/details.
Each source page leads with its reclaimable-space figure; SSD free/available
space remains alongside it. Label Docker's whole-store estimate and any kept
unused images, and keep build cache inspection-only. Xcode/Browser totals use
private bytes from items safe to clean only; missing measurements stay unknown. Snapshot
sizes remain unknown unless there are no snapshots. Filters and selection do
not change source totals. Do not sum overlapping footprints for the headline.
The November 7 revision makes Overview an actionable list of individual items
across sources, with checkboxes, per-item review, and a confirmed batch action.
Overview's top figures are Recommended and All options (recommended plus review)
reclaimable estimates. Sum only measured private file bytes across disjoint cleanup
paths; incomplete file inventories and missing measurements stay unknown. Report
Docker's whole-store estimate and unknown snapshot sizes separately. Keep physically
free SSD space and macOS's available estimate smaller alongside these figures.
Show all discovered data by default: Recommended, Review first, then dimmed
Protected rows. “Recommended only” optionally hides the latter groups. Ordering
is automatic. Keep physically free and available space distinct; no combined
recovery promise. Source tabs provide details and coverage failures stay visible.
All listed items are relevant; protection means cleanup safety could not be
established. Keep found/safe counts visible even when the filter excludes
every item, with a way to show protected items. Show each protection reason
and Xcode's source-project association; ownership does not mean currently in use.
Text search may hide non-matches. “Select all” selects/deselects the rows shown by
the current filters. Mixed selections remove only safe items, with the safe count
shown before confirmation; protected rows stay inspectable. Safety checks still
run again before removal. Changing filters or source clears the selection.

The November 7 clarification favours reclaiming old rebuildable output even when
its source project survives. Project existence or worktree registration establishes
ownership, not current use. Recommended items have recognised generated identity,
at least seven days without recorded changes, and successful current-use checks.
Review first explains extra consequences such as dependency downloads or loss of
old diagnostics. Unknown identity, failed inspection, or detected current use stays
Protected; review is not an override for failed checks. Do not call modification
times “last used”: they are evidence, not a complete usage history. Sources and
worktrees are never removed. Keep new cleanup sources manual only.

Manual Xcode cleanup may remove only Build and Index.noindex/Index inside recognised
DerivedData projects, including existing source projects, after seven days of
inactivity and successful source/output usage checks. Scheduled Xcode cleanup stays
orphan-only: source workspace AND parent folder gone, no registered worktree.
Inspect direct repositories in ~/repos and ask Git for registered worktrees,
including missing and external paths. Require complete inventory, no Xcode/build
tools running and no process/open-file references. Preserve SourcePackages,
archives, source projects, and simulator data. Reject symlink roots and volume
crossings. Revalidate before removal; destructive tests use generated fixtures.

Projects inspect only recognised Swift .build output (never checkouts/artifacts or
all of .build), Next.js .next/cache, and root node_modules in inventoried repositories.
Require tool identity, no Git-tracked contents, seven-day modification age, and no
project process/open-file users. Node dependencies require a recognised lockfile and
Review first explaining reinstall/downloads and loss of local dependency edits.
Never follow links or delete their destinations. Reject linked cleanup roots and
volume crossings. Recheck identity, inventory, tracked contents, age and use.

AI tools inspect only known Codex/Claude log and history roots. Manual review may
remove exact recognised diagnostic logs unchanged for 30 days and not in use.
Conversation/session history is unique data, not rebuildable; keep it and explain
why. Do not read transcript contents or remove databases, credentials, settings,
skills or worktrees. Generated data in registered agent worktrees uses Projects.

Docker commands must pin a local Unix socket rather than use the active context.
Relay Docker's usage definition: both running and stopped containers count. The
October 22 correction permits manual cleanup of tagged AND untagged unused images
older than 24 hours with zero container references and no reported active builder.
A tag is an identity, not evidence of active use. Inspect all tags/digests because
system df may expose only one alias; display and count each immutable image ID
once. Relay Docker's whole-store reclaimable estimate separately from selected
sizes and physical SSD recovery. Recheck usage, references and tag-to-ID mappings
before removing each alias. Stop on new tags, new users, retagging, or failed
checks; never force removal. Use --no-prune so unselected parents stay intact.
Confirm that all local tags of the selected images are included. Docker cleanup
stays manual. Build cache is inspection-only because ownership cannot be verified;
never prune it, containers or volumes.

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
