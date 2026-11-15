# Processes dashboard: design

Date: 2026-11-16. Branch: `processes-dashboard`. Base: Mac Sai v1.32.0 (`91b262f`).

## Goal

Mac Sai becomes one tool for cleanup and for process management. It opens on a
Processes dashboard that works as a task manager. The menu bar dropdown shows
process data next to the existing rings. Cleanup and deletion code is not
changed.

## Decisions made with the user

- Layout follows NeoHtop (stat cards above a process table), in Mac Sai's own
  visual style.
- The table opens as a flat list and has a List | By app switch.
- The menu bar dropdown gains a view-only Top 5 list. No Quit buttons there.
- Our build replaces the Homebrew copy in `/Applications`.
- Four cards: CPU, Memory, Storage, Network. GPU and uptime cards are out of scope.

## Data source

Measured on this Mac: the libproc API reads 407 of 628 processes as a normal
user. The other 221 are owned by other users and return nothing. `/bin/ps` is
setuid root and lists all of them in 27 ms.

- `/bin/ps -axo pid=,ppid=,uid=,pcpu=,rss=,etime=,comm=` supplies the full list
  on every tick.
- For processes that libproc can read, `proc_pidinfo(PROC_PIDTASKINFO)` replaces
  the CPU value (delta between two samples) and `proc_pid_rusage` replaces the
  memory value (`ri_phys_footprint`, the number Activity Monitor shows).
- `proc_pidpath` gives the executable path, which grouping needs.
- No admin prompt, no privileged helper, no new entitlement.

## Components

All new code is in new files. Existing files get small edits only.

### MacCleanKit (shared by the app and the menu bar helper, no AppKit)

| File | Purpose |
|------|---------|
| `Processes/ProcessSnapshot.swift` | Value type for one process: pid, ppid, uid, name, executable path, CPU percent, memory bytes, elapsed seconds, `isOwnedByCurrentUser`. |
| `Processes/PSOutputParser.swift` | Pure function: `ps` text to `[ProcessSnapshot]`. Skips lines it cannot parse. |
| `Processes/ProcessSampler.swift` | Runs `ps`, applies the libproc refinements, keeps the previous CPU times. One `sample()` call per tick. |
| `Processes/ProcessListPolicy.swift` | Pure functions: search, filter (All, Mine, Apps), sort, group by app, totals, quit rules. |
| `Processes/SystemCardsSampler.swift` | CPU per core, memory, disk, network rates for the cards. Uses the existing `CPUStats`, `MemoryStats`, `DiskStats`, `NetworkRate` types. |

Grouping rule: a process belongs to the outermost `.app` bundle in its
executable path. A process with no bundle joins the group of its nearest
ancestor that has one. Anything left goes to "Background" (current user) or
"System" (other users).

Quit rules (`ProcessListPolicy.quitAbility`):

- Never: pid 0 and 1, `kernel_task`, `launchd`, the Mac Sai app and its menu
  helper, and the bundle IDs already in `ResourceHogsPolicy.neverQuitBundleIDs`
  (Finder, Dock, loginwindow, WindowServer, SystemUIServer).
- Not possible: processes owned by another user. The row shows no Quit button.
- Allowed: everything else owned by the current user.

### MacClean (main app)

| File | Purpose |
|------|---------|
| `Views/Processes/ProcessesViewModel.swift` | `@Observable`. Owns the samplers, the 2 second timer, Pause, search text, filter, sort, List or By app mode, and a 2 minute history for the card graphs. Samples only while the page is visible. |
| `Views/Processes/ProcessesView.swift` | Page layout: cards row, toolbar, table, footer count. |
| `Views/Processes/ProcessStatCards.swift` | The four cards. |
| `Views/Processes/ProcessTableView.swift` | Sortable table: Name with icon, PID, User, CPU %, Memory, Run time, Actions. Expandable group rows in By app mode. |
| `Modules/Processes/ProcessTerminator.swift` | Quit and Force Quit. |

Edits to existing files:

- `Views/Sidebar/SidebarView.swift`: new `SidebarItem.processes`, first case, in
  the main section, so it sits above Smart Scan and takes ⌘1.
- `App/ContentView.swift`: route `.processes` to `ProcessesView`.
- `App/AppState.swift`: default selection is `.processes`.
- `MacCleanKit/Localization.swift`: sidebar title in each language table.
  New page strings use `L10n.tr(zh, en, ru)`; other languages fall back to English.

The existing Resource Hogs block inside Optimization stays as it is.

### Quit flow

1. The user clicks Quit on a row. A confirmation names the process and offers
   Quit and Force Quit.
2. `ProcessTerminator` samples the pid again. The executable path must match
   the row and the process must be at least as old as the row's elapsed time.
   If not, the pid was reused: it stops and reports that the process has
   already ended.
