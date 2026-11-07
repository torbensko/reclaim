# Why Reclaim exists

## The problem

The user runs build tools that check immediately free SSD space. They have
observed Finder showing **100+ GB available** while only approximately **5 GB is
actually free**. Builds stop for insufficient space, even though macOS considers
additional storage purgeable. In this workflow, the build tools do not appear
to trigger reclamation soon enough, so development unnecessarily comes to a halt.

The app's purpose is to expose this discrepancy and provide an explicit way to
release storage held by known sources before resuming a build. It began with
local Time Machine snapshots and now covers selected developer caches and artifacts.
This motivation is the basis for product decisions, not an incidental feature.
The figures above describe the user's reported experience, not live measurements.

## What the user means by snapshots

The target is snapshots held on the Mac's internal SSD, especially while Time
Machine is waiting for its backup destination to become available. These are
local restore points. They are not the historical backups already stored on an
external disk or a network destination.

macOS also retains local snapshots for other reasons, including after a successful
backup. Its supported tools do not provide a reliable per-snapshot “still waiting
to back up” flag. The UI must say **local snapshots**, not invent a pending queue.
Removing one can remove the only historical copy of a changed or deleted file
that has not reached the backup destination.

## Required experience

1. Show physically free APFS container space prominently.
2. Separately show macOS's estimate of space available for important usage.
   It can include reclaimable data; it may differ from Finder's calculation.
3. Explain why a build tool may run out of room despite a larger available figure.
4. List only recognized Time Machine local snapshots on the internal startup Data
   volume, with creation timestamps and reported purgeability.
5. Make “Reclaim space” the main action. Let the user set a byte target and
   reclamation urgency, then ask macOS to thin snapshots on that volume.
6. Offer confirmed deletion of selected local Time Machine snapshots.
7. Refresh after success, cancellation, or failure. Show the new free-space
   measurement; any observed change is not proof that all of it came from the
   operation because other applications can read, write, and reclaim space.
8. Handle permissions, partial deletion, an empty list, stale selections, and
   unsupported volumes without suggesting that a failed operation succeeded.

After every manual cleanup outcome (including failure and cancellation), rescan
all source inventories and fetch fresh SSD free/available readings independently.
Measure a fresh baseline before cleanup; never compare against a stale display.
Take a reading immediately afterward, repeat over about a minute to catch delayed
APFS/Docker release, and take another reading when inventory refresh finishes.
Slow Xcode or Browser inspection must not delay publication of free-space readings.
Name the sources still being scanned, show a last-checked time, distinguish the
cleanup command finishing from the follow-up checks, and explain disabled controls.
Controls remain disabled until full inventory checks finish, but the observation
period alone does not prevent a new action. A new refresh/cleanup cancels previous
polling; late results cannot overwrite the new readings. Failed measurements are
unknown, never zero or silently retained stale values. Report observed free-space
change with its limits, not a guaranteed per-source recovery amount.

## Interface direction

The October 21 revision renames the app **Reclaim** and broadens it to an
opinionated developer-storage utility. The user wants specific known culprits,
not a disk scanner looking for arbitrary large files. Start with Overview and
provide Projects, Xcode, Docker, AI tools, Browser and Time Machine tabs in the toolbar, following
Activity Monitor's native table-based layout. The November 7 headline correction
makes Overview lead with **Recommended** and **All options** reclaimable estimates.
All options includes recommended and review items, never protected data. Use private
file bytes from complete source inventories, count overlapping cleanup paths once,
and leave missing measurements unknown. Keep Docker's whole-store image estimate
and unknown snapshot sizes visibly separate; never add their footprints to file
bytes. The figures describe the whole inventory, independent of filters/selection.
Physically free SSD space and macOS's available estimate remain alongside, smaller
and separately labelled; do not claim the latter is an exact Finder reading.
Each source page leads with a large
reclaimable-space figure above its table, keeping SSD free/available space alongside
it. The current internal drive needs only a small label; no sidebar or dashboard cards.

