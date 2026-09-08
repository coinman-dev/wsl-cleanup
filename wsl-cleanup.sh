#!/usr/bin/env bash
#
# wsl-cleanup.sh — reclaim disk space in this WSL2 Ubuntu by removing derived
# data: tool caches, build output, and superseded copies of things that keep
# several versions of themselves side by side.
#
# Sibling of the two scripts in ownlocator/scripts: clean-artifacts.sh strips
# build output from ONE repo, server-cleanup.sh maintains the PRODUCTION host.
# This one is for the development machine as a whole — every repo under
# ~/Development plus the toolchains, editors and agents installed for you.
#
# NEVER TOUCHED — the things you cannot regenerate:
#   ~/.ssh ~/.gnupg                     keys and configuration
#   ~/.android                          adb key + the debug signing keystore
#   */secrets/**                        release keystores and build config
#   ~/ownlocator-backups                your backups
#   ~/.claude ~/.codex ~/.gemini        ALL AI AGENT SESSIONS, MEMORY, TRANSCRIPTS
#   ~/.copilot                           GitHub Copilot sessions, context, memory, logs
#                                        (~/.cache/copilot is NOT this: see below)
#   ~/.local/share/opencode              OpenCode memory and state
#   ~/.cache/google-vscode-extension    live Google OAuth + ADC refresh tokens
#   deviceid, telemetry.uuid            machine identity filed under ~/.cache
#   any source tree, .git, .env         working source code and repo history
#   local.properties, *.json            configuration and credentials
#   documentation                       offline docs, project docs, markdown
#   ~/.local/pgtest                     a local Postgres cluster with real data
#                                       in it (opt in with --purge-pgtest)
#
# Safe by design:
#   - DRY RUN unless you pass --force: it only prints what it WOULD remove.
#   - Every step prints each path with its size before touching it.
#   - Prints disk usage before and after, and the space actually reclaimed.
#   - Idempotent and re-runnable.
#   - Meant to run as YOU: only --system needs root, and it escalates itself.
#     Running the whole thing under sudo also works — it cleans the invoking
#     user's home, not root's.
#
# Usage:
#   ./wsl-cleanup.sh                    # DRY RUN — show what would go
#   ./wsl-cleanup.sh --force            # actually clean
#   ./wsl-cleanup.sh --force --all      # everything below as well
#   ./wsl-cleanup.sh --help
#
# Installed programs are the other half of a full disk, and no cache sweep will
# ever touch them. Two modes report on and remove them instead:
#   --list-installed [word]   everything installed on this box, largest first,
#                             from apt, global npm, cargo, go install, nvm, the
#                             Android SDK and Zed's agent registry. Each line
#                             starts with a <manager>:<name> handle.
#   --uninstall <handle>      remove one, using whatever installed it: apt
#                             purges, npm and cargo and sdkmanager uninstall,
#                             and a directory nobody owns is simply dropped. A
#                             bare name is fine when only one manager has it.
#                             DRY RUN as well — it prints the exact command, and
#                             for apt the full cascade, until you add --force.
#                             Essential and required apt packages are refused.
#
# The default run removes only data that rebuilds itself locally: editor and
# compiler caches, build output under ~/Development, the ~140M payload the
# Copilot CLI self-extracts into ~/.cache/copilot, and every superseded version
# of a toolchain or extension that keeps more than one (Go toolchains, Cursor
# extensions, Gradle distributions, Node versions, Android build-tools, agent
# releases). Only the newest working version is preserved.
#
# Opt-in, because each of these costs a re-download rather than a rebuild
# (--all turns them all on except --purge-pgtest, which is data, not cache):
#   --deep              Go module cache, npm/cargo package caches, npx cache,
#                       Playwright browser caches, Gradle transforms, and
#                       node_modules dirs in ~/Development
#   --system            apt cache + package lists + orphaned packages, the
#                       systemd journal, rotated logs under /var/log,
#                       incompatible global npm architecture binaries, and
#                       ROOT'S OWN HOME caches. Needs sudo.
#   --purge-bak         *.bak copies in /opt/ownlocator and stale backups
#                       in /var/lib/ownlocator/media-wsl-backup
#   --purge-pgtest      ~/.local/pgtest, the local Postgres test cluster
#
# Tunables (env vars):
#   DEV_DIR=~/Development     where your repos live
#   JOURNAL_KEEP=200M         cap the systemd journal to this size
#   TMP_AGE_DAYS=7            delete temp files older than N days
#
# WSL note: freeing space inside the VM does NOT shrink the .vhdx on Windows.
# The script automatically detects the host .vhdx path and prints instructions.
#
set -euo pipefail

# Only --system needs root, and it escalates by itself — but reaching for sudo
# first is the natural thing to do, and under sudo HOME is /root. That would
# point DEV_DIR and every ~/.cache path in here at the wrong home and find
# nothing (the reported "no such directory: /root/Development"). Resolve the
# invoking user's home instead of failing on it; deleting their caches as root
# works the same, and the --system step then needs no second password.
if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  RUN_USER="$SUDO_USER"
  export HOME
else
  RUN_USER="$(id -un)"
fi

DEV_DIR="${DEV_DIR:-$HOME/Development}"
JOURNAL_KEEP="${JOURNAL_KEEP:-200M}"
TMP_AGE_DAYS="${TMP_AGE_DAYS:-7}"

FORCE=0
DEEP=0
SYSTEM=0
PURGE_PGTEST=0
PURGE_BAK=0
LIST_INSTALLED=0
LIST_FILTER=""
UNINSTALL=""

# --uninstall takes a value, which `for arg in "$@"` cannot consume.
while (( $# )); do
  arg="$1"
  case "$arg" in
    --force)            FORCE=1 ;;
    --deep)             DEEP=1 ;;
    --system)           SYSTEM=1 ;;
    --purge-pgtest)     PURGE_PGTEST=1 ;;
    --purge-bak)        PURGE_BAK=1 ;;
    --purge-agent-logs)
      # Preserved by user policy: agent sessions and memories must never be deleted
      echo "Note: AI agent sessions and memory are permanently protected by policy and will not be purged." >&2
      ;;
    # Everything that is still only derived data. pgtest stays out: it is a
    # database directory, and "probably scratch" is not good enough for one.
    --all)              DEEP=1; SYSTEM=1; PURGE_BAK=1 ;;
    -h|--help)
      # The whole header block, however long it grows: stop at the first line
      # that isn't a comment rather than at a line number that goes stale.
      awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
    --list-installed)
      LIST_INSTALLED=1
      # An optional filter word may follow it — but not another flag.
      if [[ -n "${2:-}" && "${2:-}" != -* ]]; then LIST_FILTER="$2"; shift; fi ;;
    --list-installed=*) LIST_INSTALLED=1; LIST_FILTER="${arg#*=}" ;;
    --uninstall)
      UNINSTALL="${2:-}"
      [[ -n "$UNINSTALL" ]] || { echo "--uninstall needs a name (try --list-installed)" >&2; exit 2; }
      shift ;;
    --uninstall=*)      UNINSTALL="${arg#*=}" ;;
    *)
      echo "unknown option: $arg (try --help)" >&2
      exit 2 ;;
  esac
  shift
