[English](/README.md) | [Русский](/README.ru_RU.md)

# WSL Cleanup (`wsl-cleanup.sh`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-WSL2%20%7C%20Ubuntu-orange.svg)](https://learn.microsoft.com/en-us/windows/wsl/)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

A safe, idempotent, and version-aware disk reclaim utility designed specifically for WSL2 (Windows Subsystem for Linux) development environments.

---

## The Problem

1. **Virtual Disks Only Grow**: WSL2 stores its filesystem in a dynamic virtual disk (`ext4.vhdx`). While files can be deleted inside Linux, Windows never shrinks the `.vhdx` container automatically.
2. **Developer Toolchain Bloat**: Modern developer setups accumulate tens of gigabytes of redundant data:
   - Editors (Cursor Server, Zed, VS Code) keep old versions of extensions and remote server binaries side-by-side on every update.
   - Go pulls ~240 MB toolchains for each module directive change.
   - Package managers (`npm`, `npx`, `cargo`, `gradle`, `playwright`) cache huge archives, unpacked binaries, and dependency transformation artifacts.
   - Global NPM packages sometimes ship unused architecture binaries (e.g. `musl` binaries or Windows `.exe` on Linux).
   - Building under `sudo` creates a duplicate root home directory (`/root`) with independent unpruned caches.

---

## Key Features

- 🛡️ **Safe by Design (Dry Run Default)**: Always runs in dry-run mode unless `--force` is explicitly provided. Shows exact paths and disk sizes before touching anything.
- 🔄 **Strict Version Deduplication ("Keep Latest Only")**:
  - **Cursor Server Extensions**: Groups extensions by package name, keeping strictly the latest version and removing older duplicate releases and cached `.vsix` archives.
  - **Go Toolchains**: Preserves the newest toolchain (which builds older Go modules with full backward compatibility) and removes superseded versions.
  - **Editor & Runtime Servers**: Retains only active/newest Cursor and Zed server binaries.
  - **Node & Android Build Tools**: Retains the latest installed runtime while honoring project-specific pins (e.g., `.nvmrc`).
- 🧠 **100% Protection of AI Agent Sessions & Memory**:
  - Never touches chat history, transcripts, context, or persistent memory of AI assistants:
    - Claude (`~/.claude/projects`, `~/.claude/sessions`, `~/.claude/tasks`)
    - Codex (`~/.codex/sessions`, `~/.codex/memories`, `~/.codex/rules`, `~/.codex/logs_2.sqlite`)
    - Gemini / Antigravity (`~/.gemini/antigravity-acp/conversations`, `~/.gemini/antigravity-acp/brain`, CLI sessions)
    - OpenCode (`~/.local/share/opencode`)
    - GitHub Copilot CLI (`~/.copilot`: sessions, transcripts, context, memory, logs, and configuration)
  - Only purges transient build/plugin scratch caches (`.tmp`, plugin caches) where no conversation history exists.
  - Zed leaks one crash-handler socket per launch into `~/.cache/zed` and never reaps them;
    stale ones are removed, sockets belonging to a running editor are kept.
  - `~/.cache/copilot` is **not** agent state and *is* cleaned: the Copilot CLI ships as a single
    self-extracting binary and unpacks a ~140&nbsp;MB payload there on first launch, next to two JSON
    files whose own first line reads *"Disposable cache … safe to delete"* and a folder of cached MCP
    tool schemas. The next launch re-extracts it from the installed binary in ~2&nbsp;s, offline — so it
    is reclaimed in the **default** run, not behind `--deep`. A version directory still marked
    `inuse.<pid>.lock` by a live process is kept until that process exits.
- 📚 **Source Code & Documentation Safe**:
  - Source trees in `~/Development`, Git repositories (`.git`), commit history, and branches are never touched.
  - Documentation files (`docs/`, `*.md`, offline Rust documentation) are strictly preserved.
  - Sensitive configurations (`.env`, `local.properties`, SSH/GPG keys, Android signing keystores, database clusters) are excluded.
- ⚡ **Process Protection**:
  - Inspects active running processes via `/proc/*/exe` and `/proc/*/cwd` to ensure currently active editors, background servers, or language servers are never deleted.
- 🌐 **DKMS & VPN Module Awareness**:
  - Detects installed DKMS modules (e.g. AmneziaWG VPN) before touching kernel headers.