The source headline describes the entire source, unaffected by selection or table
filters. Docker promotes its own whole-store estimate as **potentially reclaimable**,
explicitly identifying unused images kept by Reclaim. Switching to Build cache
shows Docker's cache estimate with **inspection-only** next to it. Neither figure
is a total for safe or selected rows. Xcode and Browser show private bytes
from eligible items only (recommended and review), with shared-block recovery potentially additional.
If any safe item's private size is unknown, the headline stays unknown;
unmeasured kept items do not affect it. No safe items means zero. Time Machine
shows an unknown size while snapshots exist and zero only for a confirmed empty
inventory. Loading and failed source checks must never look like measured zero.
Keep measurement limitations in the short subtitle and help; do not sum overlapping
footprints or use the free/available gap to invent a reclaimable total.

Use the system's Liquid Glass toolbar on macOS 26 and later: grouped monochrome
action icons in one compact trailing group and a centered capsule-shaped source
control, as in Activity Monitor. Use principal placement so it stays centered
independently of the title and actions. Use AppKit's segmented control with the
tab role on macOS 27 and native large-control sizing for the selected segment.
The toolbar supplies one shared glass background; do not add a custom glass
effect or a second capsule. This keeps the selection and outer padding proportional.
Keep intrinsic sizing and standard keyboard/accessibility behavior rather
than painting custom glass backgrounds. Package against the actual current SDK
while keeping the macOS 14 deployment target for older systems.

Keep controls compact. Put supporting explanations in help/details and the full
cleanup consequences in confirmations. An unavailable source must be visible as
unavailable rather than appearing to contain zero bytes. Avoid a combined “space
you will recover” total: APFS copies, snapshots and Docker layers share blocks.

## Known cleanup sources

The November 7 clarification broadens manual cleanup to old, recognised rebuildable
output in surviving projects. This app is tailored to the user's tools. Rebuilding
is an acceptable cost; interrupting active work or losing source/history is not.
An existing repository or registered worktree establishes ownership and must not
alone block removal of its old generated output. Unknown identity or failed usage
checks still protect data. Modification times and Xcode access metadata are evidence,
not a complete last-use history. Never label a modification timestamp “last used”.

Overview is the primary cleanup list, with individual items across sources,
checkboxes, Select all (visible rows only), Select recommended, per-item Review,
and Remove selected. Show Recommended, Review first, then Protected groups. The
optional Recommended only filter hides review and protected groups. Found and
category counts describe the full inventory, independent of filters. Search matches
names, paths and reasons. Filter/source changes clear selection. Protected rows stay
inspectable; mixed selections remove only eligible items. Confirm exact paths,
consequences, review items and Docker tags before removal. Revalidate every item,
stop on failed checks, and report partial outcomes. Time Machine appears as a separate
review decision: restore history cannot be rebuilt; request thinning, never invent
snapshot sizes. Empty/unavailable sources and unfinished scans remain distinguishable.

Recommended means recognised generated identity, sufficient age and successful
current-use checks, not a guarantee. Review first covers extra consequences such as
dependency downloads and lost troubleshooting records; it never overrides detected
use or failed checks. Keep sources, worktrees, settings, credentials and unique
conversation history. New sources are manual-only. Scheduled Xcode retains the
narrower orphan-only ownership policy while sharing age and usage safeguards.

- **Projects:** Inspect direct repositories in `~/repos` and Git's registered
  worktrees, including Codex/Claude worktrees. Recognise Swift `.build/out` through
  its manifest/workspace-state and Products/Intermediates layout, plus older macOS
  target-triple debug/release folders. Never offer all of `.build`, dependency
  checkouts, repositories or downloaded artifacts. Recognise `.next/cache` only
  with a Next.js package manifest. Root `node_modules` requires a package manifest
  and recognised lockfile and is always Review first: reinstall may need downloads,
  credentials and scripts; local edits inside dependencies would be lost. All need
  seven days without contained modifications, no Git-tracked contents, complete
  repository inventory and no current project process/open-file users. Revalidate
  before removal; reject linked roots and volume crossings and never follow links.
