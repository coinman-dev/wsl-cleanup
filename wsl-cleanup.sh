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

for arg in "$@"; do
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
    *)
      echo "unknown option: $arg (try --help)" >&2
      exit 2 ;;
  esac
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
drop() {
  local p="$1" b
  [[ -e "$p" ]] || return 0
  b="$(size_of "$p")"
  TOTAL=$(( TOTAL + b ))
  printf '   %s%8s%s  %s\n' "$c_ylw" "$(human "$b")" "$c_rst" "${p/#$HOME/\~}"
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
  find "$h/.local/share/zed/logs" -type f -name '*.log.*' 2>/dev/null | while read -r f; do drop "$f"; done

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
  step "Compiler / tool caches ($who)"
  drop "$h/.cache/go-build"
  drop "$h/.cache/staticcheck"
  drop "$h/.cache/gopls"
  drop "$h/.cache/goimports"
  drop "$h/.cache/typescript"
  drop "$h/.cache/node-gyp"
  drop "$h/.cache/cloud-code"
  drop "$h/.cache/claude-cli-nodejs"
  drop "$h/.cache/opencode"
  drop "$h/.config/JetBrains/analyzer/workspaces"
  drop "$h/.codex/.tmp"
  drop "$h/.codex/plugins/cache"
  drop "$h/.gemini/tmp"
  drop "$h/.gradle/caches/build-cache-1"
  drop "$h/.gradle/daemon"
  drop "$h/.gradle/kotlin-profile"

  clean_copilot_cache "$h" "$who"

  # Package caches and heavy dependencies. Waiting for --deep because they re-download.
  [[ "$DEEP" -eq 1 ]] || return 0
  step "Package caches ($who, --deep)"
  local m tr
  for m in "$h"/go/pkg/mod/*/; do
    m="${m%/}"
    [[ "$(basename "$m")" == "golang.org" ]] && continue   # toolchains: handled above
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

# ── preflight ────────────────────────────────────────────────────────────────
if [[ "$FORCE" -eq 0 ]]; then
  printf '%sDRY RUN%s — nothing will be deleted. Re-run with --force to apply.\n' "$c_ylw" "$c_rst"
fi
if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  note "running under sudo — cleaning ${RUN_USER}'s home ($HOME); --system needs no second password"
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
      $SUDO journalctl --vacuum-size="$JOURNAL_KEEP"
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
    if [[ -d /var/lib/apt/lists ]]; then
      printf '   %s%8s%s  %s\n' "$c_ylw" \
        "$(human "$($SUDO du -sB1 /var/lib/apt/lists 2>/dev/null | cut -f1)")" "$c_rst" \
        "/var/lib/apt/lists"
      if [[ "$FORCE" -eq 1 ]]; then
        $SUDO find /var/lib/apt/lists -mindepth 1 -maxdepth 1 -not -name lock -not -name partial -delete
      fi
    fi

    # Incompatible platform binaries downloaded by global npm
    drop "/usr/local/lib/node_modules/@anthropic-ai/claude-code/node_modules/@anthropic-ai/claude-code-linux-x64-musl"
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
