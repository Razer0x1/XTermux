# XTermux

A real, honest terminal for iOS — inspired by Termux and iSh, but with **no
pretending**. XTermux ships an in-process shell engine, a persistent sandbox
filesystem, real SSH remote terminals, and a file manager. It never claims to
replace the kernel, never elevates privileges, and never fakes installing
packages.

## What this app is (and is not)

| Claim | Status |
|---|---|
| Runs commands inside the app's own iOS sandbox | ✅ Real — pure-Swift shell engine, no subprocesses |
| Pipes, `>` / `>>` / `<` redirections, exit codes, `$VAR` expansion | ✅ Real — POSIX-style parser written for this app |
| Persistent filesystem you can see in the Files app | ✅ Real — sandbox rooted at the app's `Documents` directory |
| Full remote Linux via SSH (real PTY) | ✅ Real — Citadel/OpenSSH client, xterm-256color |
| Install `apt`/`pip`/`gcc` packages on-device | ❌ Impossible for App Store apps — reported honestly, never faked |
| Linux VM on-device | ❌ iOS grants no compliant hypervisor — documented, not simulated |
| root / jailbreak / kernel replacement | ❌ Never — and never attempted |

## Install on your iPhone — Sideloadly, full walkthrough

There is no App Store entry for XTermux. You install it by **sideloading** the
release IPA: a signing tool (Sideloadly) signs the app with *your* Apple ID and
iOS accepts it the same way it accepts any developer build. Free, no jailbreak,
no paid account required.

### What you need