- **AI tools:** Inspect exact Codex `~/.codex/log` and Claude `~/.claude/debug` roots
  for recognised diagnostic filenames. Logs unchanged for 30 days and not in use
  can be manually reviewed; removing them loses old troubleshooting evidence.
  Show Codex sessions/archived sessions and Claude project session data as Protected
  because unique history cannot be rebuilt. No transcript contents are read.
  Databases, settings, credentials and source worktrees are never cleanup targets.
  Registered agent worktree build/dependency artifacts appear under Projects.
- **Xcode:** Manual cleanup can remove Build, Index.noindex and Index from recognised
  DerivedData projects whose sources still exist. Require complete inventory,
  seven days of inactivity, no Xcode/build tools, and successful source/output
  process and open-file inspection. Recheck identity, age and usage before removal.
  Preserve SourcePackages, logs, archives, simulators and source projects. The
  scheduled policy still requires source workspace AND parent folder confirmed
  gone and no registered worktree, including missing/external registrations.
- **Docker:** Pin the local Unix socket. The October 22 correction makes old,
  unused tagged images available for manual cleanup, matching the type of images
  shown in Docker Desktop's unused-image list. Tags alone do not establish use.
  Retain the 24-hour minimum, running/stopped container checks and reported-builder
  guard. Inspect all tags and digest references: `system df` may report only one
  tag for an image that has many. Display one row per immutable image ID, show its
  tags and creation age, and avoid counting aliases as separate stored images.
  Show Docker's whole-store reclaimable-image estimate separately; it can include
  images held by Reclaim's age rule and is not a selected-row or SSD recovery total.
  Before each removal, re-read usage and references. Stop on new references,
  container use, changed tag-to-ID mappings, inspection failure or engine refusal.
  For images with multiple references, remove verified aliases individually and
  finish by immutable ID when Docker allows it, always without force and with
  `--no-prune` to retain unselected parents. Confirm removal of all local tags;
  locally built images may need rebuilding. The multi-step operation is not atomic:
  it can stop after some tags or images have been removed, and concurrent Docker
  changes can race checks. Refresh and report partial outcomes. Build cache stays
  inspection-only because project activity cannot be reliably established. Never
  delete containers/volumes, prune build cache, use system prune or force removal.
  Docker cleanup remains manual.
- **Chrome:** The user's example lives under
  `X/com.google.Chrome.code_sign_clone/code_sign_clone.lWRU6k/Google Chrome.app.bundle`
  beside their macOS temporary folder. These are app signing copies, not generic
  browser profile data. Recognize strict clone names and the Chrome bundle ID;
  require at least 24 hours of age and no matching executable, mapped-file or
  open-file references. Match paths to individual process IDs, including canonical
  `/var` and `/private/var` aliases. An unrelated Chrome instance may stay running.
  A failed or incomplete check keeps the copy. Revalidate identity, age and usage
  before removal. Ordinary Cache/Code Cache folders are inspect-only.

### Size accounting

Allocated file footprints can overlap because of APFS clones and snapshots. Show
private bytes separately using the public `getattrlist` attribute
`ATTR_CMNEXT_PRIVATESIZE` for regular files. It describes file bytes not retained
by another clone or snapshot. Sum only known measurements; unknown stays `—`.
Deduplicate inode/device pairs within folders and conservatively exclude multiply
linked files from private totals, because a link can survive outside the target.
Exclude directory metadata. A collection of files can free more than its sum of
individually private bytes when shared extents lose their final reference. Do not
present either column as guaranteed recovery or combine Docker's image/cache
totals into an additive recovery total. Show Docker's unique/shared layer values.