done

# ── helpers ──────────────────────────────────────────────────────────────────
c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'

step() { printf '\n%s==>%s %s\n' "$c_bold" "$c_rst" "$*"; }
note() { printf '   %s%s%s\n' "$c_dim" "$*" "$c_rst"; }
keep() { printf '   %skeep%s    %s\n' "$c_grn" "$c_rst" "${1/#$HOME/\~}"; }

human()      { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }
avail_bytes(){ echo $(( $(df --output=avail "$HOME" | tail -1) * 1024 )); }
size_of()    { du -sB1 "$1" 2>/dev/null | cut -f1 || echo 0; }

TOTAL=0   # bytes of everything this run dropped (or would drop)

# The one place anything is deleted. Prints the path with its size, adds it to
# the running total, and removes it only under --force. chmod first: Go's
# module cache is deliberately read-only, and rm -rf alone bounces off it.
# DROP_QUIET suppresses the per-path line without touching the accounting, for
# the one caller that removes hundreds of entries at once and reports a total.
DROP_QUIET=0

drop() {
  local p="$1" b
  [[ -e "$p" ]] || return 0
  b="$(size_of "$p")"
  TOTAL=$(( TOTAL + b ))
  (( DROP_QUIET )) || printf '   %s%8s%s  %s\n' "$c_ylw" "$(human "$b")" "$c_rst" "${p/#$HOME/\~}"
  if [[ "$FORCE" -eq 1 ]]; then
    chmod -R u+w "$p" 2>/dev/null || true
    rm -rf -- "$p" 2>/dev/null || sudo rm -rf -- "$p" 2>/dev/null || true
  fi
}

# Children of $1 sorted by embedded version number, newest last. Used where the
# directory name carries a real version (go1.26.5, v22.22.1, 35.0.0).
by_version() { ls -1 "$1" 2>/dev/null | sort -V; }

# Children of $1 sorted by mtime, newest last. Used where the name is a commit
# hash or an opaque build id and only "when did it arrive" can order them.
# Matches files as well as directories: ~/.zed_server keeps each release as a
# bare binary, not a folder.
by_mtime() { ls -1dt "$1"/* 2>/dev/null | sed 's:/*$::' | tac; }

# Is anything running out of this directory right now? Never delete the tools
# holding the session that is doing the deleting.
in_use() {
  local p="$1"
  ls -l /proc/*/exe /proc/*/cwd 2>/dev/null | grep -q -- "$p" && return 0
  return 1
}

# Is a copilot process still executing out of this unpacked version directory?
# in_use() cannot see it: the process runs the installed binary, not anything
# under the cache. The CLI marks the copy it unpacked with inuse.<pid>.lock
# instead, and removes that on exit.
copilot_pkg_live() {
  local d="$1" lock pid
  for lock in "$d"/inuse.*.lock; do
    [[ -e "$lock" ]] || continue
    pid="${lock##*/inuse.}"; pid="${pid%.lock}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