3. Quit: `NSRunningApplication.terminate()` when the pid is a registered app,
   else `SIGTERM`. Force Quit: `forceTerminate()` or `SIGKILL`.
4. For a group row, the action goes to the app's main process. Helpers end with it.
5. A failure (permission denied, process gone) shows as a short message. Nothing retries.

### MacCleanMenu (menu bar helper)

- `MenuStatsModel`: adds `topProcesses`, the five largest app groups by CPU,
  from the same `ProcessSampler` on the existing 3 second loop.
- `MacCleanMenuApp.swift`: new "Top processes" card (name, CPU, memory) under
  the network card, and an "Open Processes" button that uses the existing
  module deep link with id `processes`.

## Fork behaviour

- `MCConstants.isForkBuild = true` makes the release check always report
  "up to date". Sparkle is already inactive in a build with no feed URL.
  Reason: an update would replace our build with the official one.
- `scripts/fork-install.sh`: builds the app bundle for arm64, signs it with the
  local "Apple Development" identity (stable signature, so Full Disk Access is
  granted once), quits the running app, and installs to `/Applications`.
- Before the first install: `brew uninstall --cask mac-sai`, so Homebrew does
  not overwrite our build later. Settings and clean history stay on disk.
- To go back: `brew install --cask mac-sai`.
- Nothing is pushed. Upstream updates are merged into this branch by hand.

## Errors and limits

- A process that ends between `ps` and libproc is dropped from that tick.
- If `ps` fails, the page keeps the last list and shows a one-line notice.
- CPU for other users' processes is the `ps` decaying average, so it reacts
  more slowly than the values for the user's own processes.
- Memory for other users' processes is resident size, not footprint.
- Processes of other users cannot be quit.

## Testing

`swift test` needs XCTest, which ships only with full Xcode. This Mac has the
Command Line Tools only, so the existing 157 test files cannot run here.

- New executable target `ProcessSelfCheck` (`swift run ProcessSelfCheck`):
  assert-based checks for `PSOutputParser` and `ProcessListPolicy` (parsing,
  search, filter, sort, grouping, totals, quit rules). It exits non-zero on failure.
- Manual check on the installed build: the page is first on launch, the list
  count matches `ps -ax | wc -l` within a few, CPU and memory for three named
  processes match Activity Monitor, Quit works on a throwaway `sleep` process
  and on a test app, protected processes show no Quit button, and the menu bar
  dropdown shows the Top 5 and opens the page.

## Out of scope

GPU and uptime cards, tree view, pinning, per-process disk I/O, admin-level
quit, own-folder protection for cleanup, upstream pull request.

## Changes after the first build

- The app is named Task Manager: bundle name, window title, menu bar header
  and visible text. The executables (`MacClean`, `MacCleanMenu`) and the bundle
  identifier (`com.macclean.app`) keep their names.
- A click on a process row opens a details sheet with live numbers and Quit,
  Force Quit and Restart. Restart quits the app's main process, waits up to
  10 seconds for it to exit, and opens the bundle again.
- Rows show an app's display name from its `Info.plist`. The quit protection
  matches the executable file name, so a renamed bundle stays protected.
- libproc supplies the full executable path for the user's own processes;
  `ps` prints the path as it was typed at launch.
- Process memory uses binary units (1 GB = 1024 MB), as Activity Monitor does.
- The four menu bar ring cards sit in one row.

## Leftovers view

A third mode on the Processes page, next to List and By app.

- **Candidates** (current user's processes only): headless browsers
  (`--headless`, Playwright and Puppeteer browser builds, headless shells,
  browser drivers) and dev servers (a listening TCP port on a runtime such as
  Node, Bun, Deno, Python, Ruby, PHP, or a command line that names a known
  server). A helper inside an installed app is not a candidate.
- **Tree:** a candidate under another candidate is part of that one's tree.
  Memory, CPU and ports are totals for the tree.
- **Ownership**, first match wins: a launchd service; a terminal on the
  process; then, walking up the parents, a coding agent, an installed app, a
  launchd service or a terminal. If the chain ends at launchd with no match,
  the item is a leftover.
- **Data:** `ps -xo pid=,tty=,args= -ww`, `lsof -nP -iTCP -sTCP:LISTEN -Fpn`
  and `launchctl list`, about 30 ms each, plus the working folder from
  libproc. They run on every tick while the view is open and every 10 seconds
  otherwise, to keep the count on the tab current.
- **Quit** ends the root with a normal Quit, then any child still alive
  1.5 seconds later. "Quit all leftovers" acts on true leftovers only.
- `LeftoverDetector` and `ProcessContextParser` are pure and covered by
  `ProcessSelfCheck`.