The user recalled having snapshot sizes and explicitly asked to avoid attributing
the same file to multiple copies. The early headline numbers were whole-SSD
free/available space, not measured snapshot sizes. `diskutil apfs listSnapshots
-plist` on this Mac supplies names, dates encoded in names, IDs and purgeability,
but no private/cumulative bytes. Disk Utility **does** expose Private Size and
Cumulative Size. Explain the current reader limitation and provide a Disk Utility
shortcut; do not claim the OS cannot measure sizes. Leave unknown values blank
and never derive them from the free/available gap or sum cumulative figures.

## Regular purge jobs

The user already has an OS job that removes Chrome signing copies hourly when
older than 12 hours. They want Reclaim to own this responsibility. Scheduling is
an app feature, not a Codex reminder. It is disabled by default and enabled only
through confirmed schedule settings. Offer hourly, six-hourly and daily checks:
Chrome copies older than 24 hours and verified orphaned Xcode generated data
inactive for seven days, with the same usage checks as manual work; scheduled Xcode keeps the stricter orphan-only ownership policy.
Build cache cannot be scheduled. If an older configuration requests Docker cache
cleanup, record that it was kept and never run a prune. Skip busy or unverifiable sources.
Time Machine remains manual; do not install a privileged background service.

Install a per-user LaunchAgent with a stable copied helper. No immediate purge on
save, no purge on app launch, no arbitrary shell-command or path configuration.
Show the last run's outcomes. Use a process lock to prevent overlapping Reclaim
cleanups. The existing Chrome job stays unchanged until the user elects to replace
it in the app. Validate its exact configuration, retain a backup, and restore prior
settings if installation fails. Do not leave duplicate jobs active for Chrome.
Disabling Reclaim's job must not silently restart the old service.

## Scope and safeguards

### App versions and updates

The user wants to use the published app as another user would, from Applications,
while testing development builds separately from the project build folder.
The October 26 correction keeps the app named **Reclaim** everywhere. Local builds
go to **dist/Reclaim.app**; do not introduce a Dev suffix or another local app.
The folder is the user's testing workflow. Local builds retain a distinct internal
bundle identity and cannot self-update or replace production. Both inspect real
storage and use the same cleanup lock.
Provide an easy menu shortcut back to the app in Applications. About identifies
the channel, version, build, revision and build date so copies are distinguishable.

Use Sparkle for production updates. Check only the stable release feed, verify
signed feeds and update archives, and deliver the same notarized ZIP offered for
manual download. Automatic checks are enabled with a user-visible off switch;
silent installation is not enabled by default. Wait for ongoing storage work
before a requested update restart. Updating the app never enables a cleanup job
or performs a purge. A previously copied scheduled helper changes only when the
user explicitly saves their schedule. Existing apps without the updater need
one manual installation of the first release that includes it.

### Storage operations

All snapshot commands target `/System/Volumes/Data`, verified to be an internal
APFS volume before loading the screen and again before an elevated action.
External Time Machine backups and other volumes are not enumerated or modified.
macOS update snapshots and unrecognized names are excluded from the actionable
list. No broad snapshot deletion commands are allowed.

`tmutil thinlocalsnapshots` lets macOS choose what to reclaim. For precise
deletion, `diskutil apfs deleteSnapshot` accepts a volume and exact snapshot name.
The date-based `tmutil deletelocalsnapshots` form must not be used: Apple's manual
says it targets matching timestamps on all mounted disks.

The UI confirms manual destructive actions. Snapshot operations then invoke
macOS's authorization dialog. It never reads, stores, or logs the user's administrator password.
Only the explicitly configured user-level schedule may run automatically.
No privileged daemon or launch-time purge is allowed. Backup-setting changes
are limited to the explicit shortcut described below; cleanup and schedules
never change backup settings.

### Time Machine backup mode

The October 26 request addresses recurring disruption from hourly local history.
The user is happy to back up the files present when the backup drive is connected,
and prefers manual Time Machine backups over ongoing snapshots between backups.
Reclaim should make the current mode visible and highlight when manual mode is
off. This is a shortcut to **macOS's setting**, not a separate Reclaim scheduler.

