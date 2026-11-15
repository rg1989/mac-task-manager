# Task Manager for Mac

A task manager and a Mac cleaner in one app. It opens on a live process
dashboard, and the cleanup tools sit one click away in the sidebar.

Task Manager is a fork of [Mac Sai](https://github.com/iliyami/MacSai) by Iliya
Mirzaei. All cleanup, uninstall, disk and protection features come from
Mac Sai and are unchanged. This fork adds the process dashboard and renames the
app.

## What this fork adds

- **Processes dashboard.** The first page of the app. Cards for CPU (per core),
  memory, storage and network sit above a searchable, sortable list of every
  process on the Mac.
- **List and By app views.** By app folds an app's helpers into one row and adds
  up their CPU and memory, so you see what a browser or Docker really costs.
- **Leftovers view.** Lists headless browsers and dev servers, and marks the
  ones nothing owns any more: whatever started them has exited, they have no
  terminal, and macOS does not run them as a service. Coding agents and test
  tools often leave these behind. Each row shows the ports, the project folder
  and who started it. Quit one, or quit all leftovers at once.
- **Details window.** Click a row to see live numbers, the parent process and
  the file location, with Quit, Force Quit and Restart buttons.
- **Menu bar.** The dropdown keeps the CPU, memory, disk and battery rings in one
  compact row and adds the top five processes.
- **Real app names.** Rows show the name an app has in Finder, not the name of
  its program file.

## Safety rules for quitting

- Finder, Dock, WindowServer, loginwindow, launchd, the kernel and Task Manager
  itself never get a Quit button.
- Processes that belong to another user (most system processes) are listed but
  cannot be quit. The app never asks for an administrator password for this.
- Before any Quit, the app checks again that the process ID still belongs to the
  same program.
- Restart sends a normal Quit, waits for the app to close, then opens it again.

## Install

There is no download. You build the app on your own Mac.

Requirements: macOS 14 or later, Apple Silicon or Intel, and the Xcode Command
Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/rg1989/mac-task-manager.git
cd mac-task-manager
./scripts/fork-install.sh
```

The script builds a release, signs it, and installs `Task Manager.app` in
`/Applications`.

- **Signing.** If your keychain has an "Apple Development" or "Developer ID
  Application" certificate, the script signs with it. macOS then keeps the Full
  Disk Access grant across rebuilds. Without a certificate the build is ad-hoc
  signed, and macOS asks for Full Disk Access again after each install.
- **Full Disk Access.** Some cleanup modules need it. Grant it in System
  Settings, Privacy & Security, Full Disk Access. The process dashboard does not
  need it.
- **Not notarized.** The build is for the Mac that made it. Gatekeeper rejects it
  on other Macs.
- **Updates.** The in-app update check is off, because an update would replace
  this fork with the official Mac Sai. Pull and run the script again to update.

If the official Mac Sai is installed with Homebrew, remove it first with
`brew uninstall --cask mac-sai`. Both apps share one bundle identifier and one
set of settings.

## How the process list works

A normal app can read CPU and memory only for the current user's processes
(about two thirds of them on a typical Mac). The built-in `/bin/ps` tool can
list all of them, so the app uses both:

- `ps` supplies the full list every two seconds.
- For the user's own processes, the libproc API replaces the CPU value with one
  measured between two samples, and the memory value with the physical
  footprint, which is the number Activity Monitor shows.

Limits:

- CPU for other users' processes is the slower, averaged value from `ps`.
- Memory for other users' processes is resident size, not footprint.
- There is no GPU, disk I/O or per-process network column.

## Checks

```bash
swift run ProcessSelfCheck          # logic checks, exit code 1 on failure
swift run ProcessSelfCheck --live   # also samples this Mac
```

The Mac Sai test suite uses XCTest, which needs the full Xcode app. It has not
been run for this fork. Tests that cover the app name and the update check are
expected to fail, because the fork changes both on purpose.

Build the two apps directly with `swift build --product MacClean` and
`swift build --product MacCleanMenu`. Plain `swift build` also compiles the
tests and fails without Xcode.

## Where the new code is

| Path | Purpose |
|------|---------|
| `Sources/MacCleanKit/Processes/` | Process reader, system counters, and the rules for search, sort, grouping and quitting |
| `Sources/MacClean/Views/Processes/` | Dashboard page, cards, table, details window |
| `Sources/MacClean/Modules/Processes/` | Quit, Force Quit, Restart |
| `Sources/ProcessSelfCheck/` | Runnable checks |
| `scripts/fork-install.sh` | Build, sign, install |
| `docs/superpowers/specs/` | Design notes |

The program files inside the bundle keep Mac Sai's internal names, `MacClean`
and `MacCleanMenu`, and the bundle identifier is still `com.macclean.app`. That
keeps the fork close to the original code, so Mac Sai updates merge with few
conflicts.

## Getting Mac Sai updates

```bash
git remote add upstream https://github.com/iliyami/MacSai.git
git fetch upstream
git merge upstream/main
./scripts/fork-install.sh
```

## Other files in this repository

The `website/` folder, the `README.*.md` translations and the release workflows
belong to Mac Sai and describe Mac Sai. They are kept unchanged to make merges
simple. GitHub Actions is turned off for this repository.

## Credits and license

Mac Sai is the work of [Iliya Mirzaei](https://github.com/iliyami) and its
contributors. If the cleanup tools are useful to you, the Support button in
Settings goes to the Mac Sai author.

The dashboard layout follows the structure of
[NeoHtop](https://github.com/Abdenasser/neohtop). No NeoHtop code is used.

The Leftovers view is inspired by
[DevDeck](https://github.com/SeanLuis/devdeck), which attributes processes to
the projects and agents behind them. It is written from scratch here; no
DevDeck code is used.

BSD 3-Clause, the same license as Mac Sai. See [LICENSE](LICENSE).