- 🔍 **Automatic Windows Host VHDX Path Detection**:
  - Automatically queries the Windows Registry via WSL Interop to find the exact host path of your `ext4.vhdx` (even when relocated to another drive) and provides copy-paste commands to compact it.

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/coinman-dev/wsl-cleanup.git
cd wsl-cleanup
chmod +x wsl-cleanup.sh
```

### 2. Preview what would be reclaimed (Dry Run)

```bash
./wsl-cleanup.sh
```

*(No files will be deleted in dry run mode)*

### 3. Run Cleanup

#### Standard cleanup (rebuildable caches, old extensions, duplicate toolchains)
```bash
./wsl-cleanup.sh --force
```

#### Deep cleanup (includes package caches, npx, Playwright, Gradle transforms)
```bash
./wsl-cleanup.sh --force --deep
```

#### Full system cleanup (all above + APT cache, systemd journal, root caches, stale backups)
```bash
sudo ./wsl-cleanup.sh --force --all
```

---

## Command-Line Options

| Flag | Description |
| :--- | :--- |
| *(default)* | **Dry run mode**. Calculates and displays potential space savings without deleting anything. |
| `--force` | Actually execute the deletions. |
| `--deep` | Removes redownloadable package caches (`~/.npm/_npx`, Go module caches, Cargo crates, Playwright browser caches, Gradle transforms, and `node_modules` in `~/Development`). |
| `--system` | Cleans system APT archives, orphans, package lists, limits `systemd` journal, cleans rotated `/var/log`, prunes `/root` caches, and removes incompatible global npm architecture stubs. *(Requires sudo)* |
| `--purge-bak` | Purges rollback copies (`*.bak*`) in `/opt/ownlocator` and stale media backups in `/var/lib/ownlocator/media-wsl-backup`. |
| `--purge-pgtest` | Purges the local PostgreSQL test cluster in `~/.local/pgtest` (if no postgres process is active). |
| `--all` | Enables `--deep`, `--system`, and `--purge-bak` together. |
| `--list-installed [word]` | Inventory of installed **programs**, largest first. Optional word filters it. |
| `--uninstall <handle>` | Removes one entry from that inventory, using whatever installed it. Dry run unless `--force`. |
| `-h`, `--help` | Displays help message and exits. |

---

## Installed Programs

Cache sweeps never touch whole programs, and on a development box those are usually
the larger half of a full disk. Two modes cover them.

```bash
./wsl-cleanup.sh --list-installed
```

```
==> Installed programs — largest first
      1.9GB  agent:antigravity-acp        1.1.1     zed external agent
      818MB  sdk:emulator                 -         android sdk
      456MB  nvm:v22.22.1                 v22.22.1  nvm
      375MB  npm:@anthropic-ai/claude-code 2.1.245  /usr/local/lib/node_modules
       44MB  apt:gh                       2.45.0    apt
       16MB  go:staticcheck               -         go install
       12MB  cargo:cargo-xwin             v0.21.4   cargo install
```

It reads apt, every global npm root, `cargo install`, `go install`, nvm, the Android
SDK and Zed's agent registry. Each line begins with a `manager:name` **handle**, which
is what makes the second mode unambiguous — `gopls` is plausibly a Go binary and a Zed
language server at once.

```bash
./wsl-cleanup.sh --uninstall gh                    # dry run: shows the command
./wsl-cleanup.sh --force --uninstall sdk:emulator  # actually removes it
```

Removal is handed to whoever installed the thing — apt purges, npm and cargo and
`sdkmanager` uninstall, and a directory no installer owns goes through the same
`drop()` as everything else the script deletes. A bare name works when only one
manager has it; otherwise the script lists the candidates and stops.

Three deliberate limits:

- **apt lines are manually installed packages only.** A dependency nobody chose is not
  a program somebody installed, and `--system` already autoremoves the orphans. Asking
  to uninstall one says so rather than claiming it isn't there.
- **Essential and required apt packages are refused.** apt will take half the system
  with `libc6` if asked; the answer here is no.
- **Dry run first, always.** For apt the preview includes the full cascade (`apt-get -s
  purge`), so what a package drags out with it is visible before `--force`.

---

## Compacting the Virtual Disk (`.vhdx`) on Windows

After cleaning up files inside WSL2, the freed disk space remains allocated inside the virtual hard disk container. To shrink the physical `.vhdx` file on your Windows host:

`wsl-cleanup.sh` prints your exact detected path at the end of the run:

### Option A: PowerShell (Windows Pro / Enterprise with Hyper-V)

Run in an **Administrator PowerShell**:

```powershell
wsl --shutdown
Optimize-VHD -Path "<Path-Reported-By-Script>\ext4.vhdx" -Mode Full
```

### Option B: Diskpart (Windows Home / Standard)

Run in an **Administrator Command Prompt / PowerShell**:

```cmd
wsl --shutdown
diskpart
```

Inside `diskpart`:

```text
select vdisk file="<Path-Reported-By-Script>\ext4.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit
```

---

## Configuration

You can customize behavior using environment variables:

```bash
DEV_DIR=~/Development     # Root directory of your repositories (default: ~/Development)
JOURNAL_KEEP=200M         # Target size for systemd journal vacuuming (default: 200M)
TMP_AGE_DAYS=7            # Age threshold for /tmp cleanup (default: 7 days)
```

Example:
```bash
DEV_DIR=/path/to/my/projects ./wsl-cleanup.sh --force
```

---

## What is Cleaned vs. What is Kept

| Category | Cleaned / Reclaimed | Kept / Protected |
| :--- | :--- | :--- |
| **AI Agents** | Transient scratch files (`.tmp`, plugin cache), the Copilot CLI's self-extracted payload (`~/.cache/copilot`, ~140 MB, rebuilt offline in ~2 s) | **All** chat sessions, conversation history, memory, rules, tasks (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.copilot`, `~/.local/share/opencode`) |
| **Cursor & Editors** | Old extension versions, cached VSIX archives, superseded server binaries | Latest extension versions, active server binaries, settings |
| **Go** | Older toolchain versions (`toolchain@...`), and `golang.org/x` module cache under `--deep` | **Latest** Go toolchain |
| **Node / NPM** | `~/.npm/_npx`, `_cacache` | Active NVM version, pinned `.nvmrc` versions |
| **Other-platform binaries** | Packages tagged for an OS or architecture this machine cannot execute — `win32-*`, `darwin-*`, `*-arm64` — wherever npm or prebuildify installed them | Anything untagged, and a musl build with no glibc sibling (Codex ships **only** a static musl binary, which runs fine on glibc) |
| **Rust / Cargo** | Redownloadable registry index/cache (under `--deep`), `target/` build output | Offline documentation (`rust-docs`), active toolchains |
| **Android / Gradle** | Superseded build-tools, build cache, transforms (under `--deep`) | Active build-tools, wrapper distribution, keystores |
| **Repositories** | Build artifacts (`target/`, `build/`, `dist/`, `.gradle/`, `reports/`) | All source code, Git history, documentation, `.env` configs |

---

## License

Released under the [MIT License](LICENSE).