Show a compact status strip on the Time Machine page, even when snapshot inspection
is unavailable. Indicate automatic mode with a restrained amber treatment; manual
mode reminds the user to connect the backup disk and choose **Back Up Now**.
The Time Machine page reports the observed backup mode. Provide **System Settings…**
and a **Manual backups** switch. Switching it requires confirmation explaining
the system-wide change, then macOS administrator authorization. Both turning
automatic backups off and turning them back on use only supported `tmutil disable`
and `tmutil enable`. No destination is enumerated or altered and no backup is
started. Enabling does not choose or promise a particular automatic frequency;
the user can review frequency in System Settings.

Read only `AutoBackup` from the system Time Machine preferences through `defaults`;
never write the preference file. This read mechanism is not a stable public API,
so missing, denied or unfamiliar output stays **unknown**, with a Settings fallback
and no enabled switch. Refresh on launch, normal refresh, and returning to the app.
Recheck immediately before changing, allow brief readback delay, and never show
an optimistic switch state or claim success without verification. Cancellation
and failure also reread the setting. Reject late readings from older requests.
Setting changes share the cleanup lock and busy state so cleanup, scheduling
changes and updater restarts cannot overlap them within the app.

Manual mode stops automatic backup protection and routine hourly local snapshots.
Existing local restore points may be removed by macOS after several minutes;
macOS update snapshots may still exist. Existing external backups are kept.
Connecting the disk alone does not trigger a manual backup. Do not describe manual
mode as a snapshot-size cap, a guarantee of no snapshots or instant free space.
Rescan sources and repeat independent storage measurements after every setting
change outcome, as after cleanup, without attributing all observed change to it.
Never change this setting automatically, as part of cleanup or a schedule, or
against the user's real Mac during development tests. Use mocked commands and
readback states for all change tests.

## What we cannot promise

- The entire gap between free and available space belongs to Time Machine.
  Other purgeable data can contribute.
- A known or additive reclaimable size for each snapshot in Reclaim's current
  reader. APFS snapshots share blocks; Disk Utility has size measurements, but
  the supported listing command used here does not report them.
- That a requested amount will be reclaimed, or that reclamation is immediate.
- That every local snapshot is awaiting upload to a backup destination.
- That deleting a snapshot is reversible.

## Built-in alternatives

Apple's Disk Utility can list and delete APFS snapshots via **View → Show APFS
Snapshots**. Apple also documents temporarily switching Time Machine's backup
frequency to manual to allow local snapshots to be removed, then restoring
automatic backups. Reclaim offers a separate, confirmed shortcut to that setting;
its reclamation actions never change the backup schedule.

References:

- [Apple: About Time Machine local snapshots](https://support.apple.com/en-au/102154)
- [Apple: Time Machine settings](https://support.apple.com/en-au/guide/mac-help/mh14037/mac)
- [Apple: About local snapshots on Mac](https://support.apple.com/en-au/guide/mac-help/mh35933/mac)
- [Apple: View APFS snapshots in Disk Utility](https://support.apple.com/en-au/guide/disk-utility/dskuf82354dc/mac)
- The installed macOS `man tmutil` and `man diskutil` documents define the
  commands used by the implementation.

## Implementation references

- [Apple: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Docker system df](https://docs.docker.com/reference/cli/docker/system/df/)
- [Docker Desktop image usage](https://docs.docker.com/desktop/use-desktop/images/)
- [Docker image removal](https://docs.docker.com/reference/cli/docker/image/rm/)
- [Docker Desktop disk space on Mac](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/)
- Installed `man getattrlist`: `ATTR_CMNEXT_PRIVATESIZE`, `ATTR_CMN_RETURNED_ATTRS`
  and `FSOPT_ATTR_CMN_EXTENDED` define the private-file measurements. The macOS
  `ps`, `lsof` and Git `worktree list --porcelain -z` interfaces supply usage and
  ownership evidence. No private APFS APIs or snapshot mounting are used.
- [Chromium user-data and cache directories](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md)