| Item | Notes |
|---|---|
| iPhone or iPad | running **iOS 16.0 or newer** |
| Windows 10/11 or macOS | Sideloadly runs on both |
| USB cable | data cable, not charge-only |
| Any Apple ID | free one is fine. Free accounts cap at **3 sideloaded apps** and the signature **expires after 7 days** (just re-sign). A paid Apple Developer account ($99/yr) gets a 1-year signature instead. |
| The IPA | download [`XTermux.ipa` from Releases](https://github.com/Razer0x1/XTermux/releases/latest) — it is *unsigned*; Sideloadly signs it during install |
| (only on Windows) | **iTunes** (from apple.com/itunes) **or** the **Apple Devices** app (Microsoft Store) — not for music, but because it installs Apple's USB driver |

### Steps

1. **Install iTunes / Apple Devices** (Windows only) for the USB driver, then
   reboot once so the driver is picked up. macOS users skip this — the driver
   is built in.
2. **Install [Sideloadly](https://sideloadly.io)** — Windows installer or macOS
   package. No account inside Sideloadly is needed; you will sign in with your
   Apple ID in step 6.
3. **Download `XTermux.ipa`** from this repo's
   [Releases](https://github.com/Razer0x1/XTermux/releases/latest) page.
4. **Plug in your iPhone** with a data cable. Unlock it; if asked, tap
   **Trust This Computer** and enter your passcode. Keep the phone *unlocked
   and the screen awake* for the whole install.
5. **Open Sideloadly** and drag `XTermux.ipa` into the big window (or use the
   IPA button to browse).
6. **Apple ID field:** type your Apple ID e-mail exactly. If you sign in with
   two-factor authentication, Sideloadly will show a **6-digit code** prompt —
   complete it in your browser/the popup and return to Sideloadly. (Some
   setups instead ask for an **app-specific password**: create one at
   [account.apple.com](https://account.apple.com) → Sign-In and Security →
   App-Specific Passwords, then paste it where Sideloadly asks.)
7. **Press Start.** Sideloadly signs the app with your Apple ID and pushes it
   to the phone. Progress is shown in the log; wait for the "Done" line.
8. **Trust the developer on the iPhone:** open
   **Settings → General → VPN & Device Management** → tap the profile that
   shows your Apple ID under "Developer App" → **Trust**.
   (On older iOS the menu is "Profiles & Device Management".)
9. **Open XTermux** from the Home Screen. First launch starts you a fresh
   sandbox — open the Terminal tab, try `ls`, `uname -a`, `kern info`, or set
   up an SSH host in **Settings → SSH**.

### Updating later

Sideload the newer IPA **over** the installed app the same way. Because the
bundle ID (`com.xtermux.app`) stays the same, iOS treats it as an app update —
your sandbox files, history, settings, and SSH profiles survive. Only
*uninstalling* the app wipes its data.

### Troubleshooting

| Symptom | Fix |
|---|---|
| Sideloadly sees no device | Install the iTunes/Apple-Devices driver, reboot PC **and** phone, use another USB port/cable, keep the phone unlocked |
| "Unable to install" on the phone | Make sure you completed the Trust step in step 8 **and** you signed in with the same Apple ID in Sideloadly; retry with the screen unlocked |
| 2FA / sign-in loops | Use a fresh one-time code each attempt; if loops persist, create an app-specific password (step 6) and use it |
| App opens then crashes or shows "expired" | The 7-day free signature ran out — re-sign with Sideloadly (step 6). Prefer automatic? [AltStore](https://altstore.io) re-signs over Wi-Fi in the background with the same Apple ID and keeps your data |
| Install stalls at "Installing…" for minutes | Ignore the Home-Screen grey icon; wait for Sideloadly's "Done" before judging — iOS finishes allocation after Sideloadly reports success |
| Other Sideloadly errors | Usually transient Apple auth servers — click Start again; if it persists, update Sideloadly and check its own help page |

### Alternatives (honest one-liners)

- **AltStore** — same free-signing flow with automatic 7-day background
  refresh; install AltServer, then open the IPA on-device from Files.
- **TrollStore** — permanent, no expiry, but only available on the specific
  iOS versions its exploit covers — check its repository for current support
  before relying on it.

## The five tabs

1. **Terminal** — multiple sessions (local sandbox shell + SSH remotes),
   Ctrl-R history search, tab completion, keyboard accessory row (Esc, Tab,
   Ctrl latch, arrows, Home/End), command palette, per-session rename/close/
   restart, iPad split view.
2. **Files** — browse/import/export/create/edit/rename/move/duplicate/delete
   inside the sandbox, with delete confirmations and a text editor.
3. **Packages** — an *honest dashboard*: what each well-known tool actually is
   here (local builtin, needs your SSH server, needs an unimplemented Linux
   VM, or planned). No fake progress bars, no pretend `apt`.
4. **Projects** — starter project folders in the sandbox (script text, notes)
   with an honest note that building binaries needs a real Linux (use SSH).
5. **Settings** — themes, font size, SSH profile management (secrets in the
   iOS Keychain), Linux VM feasibility report, and the local backend's
   capability matrix.

## Command compatibility

**Local shell (35 builtins, real implementations):**

```
cat  cd   chmod cp   date  echo  env   exit  export false find
grep head help  history id   ls    mkdir mv    printenv pwd
rm   sort tail  touch  true  tr    uname unset which wc    whoami
clear kern
```

Aliases: `dir` → `ls`, `logout`/`q` → `exit`, `cat -` reads pipe input,
`kernel` → `kern`.

**Shell features:**

| Feature | Supported | Notes |
|---|---|---|
| Quoting `'single'`, `"double"` with escapes | ✅ | `\n \t \" \\ \$ \`` inside double quotes |
| Pipelines `a \| b \| c` | ✅ | exit code = last stage; intermediate output hidden |
| Redirects `>`, `>>`, `<` | ✅ | `<` re-runs a stage with file contents as stdin |
| Variables `$VAR`, `${VAR}`, `$?` | ✅ | per-session env; `export`/`unset` |
| `~` and chroot-style path safety | ✅ | `..` beyond the sandbox root is rejected |
| `&&`, `||`, `;` chaining, globs, backticks, `$(...)` | ❌ planned | honest syntax error today |

**Known-but-not-local tools** (`git`, `python`, `node`, `gcc`, `make`, `bash`
scripts, …): the shell prints a truthful pointer — run them on your SSH
server (Terminal → + → SSH). The app never fakes executing them.

## Architecture

```
Sources/
  XTermuxCore/          platform-neutral core (Linux-testable)
    Shell/CommandScanner.swift    tokenizer: quotes, pipes, redirects
    Execution/ShellEngine.swift   expansion, stage loop, registry, IO
    Execution/FileCommands.swift  ls, cat, cp, mv, rm, find, grep, wc, …
    Execution/MetaCommands.swift  echo, env, sort, cut, tr, exit, kern, …
    Execution/LocalShellSession.swift  byte-machine session (Ctrl-R, completion)
    Execution/SessionStoreCore.swift   session lifecycle state machine
    Filesystem/                   SandboxPath (chroot) + FileSystemService
    History/HistoryStore.swift    persistent, searchable history
    Packages/PackageCatalog.swift honest package truth table
    LinuxVM/LinuxVMBackend.swift  feasibility report (no fake VM)
    SSH/SSHModels.swift           profiles (secret-free JSON)
    SSH/SSHBackend.swift          Citadel PTY backend (Apple platforms only)
  XTermux/              SwiftUI app (iOS-only; guarded with canImport(UIKit))
    Terminal/  Files/  Packages/  Projects/  Settings/  Services/  SSH/  Shared/
  Vendor/SwiftTerm/     vendored SwiftTerm v1.20.0 (patched — see below)
Tests/XTermuxCoreTests/  unit/integration tests (run on Linux and iOS)
```

**Why SwiftTerm is vendored:** upstream SwiftTerm cannot build under xtool,
which cross-compiles for iPhoneOS from a Linux host. Its manifest (a) declares
`Shaders.metal` as a *processed* resource, forcing a Metal-shader compile with
a compiler that does not exist for Linux, and (b) excludes the `iOS/` UI
sources whenever the *host* is Linux. The vendored copy copies the shader as a
plain resource (SwiftTerm's renderer already falls back to compiling it at
runtime — and GPU rendering is opt-in; CoreGraphics is the default) and keeps
the Apple/iOS sources for the iOS destination. Everything else is unmodified.

## Building

Requirements: [xtool](https://github.com/xtool-org/xtool) 1.22+, an Apple
Developer Team ID (set in `xtool.yml`), and for Linux testing any Swift 6
toolchain.

```bash
# iOS app (device/simulator via xtool; needs the Darwin SDK)
xtool dev build

# On a Linux host (e.g. WSL), use the mirror script instead: SwiftPM's module
# cache races on /mnt/c (NTFS), so the build runs from an ext4 mirror.
./build_ios.sh

# Linux/WSL unit + integration tests (never touches the iOS UI layer)
swift test
```

Repository utilities:

- `build_ios.sh` — mirrors the project to a WSL-native directory
  (`~/xtermux-build`) and runs `xtool dev build` there; required on Windows/WSL
  setups because Clang's explicit-module cache is unreliable on `/mnt/c`.
- `guard_app_sources.sh` — wraps every `Sources/XTermux` file in
  `#if canImport(UIKit)` (rerun after adding app-target files; the Linux
  toolchain has no SwiftUI).
- `fix_quotes.sh` — scrubs smart quotes/dashes that text editors sometimes
  introduce into Swift sources.

## Tests

`swift test` runs 111 tests covering: scanner (quoting, pipelines, dangling
redirects), expansion (`$VAR`, `${VAR}`, `$?`), pipes + redirects (including
`stdout-to-file-then-empty-pipe`), file command lifecycle, ls filtering,
chmod, sandbox traversal rejection, honest not-found messages with
suggestions, history recording, Ctrl-R/Ctrl-C/arrow-key session behaviour,
banner/prompt/echo, safe input after session end, the `kern` command family
(including its strict "never invent a value" honesty rule), and the session
lifecycle machine (creation dedupe, exit idempotence, closing the last
session → Home, unexpected-disconnect pruning, preserved sessions).

## Minimum iOS and device compatibility

- **Deployment target: iOS 16.0** (`Package.swift` platform floor; the SSH
  client vendoring keeps Citadel's 0.12 surface below the iOS 17 API it does
  not actually use). Nothing in the app requires a newer API; iOS 17/18/26+
  features are used opportunistically with no availability gate.
- No device-model lists, no fixed screen dimensions: layouts use size classes,
  safe areas, and scrolling. iPhone SE-class through Pro Max, portrait and
  landscape, iPad split view (Terminal uses a sidebar at width-regular).
- Not yet verified on physical hardware in this build environment (no device
  or simulator access from the CI host): keyboard-inset behaviour on new
  hardware, SSH against a live server, and iPad multitasking edge cases.
  These remain honest open items rather than claimed results.

## Complete rebrand note

The project is named **XTermux** everywhere: package, library product, targets
(`XTermux`, `XTermuxCore`), executable name, bundle ID (`com.xtermux.app`),
home-screen display name, the sandbox user and its home directory
(`/home/xtermux`), settings keys, the Keychain service, build scripts, docs,
and every source comment.

⚠️ **Data note:** the bundle identifier changed in the rebrand, so iOS gives
this build a fresh sandbox on a device that had any earlier build installed —
Files, history, settings, and SSH profiles start empty (secrets were in the
old container's Keychain). Re-add profiles in Settings → SSH. This is a
one-time cost of doing the rename completely.

## App Store compliance notes

- **2.5.2 (software execution):** the app executes *no* downloaded code.
  Local commands are its own compiled-in Swift implementations; SSH remotes
  are the user's own servers (user-initiated, general-purpose tooling — the
  same category as any SSH client).
- **No private-API / entitlement abuse:** no fork/exec (impossible for
  App Store apps anyway), no hypervisor entitlement, no root claims.
- **Data:** SSH secrets live in the iOS Keychain; profile metadata is a JSON
  file in the app's own Documents directory. Nothing leaves the device except
  SSH traffic the user initiates.
- **Honesty policy:** the UI (Packages, Settings, Projects) states exactly
  what runs where; features that don't exist are labelled planned, never
  simulated.

## Implemented vs planned

| Area | Implemented | Planned |
|---|---|---|
| Shell | 35 builtins, pipes, redirects, expansion, exit codes | `&&`/`\|\|`/`;`, globs, command substitution |
| Terminal | sessions, Ctrl-R, completion, palette, accessory row, iPad split | theming presets per-pane, scrollback search |
| SSH | PTY sessions, password + OpenSSH RSA/Ed25519 keys, Keychain secrets | host-key pinning, SFTP browse, agent forwarding |
| Linux VM | feasibility matrix (honest "no") | — (blocked by iOS platform rules) |
| Files | full CRUD + import/export + editor | archive extraction, sharing |

## License

MIT — see [LICENSE](LICENSE).