# ~/.copilot — sessions, transcripts, memory, config — is never touched. This
# is the other directory, and despite its size every byte of it is derived:
# the CLI ships as one self-extracting binary and unpacks its ~140M payload
# into pkg/<platform>/<version>/ the first time it runs, beside two JSON files
# whose own first line reads "Disposable cache … safe to delete. Managed
# automatically." and a folder of cached MCP tool schemas. The next launch
# re-extracts it from the installed binary in about two seconds with no
# network, which is why this is in the default run and not behind --deep.
clean_copilot_cache() {
  local h="$1" who="$2"
  local cache="$h/.cache/copilot"
  step "GitHub Copilot CLI cache ($who) — ~/.copilot itself is never touched"
  if [[ ! -d "$cache" ]]; then note "none"; return 0; fi

  local d live=0
  local -a vers=() dead=()
  mapfile -t vers < <(find "$cache/pkg" -mindepth 2 -maxdepth 2 -type d 2>/dev/null)
  for d in "${vers[@]}"; do
    if copilot_pkg_live "$d"; then keep "$d"; live=1; else dead+=("$d"); fi
  done

  # Pulling the payload out from under a live CLI would break that session —
  # possibly the one running this script. If any copy is held, only the
  # superseded ones go and the small files wait for the next run.
  if (( live )); then
    note "a copilot process is running out of it — leaving what it holds"
    for d in "${dead[@]}"; do drop "$d"; done
    (( ${#dead[@]} )) || note "nothing else to drop"
  else
    note "re-extracted from the installed binary on next launch: local, offline, ~2s"
    drop "$cache"
  fi
}

# Zed opens a crash-handler socket per instance under ~/.cache/zed and never
# reaps it, so one accumulates per editor launch — a few hundred over a few
# months. They are zero-byte unix sockets: what they cost is directory entries
# and the impression that ~/.cache is a junk drawer, not disk. A socket whose
# pid is still alive belongs to a running editor and stays; the pid is the
# trailing field of the name, the same trick copilot_pkg_live() plays.
clean_zed_sockets() {
  local h="$1" who="$2"
  local d="$h/.cache/zed"
  step "Zed crash-handler sockets ($who)"
  if [[ ! -d "$d" ]]; then note "none"; return 0; fi

  local sock pid live=0
  local -a dead=()
  for sock in "$d"/*crash-handler-*; do
    [[ -S "$sock" ]] || continue
    pid="${sock##*-}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      live=$(( live + 1 ))
    else
      dead+=("$sock")
    fi
  done

  if (( ${#dead[@]} == 0 )); then
    note "none stale${live:+ ($live held by running editors)}"
    return 0
  fi

  DROP_QUIET=1
  for sock in "${dead[@]}"; do drop "$sock"; done
  DROP_QUIET=0
  note "${#dead[@]} stale sockets from exited editors ($live still running, kept)"
}

# What this machine can actually execute, in the tokens npm and prebuildify use
# for their directory names.
HOST_OS="$(uname -s | tr "[:upper:]" "[:lower:]")"
case "$HOST_OS" in darwin) HOST_OS=darwin ;; linux) HOST_OS=linux ;; esac
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH=x64 ;;
  aarch64|arm64) HOST_ARCH=arm64 ;;
  *) HOST_ARCH="$(uname -m)" ;;
esac
HOST_LIBC=glibc
ldd --version 2>&1 | head -1 | grep -qi musl && HOST_LIBC=musl

# A Windows PE, a Mach-O or an arm64 ELF cannot execute on this machine under
# any circumstances. Untagged names return false: silence is not an invitation.
foreign_os_or_arch() {
  local name="$1" os="" arch=""
  case "$name" in
    *darwin*|*macos*)          os=darwin ;;
    *win32*|*win10*|*windows*) os=win32 ;;
    *freebsd*)                 os=freebsd ;;
    *android*)                 os=android ;;
    *linuxmusl*|*linux*)       os=linux ;;
  esac
  case "$name" in
    *arm64*|*aarch64*)  arch=arm64 ;;
    *x64*|*x86_64*)     arch=x64 ;;
    *ia32*)             arch=ia32 ;;
  esac
  [[ -n "$os"   && "$os"   != "$HOST_OS"   ]] && return 0
  [[ -n "$arch" && "$arch" != "$HOST_ARCH" ]] && return 0
  return 1
}

# musl is not a foreign platform by itself. A statically linked musl binary runs
# perfectly well on glibc, and that is how Codex ships: vendor/ holds only
# x86_64-unknown-linux-musl and codex.js resolves exactly that path, so reading
# the token as "cannot run here" would delete the working program. A musl build
# is surplus only when the same package offers this machine's libc right beside
# it — Copilot does, and its loader reaches for the musl one solely when
# detect-libc reports a non-glibc Linux.
surplus_libc_build() {
  local d="$1" base parent alt
  [[ "$HOST_LIBC" == glibc ]] || return 1
  base="$(basename "$d")"
  case "$base" in *musl*) ;; *) return 1 ;; esac
  parent="$(dirname "$d")"
  for alt in "${base/linuxmusl/linux}" "${base%-musl}-gnu" "${base%-musl}"; do
    [[ "$alt" != "$base" && -d "$parent/$alt" ]] && return 0
  done
  return 1
}

# npm publishes one package per platform and picks at load time, so an x86-64
# Linux box ends up carrying binaries for macOS, Windows and arm that it cannot
# run at all. Two hardcoded paths used to cover one package; this finds them
# wherever they are installed.
#
# Two conventions are walked:
#   anything under node_modules/<scope>/    npm optional platform deps
#   anything under a prebuilds/ directory   prebuildify / node-gyp-build
# A directory whose name carries no platform token is never considered, and a
# musl build with no glibc sibling is left alone — see surplus_libc_build.
prune_foreign_platform_binaries() {
  local who="$1"; shift
  step "Binaries for other platforms ($who) — this box is $HOST_OS/$HOST_ARCH/$HOST_LIBC"
  # No -prune on the find: a scope directory matches the first pattern, and
  # pruning there would stop the walk before reaching the prebuilds/ nested
  # several node_modules deeper — which is where 58M of Windows node-pty hides.
  # Descending everywhere instead means a match can sit inside another match, so
  # sorted order plus a list of what was already taken keeps the accounting from
  # counting the same bytes twice in a dry run.
  local root d t skip found=0
  local -a taken=()
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r d; do
      foreign_os_or_arch "$(basename "$d")" || surplus_libc_build "$d" || continue
      skip=0
      for t in "${taken[@]}"; do [[ "$d" == "$t"/* ]] && { skip=1; break; }; done
      (( skip )) && continue
      taken+=("$d")
      drop "$d"; found=1
    done < <(find "$root" -maxdepth 10 -type d \
               \( -path '*/node_modules/@*/*' -o -path '*/prebuilds/*' \) 2>/dev/null | sort)
  done
  (( found )) || note "none"
}

# Keep the newest child of $1 (by mtime), drop the rest. For directories whose
# entries are versions of one program under opaque names — commit hashes, build
# ids — where only arrival order can rank them.
prune_keep_newest() {
  local d="$1" old
  [[ -d "$d" ]] || return 0
  mapfile -t vers < <(by_mtime "$d")
  (( ${#vers[@]} > 0 )) || return 0
  keep "${vers[-1]}"
  for old in "${vers[@]:0:${#vers[@]}-1}"; do
    if in_use "$old"; then note "in use, kept: ${old/#$HOME/\~}"; else drop "$old"; fi
  done
}

# Cursor Server keeps old versions of extensions side-by-side on update.
# Group extensions by package name, keep ONLY the latest version, drop older ones.
prune_cursor_extensions() {
  local ext_dir="$1"
  [[ -d "$ext_dir" ]] || return 0
  local bases base
  mapfile -t bases < <(find "$ext_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sed -E 's/^(.*)-[0-9]+\.[0-9]+.*$/\1/' | sort -u)
  for base in "${bases[@]}"; do
    [[ -n "$base" ]] || continue
    mapfile -t vers < <(find "$ext_dir" -mindepth 1 -maxdepth 1 -type d -name "$base-[0-9]*" 2>/dev/null | sort -V)
    (( ${#vers[@]} > 0 )) || continue
    keep "${vers[-1]}"
    for ((i = 0; i < ${#vers[@]} - 1; i++)); do
      local old="${vers[i]}"
      if in_use "$old"; then note "in use, kept: ${old/#$HOME/\~}"; else drop "$old"; fi
    done
  done
}

# Go pulls a whole toolchain (~240 MB) whenever a go.mod raises its `go`
# directive. Only keep the newest toolchain: Go 1.26.x compiles older 1.26 modules seamlessly.
prune_go_toolchains() {
  local dir="$1"
  mapfile -t TCS < <(ls -1 "$dir" 2>/dev/null | grep '^toolchain@' | sort -V)
  (( ${#TCS[@]} > 0 )) || { note "none"; return 0; }
  keep "$dir/${TCS[-1]}"
  for ((i = 0; i < ${#TCS[@]} - 1; i++)); do
    drop "$dir/${TCS[i]}"
  done
}

# Detect actual Windows path of this WSL2 instance's ext4.vhdx file
detect_vhdx_path() {
  local vhdx_path=""
  local mounted_c=0

  if [[ ! -f /mnt/c/Windows/System32/reg.exe ]]; then
    if [[ -d /mnt/c ]]; then
      if [[ "$EUID" -eq 0 ]] || sudo -n true 2>/dev/null; then
        mount -t drvfs C: /mnt/c 2>/dev/null && mounted_c=1 || sudo -n mount -t drvfs C: /mnt/c 2>/dev/null && mounted_c=1 || true
      fi
    fi
  fi

  if [[ -f /mnt/c/Windows/System32/reg.exe ]]; then
    local reg_out base_path vhd_name
    reg_out="$(/mnt/c/Windows/System32/reg.exe query "HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss" /s 2>/dev/null | tr -d '\r')"
    base_path="$(echo "$reg_out" | awk '/BasePath/ {print $3}' | head -1)"
    vhd_name="$(echo "$reg_out" | awk '/VhdFileName/ {print $3}' | head -1)"
    [[ -z "$vhd_name" ]] && vhd_name="ext4.vhdx"
    if [[ -n "$base_path" ]]; then
      base_path="${base_path%\\}"
      vhdx_path="${base_path}\\${vhd_name}"
    fi
  fi

  if [[ "$mounted_c" -eq 1 ]]; then
    umount /mnt/c 2>/dev/null || sudo -n umount /mnt/c 2>/dev/null || true
  fi

  if [[ -z "$vhdx_path" ]]; then
    vhdx_path='D:\Temp\wsl2\ext4.vhdx'
  fi

  echo "$vhdx_path"
}

# Everything that a home directory accumulates regardless of whose home it is.
# Called for you, and again for /root under --system.
clean_home_caches() {
  local h="$1" who="$2"

  # Zed ships its own Node and points npm's cache at it.
  step "Zed npm cache ($who)"
  local found=0 c
  for c in "$h"/.local/share/zed/node/*/cache; do
    [[ -d "$c" ]] || continue
    drop "$c"; found=1
  done
  (( found )) || note "none"

  # work/ is where extensions are unpacked and compiled; the built .wasm lives
  # one level up in remote_extensions/<name>/ and is kept.
  step "Zed extension build scratch ($who)"
  drop "$h/.local/share/zed/remote_extensions/work"
  drop "$h/.local/share/zed/remote_extensions/uploads"
  # mapfile, not `find | while`: under `set -o pipefail` a find that exits 1 on a
  # missing directory becomes the pipeline's status and `set -e` kills the run.
  # root has no ~/.local/share/zed, which is how --system silently aborted here
  # and never reached root's 1.6G below.
  local f
  local -a zlogs=()
  mapfile -t zlogs < <(find "$h/.local/share/zed/logs" -type f -name '*.log.*' 2>/dev/null)
  for f in "${zlogs[@]}"; do drop "$f"; done

  step "Editor servers and Node runtimes ($who) — keep the newest of each"
  local d
  for d in "$h/.cursor-server/bin" "$h/.zed_server" "$h/.local/share/zed/node"; do
    prune_keep_newest "$d"
  done

  step "Cursor Server extensions ($who) — keep the newest release of each"
  prune_cursor_extensions "$h/.cursor-server/extensions"
  drop "$h/.cursor-server/data/CachedExtensionVSIXs"

  step "Zed external agents ($who) — keep the newest release of each"
  local agent rels
  for agent in "$h"/.local/share/zed/external_agents/registry/*/; do
    agent="${agent%/}"
    mapfile -t rels < <(ls -1dt "$agent"/v_*/ 2>/dev/null | sed 's:/*$::' | tac)
    (( ${#rels[@]} > 1 )) || continue
    keep "${rels[-1]}"
    for d in "${rels[@]:0:${#rels[@]}-1}"; do drop "$d"; done
  done

  step "Go toolchains ($who) — keep the newest toolchain"
  prune_go_toolchains "$h/go/pkg/mod/golang.org"

  # Compiler and developer caches. Rebuilds locally on demand.
  # AI agent memory and sessions are NEVER touched here — only transient scratch caches.
  step "Compiler, font and GPU caches ($who)"
  drop "$h/.cache/go-build"
  drop "$h/.cache/staticcheck"
  drop "$h/.cache/gopls"
  drop "$h/.cache/goimports"
  drop "$h/.cache/typescript"
  drop "$h/.cache/node-gyp"
  drop "$h/.cache/cloud-code"
  drop "$h/.cache/claude-cli-nodejs"
  drop "$h/.cache/opencode"
  drop "$h/.cache/mesa_shader_cache"
  drop "$h/.cache/fontconfig"
  # Antigravity's agent server unpacks an embedded ripgrep here, named by
  # content hash, and re-extracts it from the installed .par when it is gone.
  drop "$h/.cache/jetski"
  drop "$h/.cache/JNA/temp"
  drop "$h/.cache/main.kts.compiled.cache"
  drop "$h/.config/JetBrains/analyzer/workspaces"
  drop "$h/.codex/.tmp"
  drop "$h/.codex/plugins/cache"
  drop "$h/.gemini/tmp"
  drop "$h/.gradle/caches/build-cache-1"
  drop "$h/.gradle/daemon"
  drop "$h/.gradle/kotlin-profile"

  clean_copilot_cache "$h" "$who"
  clean_zed_sockets "$h" "$who"
  prune_foreign_platform_binaries "$who" \
    "$h/.local/share/zed/external_agents" "$h/.local/share/zed/node"

  # launchpadlib caches Launchpad's API responses for add-apt-repository. Only
  # the cache subtree: the library also files OAuth credentials in this
  # directory on machines that have logged in.
  drop "$h/.launchpadlib/api.launchpad.net/cache"

  # Package caches and heavy dependencies. Waiting for --deep because they re-download.
  [[ "$DEEP" -eq 1 ]] || return 0
  step "Package caches ($who, --deep)"
  local m tr
  local sub
  for m in "$h"/go/pkg/mod/*/; do
    m="${m%/}"
    # golang.org holds the downloaded toolchains, pruned above by version — but
    # also golang.org/x, which is ordinary module cache and was being spared by
    # association with them. Skip the toolchains by name, not the parent.
    if [[ "$(basename "$m")" == "golang.org" ]]; then
      for sub in "$m"/*; do
        [[ "$(basename "$sub")" == toolchain@* ]] && continue
        drop "$sub"
      done
      continue
    fi
    drop "$m"
  done
  drop "$h/.npm/_npx"
  drop "$h/.npm/_cacache"
  drop "$h/.cargo/registry/cache"
  drop "$h/.cargo/registry/src"
  drop "$h/.cache/cargo-xwin"
  drop "$h/.cache/pip"
  drop "$h/.cache/ms-playwright"
  drop "$h/.cache/ms-playwright-go"
  drop "$h/.gradle/caches/modules-2"
  for tr in "$h"/.gradle/caches/*/transforms; do
    [[ -d "$tr" ]] || continue
    drop "$tr"
  done
  drop "$h/.gradle/.tmp"
}

# ── installed programs: inventory and removal ────────────────────────────────
# Everything above removes derived data. This is the other half of a full disk:
# whole programs somebody installed on purpose, which no cache sweep will ever
# touch. The script has always ended by suggesting `apt-mark showmanual | ...`
# and leaving the reader to it; these two modes do that properly, across every
# installer this box actually uses, and let one entry be removed by the tool
# that owns it rather than by rm.
#
# A handle is <manager>:<name>. The prefix disambiguates — gopls is plausibly a
# Go binary and a Zed language server at once — and it selects the removal
# command: apt purges, npm and cargo and sdkmanager uninstall, and the rest are
# directories one owner unpacked and can simply lose.
#
# Both modes honour the dry run. `--uninstall X` prints the exact command and
# the bytes it would return; only --force runs it.

# Where a global npm install can land. `npm root -g` answers for whichever node
# is first on PATH, which on this box is Zed's, not the system one.
npm_global_roots() {
  local r
  for r in /usr/local/lib/node_modules /usr/lib/node_modules "$(npm root -g 2>/dev/null)"; do
    [[ -n "$r" && -d "$r" ]] && echo "$r"
  done | sort -u
}

# One line per installed program: bytes, handle, version, where it came from.
# Sizes are real disk usage except for apt, which is asked rather than measured:
# a package's files are scattered over the whole filesystem and dpkg is the only
# thing that knows which ones are its.
inventory() {
  local d n v b root

  if command -v dpkg-query >/dev/null 2>&1; then
    declare -A manual=()
    while read -r n; do [[ -n "$n" ]] && manual["$n"]=1; done < <(apt-mark showmanual 2>/dev/null)
    while IFS=$'\t' read -r b n v; do
      # Dependencies nobody chose are noise here, and autoremove already deals
      # with the orphans among them.
      [[ -n "${manual[$n]:-}" ]] || continue
      printf '%s\tapt:%s\t%s\tapt\n' "$(( b * 1024 ))" "$n" "$v"
    done < <(dpkg-query -Wf '${Installed-Size}\t${Package}\t${Version}\n' 2>/dev/null)
  fi

  while read -r root; do
    for d in "$root"/*; do
      [[ -d "$d" ]] || continue
      n="$(basename "$d")"
      # A scope directory is not a package; the packages are inside it.
      if [[ "$n" == @* ]]; then
        for d in "$d"/*; do
          [[ -d "$d" ]] || continue
          printf '%s\tnpm:%s/%s\t%s\t%s\n' "$(size_of "$d")" "$n" "$(basename "$d")" \
            "$(npm_pkg_version "$d")" "$root"
        done
      else
        printf '%s\tnpm:%s\t%s\t%s\n' "$(size_of "$d")" "$n" "$(npm_pkg_version "$d")" "$root"
      fi
    done
  done < <(npm_global_roots)

  # registry/npx is not an agent, it is a shelf of them — the same reason an npm
  # scope directory gets opened rather than counted.
  local sub
  for d in "$HOME"/.local/share/zed/external_agents/registry/*; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    [[ "$n" == icons ]] && continue
    if [[ "$n" == npx ]]; then
      for sub in "$d"/*; do
        [[ -d "$sub" ]] || continue
        printf '%s\tagent:npx/%s\t%s\tzed agent (npx)\n' "$(size_of "$sub")" \
          "$(basename "$sub")" "$(npm_pkg_version "$sub")"
      done
    else
      printf '%s\tagent:%s\t%s\tzed external agent\n' "$(size_of "$d")" "$n" \
        "$(agent_release_version "$d")"
    fi
  done

  while read -r n v; do
    [[ -n "$n" ]] || continue
    printf '%s\tcargo:%s\t%s\tcargo install\n' "$(size_of "$HOME/.cargo/bin/$n")" "$n" "$v"
  done < <(cargo install --list 2>/dev/null | sed -n 's/^\([^ ]*\) \(v[^:]*\):$/\1 \2/p')

  for d in "$HOME"/go/bin/*; do
    [[ -f "$d" ]] || continue
    printf '%s\tgo:%s\t-\tgo install\n' "$(size_of "$d")" "$(basename "$d")"
  done

  for d in "$HOME"/.nvm/versions/node/*; do
    [[ -d "$d" ]] || continue
    printf '%s\tnvm:%s\t%s\tnvm\n' "$(size_of "$d")" "$(basename "$d")" "$(basename "$d")"
  done

  local sdk="${ANDROID_HOME:-$HOME/Android/Sdk}"
  for d in "$sdk"/*; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    [[ "$n" == licenses ]] && continue
    printf '%s\tsdk:%s\t-\tandroid sdk\n' "$(size_of "$d")" "$n"
  done
}

# Zed names an agent release v_<version>_<hash>_<hash>. Only the version part
# says anything to a reader.
agent_release_version() {
  local v
  v="$(basename "$(ls -1dt "$1"/v_*/ 2>/dev/null | head -1)" 2>/dev/null \
       | sed -n 's/^v_\([^_]*\)_.*/\1/p')"
  echo "${v:--}"
}

# package.json is the only place an npm package states its own version, and a
# missing or unreadable one is not worth failing over.
npm_pkg_version() {
  local v
  v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/package.json" 2>/dev/null | head -1)"
  echo "${v:--}"
}

# --list-installed [pattern]
cmd_list_installed() {
  local pattern="${1:-}" total=0 b h v src n=0
  step "Installed programs${pattern:+ matching \"$pattern\"} — largest first"
  while IFS=$'\t' read -r b h v src; do
    [[ -n "$pattern" && "$h" != *"$pattern"* ]] && continue
    total=$(( total + b )); n=$(( n + 1 ))
    printf '   %s%8s%s  %-40s %-16s %s%s%s\n' \
      "$c_ylw" "$(human "$b")" "$c_rst" "$h" "${v:--}" "$c_dim" "$src" "$c_rst"
  done < <(inventory | sort -rn -t$'\t' -k1,1)

  if (( n == 0 )); then note "nothing matched"; return 0; fi
  note "$n program$( (( n == 1 )) || echo s ), $(human "$total") total — apt reports dpkg's figure, the rest are measured"
  note "remove one with:  $0 --uninstall <handle>   (add --force to actually do it)"
  note "apt lines are manually installed packages only — a dependency nobody chose is not"
  note "  a program somebody installed, and --system already autoremoves the orphans among"
  note "  them. --uninstall shows what a package drags out with it before it does anything."

  # Real space, visible from here, owned by no installer: unpacking these was
  # somebody's shell command and removing them has to be one too.
  local d shown=0
  for d in /opt/* /usr/local/lib /usr/local/x-ui; do
    [[ -d "$d" ]] || continue
    (( shown )) || note "no installer owns these — remove them by hand:"
    shown=1
    printf '   %s%8s  %s%s\n' "$c_dim" "$(human "$(size_of "$d")")" "$d" "$c_rst"
  done
}

# --uninstall <handle>. Resolves a bare name against the inventory, refuses the
# packages the system is built out of, and otherwise hands the job to whoever
# installed the thing.
cmd_uninstall() {
  local want="$1" mgr name path b h v src
  local -a matches=()

  while IFS=$'\t' read -r b h v src; do
    if [[ "$want" == *:* ]]; then [[ "$h" == "$want" ]] && matches+=("$b|$h|$src")
    else                          [[ "${h#*:}" == "$want" ]] && matches+=("$b|$h|$src"); fi
  done < <(inventory)

  if (( ${#matches[@]} == 0 )); then
    # dpkg knows about thousands of packages the inventory deliberately hides.
    # Saying "not installed" about libc6 would simply be false.
    if dpkg-query -W "${want#apt:}" >/dev/null 2>&1; then
      echo "${want#apt:} is installed, but as a dependency rather than a choice — this" >&2
      echo "script only offers to remove what someone installed on purpose. Remove" >&2
      echo "whatever pulled it in, or let --force --system autoremove the orphans." >&2
      return 1
    fi
    echo "not installed, or not something this script can see: $want" >&2
    echo "look for it with:  $0 --list-installed ${want}" >&2
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    echo "\"$want\" is ambiguous — qualify it with the manager:" >&2
    local m rest
    for m in "${matches[@]}"; do rest="${m#*|}"; echo "  ${rest%%|*}" >&2; done
    return 2
  fi

  IFS='|' read -r b h src <<< "${matches[0]}"
  mgr="${h%%:*}"; name="${h#*:}"
  step "Uninstall $h  ($(human "$b"))"

  # A directory is the entire installation, so removal goes through drop() like
  # everything else the script deletes — same dry run, same accounting.
  case "$mgr" in
    agent) path="$HOME/.local/share/zed/external_agents/registry/$name" ;;
    go)    path="$HOME/go/bin/$name" ;;
    nvm)   path="$HOME/.nvm/versions/node/$name" ;;
    *)     path="" ;;
  esac
  if [[ -n "$path" ]]; then
    drop "$path"
    [[ "$FORCE" -eq 1 ]] && note "removed" || note "re-run with --force to apply"
    return 0
  fi

  local -a cmd=()
  case "$mgr" in
    apt)
      local ess prio
      IFS=$'\t' read -r ess prio < <(dpkg-query -Wf '${Essential}\t${Priority}\n' "$name" 2>/dev/null)
      # apt will take half the system with a required package if asked, and the
      # answer to "are you sure" is no. This is a disk-space tool.
      if [[ "$ess" == yes || "$prio" == required || "$prio" == important ]]; then
        echo "refusing: $name is Essential=$ess, Priority=$prio — the system is built out of it" >&2
        return 1
      fi
      cmd=(apt-get purge -y "$name")
      [[ "$EUID" -eq 0 ]] || cmd=(sudo "${cmd[@]}")
      if [[ "$FORCE" -eq 0 ]]; then
        # -s needs no root and is the only honest preview: the cascade matters
        # far more than the one package that was asked for.
        note "apt would take these with it:"
        apt-get -s purge "$name" 2>/dev/null | grep -E '^(Remv|Purg)' | sed 's/^/     /' \
          || note "     (only $name)"
      fi ;;
    npm)
      # `npm -g` resolves against whichever node is first on PATH — Zed's here,
      # not the one that owns /usr/local. Point it at the root the package was
      # actually found in.
      cmd=(npm uninstall -g --prefix "${src%/lib/node_modules}" "$name")
      [[ -w "$src" ]] || cmd=(sudo "${cmd[@]}") ;;
    cargo) cmd=(cargo uninstall "$name") ;;
    sdk)   cmd=("${ANDROID_HOME:-$HOME/Android/Sdk}/cmdline-tools/latest/bin/sdkmanager" --uninstall "$name") ;;
    *)     echo "no removal path for manager: $mgr" >&2; return 1 ;;
  esac

  if [[ "$FORCE" -eq 0 ]]; then
    note "[dry] ${cmd[*]}"
    note "would return about $(human "$b") — re-run with --force to apply"
    return 0
  fi
  note "${cmd[*]}"
  if "${cmd[@]}"; then
    printf '   removed %s, about %s%s%s returned\n' "$h" "$c_ylw" "$(human "$b")" "$c_rst"
  else
    echo "uninstall failed: ${cmd[*]}" >&2
    return 1
  fi
}

# ── preflight ────────────────────────────────────────────────────────────────
if [[ "$FORCE" -eq 0 ]]; then
  printf '%sDRY RUN%s — nothing will be deleted. Re-run with --force to apply.\n' "$c_ylw" "$c_rst"
fi
if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  note "running under sudo — cleaning ${RUN_USER}'s home ($HOME); --system needs no second password"
fi
# These two are modes rather than steps: they answer about installed programs
# instead of derived data, and they exit rather than fall through into a cleanup
# nobody asked for. Neither needs DEV_DIR to exist.
if (( LIST_INSTALLED )); then
  cmd_list_installed "$LIST_FILTER"
  exit 0
fi
if [[ -n "$UNINSTALL" ]]; then
  cmd_uninstall "$UNINSTALL"
  exit $?
fi

[[ -d "$DEV_DIR" ]] || {
  echo "no such directory: $DEV_DIR" >&2
  echo "point it somewhere real:  DEV_DIR=/path/to/repos $0 $*" >&2
  exit 1
}

step "Disk before"
df -h "$HOME"
BEFORE="$(avail_bytes)"

# ── 1. User home directory caches ────────────────────────────────────────────
clean_home_caches "$HOME" "$RUN_USER"

# ── 2. Superseded copies of the build tooling ────────────────────────────────
# Gradle distributions: keep what wrappers pin
step "Gradle distributions and version caches (keep what the wrappers pin)"
mapfile -t PINNED < <(
  find "$DEV_DIR" -maxdepth 6 -name gradle-wrapper.properties 2>/dev/null \
    | xargs -r grep -h '^distributionUrl' 2>/dev/null \
    | sed -E 's:.*/(gradle-[0-9.]+(-[a-z]+)?)\.zip.*:\1:' | sort -u
)
if (( ${#PINNED[@]} == 0 )); then
  note "no gradle wrapper found under ${DEV_DIR/#$HOME/\~} — skipping, nothing to compare against"
else
  for p in "${PINNED[@]}"; do keep "$HOME/.gradle/wrapper/dists/$p"; done
  for dist in "$HOME"/.gradle/wrapper/dists/*/; do
    dist="${dist%/}"; name="$(basename "$dist")"
    printf '%s\n' "${PINNED[@]}" | grep -qx "$name" || drop "$dist"
  done
  mapfile -t PINNED_VER < <(printf '%s\n' "${PINNED[@]}" | sed -E 's/^gradle-([0-9.]+).*/\1/' | sort -u)
  for cache in "$HOME"/.gradle/caches/*/; do
    cache="${cache%/}"; name="$(basename "$cache")"
    [[ "$name" =~ ^[0-9]+\.[0-9]+ ]] || continue        # skip modules-2, jars-9, …
    printf '%s\n' "${PINNED_VER[@]}" | grep -qx "$name" && { keep "$cache"; continue; }
    drop "$cache"
  done
fi

# Node versions under nvm: keep newest + every .nvmrc pin
step "Node versions under nvm (keep the newest + every .nvmrc pin)"
NVM_DIR_VERS="$HOME/.nvm/versions/node"
if [[ -d "$NVM_DIR_VERS" ]]; then
  mapfile -t NODES < <(by_version "$NVM_DIR_VERS")
  mapfile -t PINS < <(find "$DEV_DIR" -maxdepth 3 -name .nvmrc -exec cat {} \; 2>/dev/null \
                       | tr -d ' v' | sed '/^$/d' | sort -u)
  if (( ${#NODES[@]} > 1 )); then
    keep "$NVM_DIR_VERS/${NODES[-1]}"
    for old in "${NODES[@]:0:${#NODES[@]}-1}"; do
      if printf '%s\n' "${PINS[@]:-}" | grep -q "${old#v}"; then
        note "pinned by .nvmrc, kept: $old"
      else
        drop "$NVM_DIR_VERS/$old"
      fi
    done
  else
    note "one version, nothing to prune"
  fi
else
  note "nvm not installed"
fi

# Android build-tools: keep newest
step "Android SDK build-tools (keep the newest)"
BT="${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools"
if [[ -d "$BT" ]]; then
  mapfile -t TOOLS < <(by_version "$BT")
  if (( ${#TOOLS[@]} > 1 )); then
    keep "$BT/${TOOLS[-1]}"
    for old in "${TOOLS[@]:0:${#TOOLS[@]}-1}"; do drop "$BT/$old"; done
  else
    note "one version, nothing to prune"
  fi
else
  note "no Android SDK at ${BT/#$HOME/\~}"
fi

# ── 3. Build output under ~/Development ──────────────────────────────────────
step "Build output under ${DEV_DIR/#$HOME/\~}"
mapfile -t ARTIFACTS < <(
  find "$DEV_DIR" -maxdepth 5 -type d \
    \( -name target -o -name build -o -name dist -o -name .gradle \
       -o -name .kotlin -o -name .cxx -o -name out \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -prune -print 2>/dev/null | sort
)
if (( ${#ARTIFACTS[@]} == 0 )); then
  note "none"
else
  for a in "${ARTIFACTS[@]}"; do
    if [[ -z "$(ls -A "$a" 2>/dev/null)" ]]; then
      continue                                     # empty: nothing to reclaim
    elif [[ -f "$a/CACHEDIR.TAG" || -f "$a/.rustc_info.json" \
         || -d "$a/debug" || -d "$a/release" || -d "$a/intermediates" \
         || -d "$a/outputs" || -d "$a/classes" || -d "$a/reports" \
         || -f "$a/x-ui" \
         || "$(basename "$a")" =~ ^(\.gradle|\.kotlin|\.cxx|dist|out)$ ]]; then
      drop "$a"
    else
      note "unrecognised, kept: ${a/#$HOME/\~}"
    fi
  done
fi

# ── 4. Junk files and stale binaries ─────────────────────────────────────────
step "OS / editor junk and stale temp files"
mapfile -t JUNK < <(
  find "$DEV_DIR" "$HOME/Downloads" -maxdepth 6 -type f \
    \( -name '*Zone.Identifier' -o -name '.DS_Store' -o -name 'Thumbs.db' \
       -o -name '*.swp' -o -name '*.swo' -o -name '*.orig' -o -name '*.rej' \) \
    -not -path '*/.git/*' 2>/dev/null | head -500
)
if (( ${#JUNK[@]} == 0 )); then note "none"; else
  for f in "${JUNK[@]}"; do drop "$f"; done
fi
drop "$HOME/.local/share/Trash"

# Old binary backups in ~/.local/bin (e.g. agy.*.old)
mapfile -t OLD_BINS < <(find "$HOME/.local/bin" -maxdepth 1 -type f \( -name '*.old' -o -name '*.bak*' \) 2>/dev/null)
for f in "${OLD_BINS[@]}"; do drop "$f"; done

mapfile -t OLDTMP < <(find /tmp -maxdepth 1 -mtime "+$TMP_AGE_DAYS" -user "$RUN_USER" 2>/dev/null)
if (( ${#OLDTMP[@]} == 0 )); then note "/tmp: nothing older than ${TMP_AGE_DAYS}d"; else
  for f in "${OLDTMP[@]}"; do drop "$f"; done
fi

# ── 5. AI Agent sessions and memory (STRICTLY PRESERVED) ─────────────────────
step "AI agent sessions and memory"
note "ALL agent sessions, history and persistent memory are strictly preserved:"
note "  ~/.claude (projects, sessions, tasks, memory)"
note "  ~/.codex (sessions, memories, archived_sessions, rules, logs_2.sqlite)"
note "  ~/.gemini (conversations, brain, cli)"
note "  ~/.copilot (sessions, transcripts, context, memory, logs, configuration)"
note "  ~/.local/share/opencode"
note "~/.cache/copilot is not in this list: it holds no session or memory data, only"
note "  the payload the CLI unpacks out of its own binary. Cleaned above."

# ── 6. Local Postgres test cluster (--purge-pgtest) ──────────────────────────
step "Local Postgres test cluster (--purge-pgtest)"
if [[ "$PURGE_PGTEST" -eq 1 ]]; then
  if pgrep -f "$HOME/.local/pgtest" >/dev/null 2>&1; then
    note "a postgres process is running out of it — stop it first, skipping"
  else
    drop "$HOME/.local/pgtest"
  fi
else
  note "skipped (pass --purge-pgtest) — this is a database directory, not a cache"
fi

# ── 7. --deep: installed dependency trees ────────────────────────────────────
step "node_modules under ${DEV_DIR/#$HOME/\~} (--deep)"
if [[ "$DEEP" -eq 1 ]]; then
  mapfile -t NM < <(find "$DEV_DIR" -maxdepth 5 -type d -name node_modules -prune -print 2>/dev/null)
  if (( ${#NM[@]} == 0 )); then note "none"; else
    note "npm install brings these back — needs network"
    for d in "${NM[@]}"; do drop "$d"; done
  fi
else
  note "skipped (pass --deep)"
fi

# ── 8. --system: apt, journal, rotated logs, system binaries ─────────────────
step "System packages, logs and architecture stubs (--system, needs sudo)"
if [[ "$SYSTEM" -eq 1 ]]; then
  SUDO="sudo"; [[ "$EUID" -eq 0 ]] && SUDO=""
  if [[ -n "$SUDO" ]] && ! sudo -n true 2>/dev/null && [[ ! -t 0 ]]; then
    note "needs sudo and there is no terminal to ask on — skipping"
  else
    note "apt cache: $(du -sh /var/cache/apt/archives 2>/dev/null | cut -f1)"
    if [[ "$FORCE" -eq 1 ]]; then
      $SUDO apt-get clean
      DEBIAN_FRONTEND=noninteractive $SUDO apt-get autoremove --purge -y
      # journalctl reports what it freed on stderr in its own format; measuring
      # the directory is both simpler and in the same units as everything else.
      JOURNAL_B0="$($SUDO du -sB1 /var/log/journal 2>/dev/null | cut -f1)"
      $SUDO journalctl --vacuum-size="$JOURNAL_KEEP"
      JOURNAL_B1="$($SUDO du -sB1 /var/log/journal 2>/dev/null | cut -f1)"
      TOTAL=$(( TOTAL + ${JOURNAL_B0:-0} - ${JOURNAL_B1:-0} ))
    else
      note "[dry] apt-get clean"
      $SUDO apt-get -s autoremove --purge 2>/dev/null | grep -E '^Remv' | sed 's/^/   [dry] /' \
        || note "nothing to autoremove"
      note "[dry] journalctl --vacuum-size=$JOURNAL_KEEP  (now: $(journalctl --disk-usage 2>/dev/null | sed 's/^.*take up //'))"
    fi
    # Rotated copies only — the live file per service stays.
    mapfile -t OLD_LOGS < <($SUDO find /var/log -regextype posix-extended -type f \
      \( -name '*.gz' -o -name '*.old' -o -regex '.*\\.[0-9]+' -o -regex '.*-[0-9]{8}' \) 2>/dev/null)
    if (( ${#OLD_LOGS[@]} == 0 )); then note "no rotated logs"; else
      for f in "${OLD_LOGS[@]}"; do
        printf '   %s%8s%s  %s\n' "$c_ylw" "$(human "$($SUDO du -sB1 "$f" 2>/dev/null | cut -f1)")" "$c_rst" "$f"
        [[ "$FORCE" -eq 1 ]] && $SUDO rm -f -- "$f"
      done
    fi

    # The downloaded package index
    # Hand-rolled rather than drop(): lock and partial have to survive inside the
    # directory. That means the running total has to be fed here by hand too, or
    # the summary under-reports the run by however big the index is.
    if [[ -d /var/lib/apt/lists ]]; then
      APT_LISTS_B="$($SUDO du -sB1 /var/lib/apt/lists 2>/dev/null | cut -f1)"
      TOTAL=$(( TOTAL + ${APT_LISTS_B:-0} ))
      printf '   %s%8s%s  %s\n' "$c_ylw" "$(human "${APT_LISTS_B:-0}")" "$c_rst" \
        "/var/lib/apt/lists"
      if [[ "$FORCE" -eq 1 ]]; then
        $SUDO find /var/lib/apt/lists -mindepth 1 -maxdepth 1 -not -name lock -not -name partial -delete
      fi
    fi

    # Incompatible platform binaries downloaded by global npm
    prune_foreign_platform_binaries "global npm" /usr/local/lib/node_modules
    drop "/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
  fi
else
  note "skipped (pass --system)"
fi

# ── 9. root's own home ───────────────────────────────────────────────────────
step "root's home (--system)"
if [[ "$SYSTEM" -eq 1 && "$EUID" -eq 0 && "$HOME" != "/root" ]]; then
  clean_home_caches "/root" "root"
  # GUI editor runtimes in /root are not needed
  drop "/root/.zed_server"
  drop "/root/.local/share/zed"
elif [[ "$SYSTEM" -eq 1 && "$EUID" -ne 0 ]]; then
  note "re-run with sudo to include it (sudo $0 --force --all)"
else
  note "skipped (pass --system)"
fi

# ── 10. --purge-bak: previous binaries and stale backups ─────────────────────
step "Rollback copies and stale backups (--purge-bak)"
if [[ "$PURGE_BAK" -eq 1 ]]; then
  mapfile -t BAKS < <(find /opt/ownlocator -maxdepth 1 -name '*.bak*' -type f 2>/dev/null)
  if (( ${#BAKS[@]} == 0 )); then note "no /opt/ownlocator/*.bak*"; else
    for f in "${BAKS[@]}"; do drop "$f"; done
  fi
  drop "/var/lib/ownlocator/media-wsl-backup"
else
  note "skipped (pass --purge-bak)"
fi

# ── 11. Reported, never removed ──────────────────────────────────────────────
step "Left alone on purpose"
note "AI agent sessions, memories and history are preserved."
note "working source code and project documentation are preserved."

# ~/.cache is disposable by specification, and applications ignore that. These
# were found by looking rather than by assuming, and are deliberately absent
# from every list above — the reason `rm -rf ~/.cache/*` is not what this
# script does. Named here so the next reader knows the difference is intended.
CACHE_STATE=(
  "$HOME/.cache/google-vscode-extension/auth|live Google OAuth + ADC refresh tokens: deleting these logs you out"
  "$HOME/.cache/Microsoft/DeveloperTools/deviceid|stable device id, regenerates but changes identity"
  "$HOME/.cache/powershell/telemetry.uuid|stable telemetry id, same"
)
CACHE_STATE_SEEN=0
for entry in "${CACHE_STATE[@]}"; do
  [[ -e "${entry%%|*}" ]] || continue
  (( CACHE_STATE_SEEN )) || note "under ~/.cache, state rather than cache, never removed:"
  CACHE_STATE_SEEN=1
  path="${entry%%|*}"
  note "  ${path/#$HOME/\~}: ${entry#*|}"
done
if [[ "$(uname -r)" == *microsoft-standard-WSL2* ]]; then
  mapfile -t HDRS < <(dpkg-query -Wf '${Package}\n' 'linux-headers-*' 2>/dev/null | sed '/^$/d')
  if (( ${#HDRS[@]} > 0 )); then
    HDR_KB="$(dpkg-query -Wf '${Installed-Size}\n' 'linux-headers-*' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    note "kernel headers (~$(human $(( HDR_KB * 1024 )))): this WSL boots Windows' own kernel, so nothing here can use them —"
    DKMS_BUILT="$(dkms status 2>/dev/null | grep -c ': installed' || true)"
    if (( DKMS_BUILT > 0 )); then
      note "  …except DKMS, which has $DKMS_BUILT module builds against them (e.g. AmneziaWG VPN)."
      note "  They cannot load under WSL either, but if this rootfs ever boots real hardware they are your VPN. Kept."
    elif [[ "$EUID" -eq 0 ]]; then
      note "  and DKMS has nothing built. Remove by hand if you are sure: apt-get purge 'linux-headers-*'"
    else
      note "  whether DKMS builds against them needs root to tell — re-run under sudo to find out."
    fi
  fi
fi
note "big hand-installed toolchains (llvm, mingw-w64, openjdk…) are never touched —"
note "  review them yourself with: apt-mark showmanual | xargs dpkg-query -Wf '\${Installed-Size}\t\${Package}\n' | sort -rn | head"
[[ -d /usr/local/x-ui ]] && note "/usr/local/x-ui is an installed program, not build output — kept"

# ── done ─────────────────────────────────────────────────────────────────────
step "Result"
if [[ "$FORCE" -eq 1 ]]; then
  AFTER="$(avail_bytes)"
  df -h "$HOME"
  printf '\n%sReclaimed: %s%s (accounted: %s)\n' \
    "$c_grn" "$(human $(( AFTER - BEFORE )))" "$c_rst" "$(human "$TOTAL")"
else
  printf '\n%sWould free about %s%s — re-run with --force to apply.\n' \
    "$c_ylw" "$(human "$TOTAL")" "$c_rst"
  [[ "$DEEP"   -eq 1 ]] || note "add --deep for package caches, npx, playwright and gradle transforms"
  [[ "$SYSTEM" -eq 1 ]] || note "add --system for apt and the journal"
fi

VHDX_PATH="$(detect_vhdx_path)"

cat <<EOF

   Space freed inside WSL does not shrink the virtual disk on Windows — the
   .vhdx only ever grows.

   Detected VHDX location on Windows:
       $VHDX_PATH

   To compact it and reclaim physical disk space on Windows, run from an ADMIN PowerShell:

       wsl --shutdown
       Optimize-VHD -Path "$VHDX_PATH" -Mode Full

   Without Hyper-V (Windows Home), diskpart does the same:

       diskpart
       select vdisk file="$VHDX_PATH"
       attach vdisk readonly
       compact vdisk
       detach vdisk
EOF
