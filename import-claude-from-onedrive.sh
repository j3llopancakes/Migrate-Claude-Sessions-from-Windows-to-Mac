#!/usr/bin/env bash
# =============================================================================
# import-claude-from-onedrive.sh
# Step 2 of 2 (run on the Mac): restores the data exported by
# Export-ClaudeToOneDrive.ps1 from the current user's OneDrive.
#
#   - Cowork sessions      -> restored into the Claude Desktop app's sidebar
#   - Claude Code sessions -> re-filed under the matching Mac folders, so they show in
#                             `claude --resume`, the VS Code extension and the Desktop
#                             app's Code tab. Missing folders are created.
#   - Claude Code config   -> merged into ~/.claude (never overwrites existing files)
#   - MCP servers / Desktop config -> reported for manual re-entry (secrets redacted)
#
# The script finds every Claude_Migration* backup in OneDrive (one per PC) and imports
# each one. It waits for OneDrive to deliver them (restarting OneDrive if it stalls),
# verifies every file, and runs only the parts each PC export contained.
#
# Usage:
#   bash import-claude-from-onedrive.sh [--dry-run] [--yes] [--onedrive PATH] [--source DIR]
#        [--map 'WINPATH=MACPATH']... [--backup-name NAME] [--wait SECONDS] [--cleanup]
#
#   --dry-run      Verify the backup and show the plan. Changes nothing.
#   --yes          Don't ask before quitting Claude.
#   --onedrive     OneDrive root (auto-detected), e.g. ~/Library/CloudStorage/OneDrive-Contoso
#   --source       Use a backup folder somewhere else instead of OneDrive, e.g. one
#                  downloaded from the OneDrive website and unzipped.
#   --map          Put a PC folder somewhere specific on this Mac (repeatable), e.g.
#                  --map 'D:\repos=~/code'
#   --backup-name  Import only this backup folder (default: every Claude_Migration* folder).
#   --wait         Max seconds to wait for OneDrive before showing the website-download
#                  steps (default: 180).
#   --cleanup      Delete the backup's credential files afterwards.
# =============================================================================
set -euo pipefail

ORIG_ARGS=("$@")
BACKUP_NAME=""
ONEDRIVE=""
SOURCE=""
DRY_RUN=0
ASSUME_YES=0
CLEANUP=0
WAIT_SECS=180
MAPS=()

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --onedrive)    ONEDRIVE="${2:?--onedrive needs a path}"; shift 2 ;;
    --source)      SOURCE="${2:?--source needs a path}"; shift 2 ;;
    --map)         [[ "${2:-}" == *=* ]] || { echo "--map needs 'WINPATH=MACPATH'"; exit 1; }; MAPS+=("$2"); shift 2 ;;
    --backup-name) BACKUP_NAME="${2:?--backup-name needs a value}"; shift 2 ;;
    --wait)        WAIT_SECS="${2:?--wait needs seconds}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --cleanup)     CLEANUP=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[OK]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[WARN]\033[0m %s\n' "$*"; }
fail() { printf '\n    \033[31m[FAIL]\033[0m %s\n' "$*"; exit 1; }
confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local a; read -r -p "    $1 [Y/n] " a </dev/tty || return 0
  [[ ! "$a" =~ ^[Nn] ]]
}
json_get() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }   # plutil ships with macOS
lower()    { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
encode()   { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }               # Claude Code's project folder naming
expand()   { case "$1" in "~") printf '%s' "$HOME" ;; "~/"*) printf '%s' "$HOME/${1:2}" ;; *) printf '%s' "$1" ;; esac; }
now()      { date +%s; }

APP_SESS="$HOME/Library/Application Support/Claude/local-agent-mode-sessions"
CODE_PROJECTS="$HOME/.claude/projects"
GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-import.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

restart_onedrive() {
  if [ ! -d "/Applications/OneDrive.app" ] && [ ! -d "$HOME/Applications/OneDrive.app" ]; then
    warn "OneDrive app not found in /Applications; cannot restart it."; return 0
  fi
  printf '\n    Restarting OneDrive to force a sync pass...\n'
  osascript -e 'quit app "OneDrive"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -x OneDrive >/dev/null || break; sleep 1; done
  open -a OneDrive >/dev/null 2>&1 || warn "Could not start OneDrive. Open it manually."
  sleep 15
}

web_fallback() {
  local n="${BACKUP_NAME:-Claude_Migration_<PC name>}"
  fail "OneDrive on this Mac hasn't delivered the backup.
           1. Check OneDrive's Finder integration is on: System Settings > General >
              Login Items & Extensions > File Providers > OneDrive. Restart the Mac if you just enabled it.
           2. On the PC, check the OneDrive icon shows 'Up to date'.
           3. Or download it from the OneDrive website: open OneDrive in a browser, press
              Cmd+Shift+R, select '$n', click Download, then double-click the zip.
              Re-run this script with:  --source ~/Downloads/$n"
}

# True if OneDrive folder $1 contains the requested backup (or any Claude_Migration* backup).
has_backup() {
  if [ -n "$BACKUP_NAME" ]; then [ -d "$1/$BACKUP_NAME" ]; return; fi
  local d; for d in "$1"/Claude_Migration*; do [ -d "$d" ] && return 0; done; return 1
}

# Names of Claude_Migration* folders in $ONEDRIVE whose manifest has arrived.
list_backups() {
  local d; for d in "$ONEDRIVE"/Claude_Migration*; do
    [ -d "$d" ] && cat "$d/manifest.json" >/dev/null 2>&1 && basename "$d"
  done; return 0
}

check_finder_integration() {
  # OneDrive syncs into Finder through a macOS File Provider extension. If it's switched
  # off, Finder shows a frozen copy and nothing new ever arrives.
  local fp
  fp=$(pluginkit -m -p com.apple.fileprovider-nonui 2>/dev/null | grep -i onedrive || true)
  if printf '%s\n' "$fp" | grep -q '^ *-'; then
    warn "OneDrive's Finder integration is turned OFF, so new files can't reach this Mac."
    echo  "           Turn it on: System Settings > General > Login Items & Extensions >"
    echo  "           File Providers (or Extensions > File Providers) > enable OneDrive, then restart the Mac."
    confirm "Continue waiting anyway?" || exit 1
  fi
}

# -----------------------------------------------------------------------------
step "Locating the backup"
if [ -z "$ONEDRIVE" ] && [ -z "$SOURCE" ]; then
  all=(); with=(); work=()
  for d in "$HOME"/Library/CloudStorage/OneDrive-*; do
    [ -d "$d" ] || continue
    all+=("$d")
    has_backup "$d" && with+=("$d")
    case "$(basename "$d")" in OneDrive-Personal) ;; *) work+=("$d") ;; esac
  done
  if   [ ${#with[@]} -eq 1 ]; then ONEDRIVE="${with[0]}"
  elif [ ${#with[@]} -gt 1 ]; then fail "Several OneDrive accounts contain Claude backups: ${with[*]}. Pass --onedrive PATH."
  elif [ ${#all[@]}  -eq 1 ]; then ONEDRIVE="${all[0]}"
  elif [ ${#work[@]} -eq 1 ]; then ONEDRIVE="${work[0]}"
  elif [ ${#all[@]}  -eq 0 ]; then fail "OneDrive isn't set up on this Mac. Install OneDrive and sign in with the same account as the PC, or use --source."
  else fail "Several OneDrive accounts found: ${all[*]}. Pass --onedrive PATH."
  fi
elif [ -z "$ONEDRIVE" ]; then
  # --source given: still find OneDrive so OneDrive-hosted projects map to the right place.
  for d in "$HOME"/Library/CloudStorage/OneDrive-*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in OneDrive-Personal) [ -z "$ONEDRIVE" ] && ONEDRIVE="$d" ;; *) ONEDRIVE="$d" ;; esac
  done
fi
ONEDRIVE="$(expand "${ONEDRIVE%/}")"

if [ -n "$SOURCE" ]; then
  SRC="$(expand "${SOURCE%/}")"
  if [ ! -f "$SRC/manifest.json" ]; then   # web downloads may unzip one level deeper
    inner=$(find "$SRC" -maxdepth 3 -name manifest.json -print 2>/dev/null | head -1 || true)
    [ -n "$inner" ] && SRC="$(dirname "$inner")"
  fi
  [ -f "$SRC/manifest.json" ] || fail "No manifest.json found in $SRC. Point --source at the unzipped backup folder."
  ok "Backup (local copy): $SRC"
else
  ok "OneDrive: $ONEDRIVE"
  check_finder_integration
fi

# -----------------------------------------------------------------------------
# No --backup-name: find every Claude_Migration* backup (one per PC) and import each.
if [ -z "$SOURCE" ] && [ -z "$BACKUP_NAME" ]; then
  step "Looking for Claude backups in OneDrive"
  start=$(now); restarts=0; last_restart=$start; names=()
  while true; do
    ls "$ONEDRIVE" >/dev/null 2>&1 || true                  # makes OneDrive refresh the listing
    names=()
    while IFS= read -r n; do [ -n "$n" ] && names+=("$n"); done < <(list_backups)
    [ ${#names[@]} -gt 0 ] && break
    [ $(( $(now) - start )) -ge "$WAIT_SECS" ] && { printf '\n'; web_fallback; }
    if [ "$restarts" -eq 0 ] || { [ $(( $(now) - last_restart )) -ge 120 ] && [ "$restarts" -lt 3 ]; }; then
      restart_onedrive; restarts=$((restarts + 1)); last_restart=$(now)
    fi
    printf '\r    waiting for a Claude_Migration backup folder to appear (%ss elapsed)          ' "$(( $(now) - start ))"
    sleep 10
  done
  if [ ${#names[@]} -eq 1 ]; then
    BACKUP_NAME="${names[0]}"; ok "Found backup: $BACKUP_NAME"
  else
    ok "Found ${#names[@]} backups: ${names[*]}"
    rc=0
    for n in "${names[@]}"; do
      printf '\n\033[35m############ Importing %s ############\033[0m\n' "$n"
      bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} --onedrive "$ONEDRIVE" --backup-name "$n" || rc=1
    done
    if [ "$DRY_RUN" = 1 ]; then done_word="checked (dry run, nothing changed)"; else done_word="imported"; fi
    [ "$rc" = 0 ] && printf '\n\033[32mAll %s backups %s.\033[0m\n' "${#names[@]}" "$done_word" \
                  || printf '\n\033[31mOne or more backups did not complete; see the messages above.\033[0m\n'
    exit "$rc"
  fi
fi
[ -z "$SOURCE" ] && SRC="$ONEDRIVE/$BACKUP_NAME"

# -----------------------------------------------------------------------------
# Wait for OneDrive to deliver every file listed by the PC, restarting it if it stalls.
if [ -z "$SOURCE" ]; then
  if [ "$WAIT_SECS" -ge 60 ]; then limit="$((WAIT_SECS / 60)) min"; else limit="${WAIT_SECS}s"; fi
  step "Syncing the backup from OneDrive (waits up to $limit)"
  start=$(now); last_change=$start; last_missing=-2; restarts=0
  [ -f "$SRC/manifest.json" ] || { restart_onedrive; restarts=1; }
  while true; do
    ls "$ONEDRIVE" >/dev/null 2>&1 || true                  # makes OneDrive refresh the listing
    missing=-1
    if [ -d "$SRC" ] && cat "$SRC/manifest.json" >/dev/null 2>&1 && cat "$SRC/manifest-files.txt" >/dev/null 2>&1; then
      missing=0
      while IFS= read -r rel || [ -n "$rel" ]; do
        rel="${rel%$'\r'}"; [ -z "$rel" ] && continue
        [ -e "$SRC/$rel" ] || missing=$((missing + 1))
      done < "$SRC/manifest-files.txt"
      if [ "$missing" -eq 0 ]; then
        # Everything is listed; now force each file to download.
        while IFS= read -r rel || [ -n "$rel" ]; do
          rel="${rel%$'\r'}"; [ -z "$rel" ] && continue
          cat "$SRC/$rel" >/dev/null 2>&1 || missing=$((missing + 1))
        done < "$SRC/manifest-files.txt"
        [ "$missing" -eq 0 ] && { printf '\n'; ok "All $(grep -c . "$SRC/manifest-files.txt") backup files downloaded"; break; }
      fi
    fi
    [ "$missing" != "$last_missing" ] && { last_missing=$missing; last_change=$(now); }
    [ $(( $(now) - start )) -ge "$WAIT_SECS" ] && { printf '\n'; web_fallback; }
    if [ $(( $(now) - last_change )) -ge 120 ] && [ "$restarts" -lt 3 ]; then
      restart_onedrive; restarts=$((restarts + 1)); last_change=$(now)
    fi
    if [ "$missing" -lt 0 ]; then status="waiting for the backup folder to appear"
    else status="$missing file(s) still arriving"; fi
    printf '\r    %s (%ss elapsed)          ' "$status" "$(( $(now) - start ))"
    sleep 10
  done
fi

MANIFEST="$SRC/manifest.json"
HAS_COWORK=$(json_get "$MANIFEST" hasCowork)
HAS_CODE=$(json_get "$MANIFEST" hasClaudeCode)
OD_WIN=$(json_get "$MANIFEST" oneDriveRootWindows)
echo "    Exported from : $(json_get "$MANIFEST" sourceComputer) ($(json_get "$MANIFEST" installType) install), $(json_get "$MANIFEST" createdAt)"
echo "    Cowork        : ${HAS_COWORK:-false}"
echo "    Claude Code   : ${HAS_CODE:-false}"

step "Verifying the backup against the PC's file list"
missing=0
while IFS= read -r rel || [ -n "$rel" ]; do
  rel="${rel%$'\r'}"; [ -z "$rel" ] && continue
  if [ ! -e "$SRC/$rel" ] || ! cat "$SRC/$rel" >/dev/null 2>&1; then
    missing=$((missing + 1)); [ "$missing" -le 10 ] && echo "      missing: $rel"
  fi
done < "$SRC/manifest-files.txt"
[ "$missing" -gt 0 ] && { [ -n "$SOURCE" ] && fail "$missing file(s) missing from $SRC. Re-download the backup and unzip it again."; web_fallback; }
ok "All $(grep -c . "$SRC/manifest-files.txt") files present"

# Unpack a session archive into WORK_DIR/$2 and check it holds the expected number of conversations.
unpack() {   # $1 = archive (relative), $2 = name, $3 = expected .jsonl count
  local dir="$WORK_DIR/$2" have
  mkdir -p "$dir"
  tar -xzf "$SRC/$1" -C "$dir" 2>/dev/null || fail "Could not unpack $1 (corrupted or incomplete). Re-run the export on the PC."
  have=$(find "$dir" -type f -name '*.jsonl' | wc -l | tr -d ' ')
  [ -n "$3" ] && [ "$have" -lt "$3" ] && fail "$1 has $have of $3 conversation files. Re-run the export on the PC."
  ok "Unpacked $1: $have conversation file(s), matches the PC"
}

# -----------------------------------------------------------------------------
# Plan: Cowork sessions
COWORK_SRC="$SRC/cowork/local-agent-mode-sessions"
pairs=(); new_sessions=(); account_notes=()
if [ "$HAS_COWORK" = "true" ]; then
  step "Cowork sessions"
  if [ ! -d "/Applications/Claude.app" ] && [ ! -d "$HOME/Applications/Claude.app" ]; then
    fail "Claude Desktop isn't installed. Install it from claude.ai/download, sign in, then re-run."
  fi
  arch=$(json_get "$MANIFEST" coworkArchive)
  if [ -n "$arch" ]; then unpack "$arch" cowork "$(json_get "$MANIFEST" coworkTranscriptCount)"; COWORK_SRC="$WORK_DIR/cowork"; fi
  mac_accounts=$(ls "$APP_SESS" 2>/dev/null | grep -E "$GUID_RE" || true)
  for acct_dir in "$COWORK_SRC"/*/; do
    acct=$(basename "$acct_dir"); [[ "$acct" =~ $GUID_RE ]] || continue
    for org_dir in "$acct_dir"*/; do
      org=$(basename "$org_dir"); [[ "$org" =~ $GUID_RE ]] || continue
      if [ ! -d "$APP_SESS/$acct/$org" ]; then
        if [ -z "$mac_accounts" ]; then
          account_notes+=("Cowork hasn't been opened on this Mac yet; its session folder will be created.")
        else
          account_notes+=("These Cowork sessions belong to Claude account $acct (org $org), which isn't the account signed in on this Mac. They will appear after you sign in to that account in Claude Desktop.")
        fi
      fi
      pairs+=("$acct/$org")
      for s in "$org_dir"local_*.json; do
        [ -e "$s" ] || continue
        [ -e "$APP_SESS/$acct/$org/$(basename "$s")" ] || new_sessions+=("$s")
      done
    done
  done
  for n in ${account_notes[@]+"${account_notes[@]}"}; do warn "$n"; done
  ok "${#new_sessions[@]} new Cowork session(s):"
  for s in ${new_sessions[@]+"${new_sessions[@]}"}; do echo "           - $(json_get "$s" title)"; done
fi

# -----------------------------------------------------------------------------
# Plan: Claude Code sessions. Every Windows folder gets a predictable Mac folder:
#   1. --map rules            2. inside OneDrive -> same place in the Mac's OneDrive
#   3. C:\Users\<name>\x -> ~/x 4. other drives: D:\x -> ~/D-drive/x ; \\srv\share\x -> ~/network/srv/share/x
win_to_mac() {
  local w="$1" lw m from to rest
  lw=$(lower "$w")
  for m in ${MAPS[@]+"${MAPS[@]}"}; do
    from="${m%%=*}"; from="${from%\\}"; to="$(expand "${m#*=}")"; to="${to%/}"
    case "$lw" in "$(lower "$from")"|"$(lower "$from")"\\*)
      rest="${w:${#from}}"; printf '%s%s' "$to" "$(printf '%s' "$rest" | tr '\\' '/')"; return ;; esac
  done
  if [ -n "$OD_WIN" ] && [ -n "$ONEDRIVE" ]; then
    case "$lw" in "$(lower "$OD_WIN")"|"$(lower "$OD_WIN")"\\*)
      rest="${w:${#OD_WIN}}"; printf '%s%s' "$ONEDRIVE" "$(printf '%s' "$rest" | tr '\\' '/')"; return ;; esac
  fi
  if [[ "$w" =~ ^[A-Za-z]:\\[Uu]sers\\[^\\]+(.*)$ ]]; then
    printf '%s%s' "$HOME" "$(printf '%s' "${BASH_REMATCH[1]}" | tr '\\' '/')"; return
  fi
  if [[ "$w" =~ ^([A-Za-z]):(.*)$ ]]; then
    printf '%s/%s-drive%s' "$HOME" "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "${BASH_REMATCH[2]}" | tr '\\' '/')"; return
  fi
  printf '%s/network/%s' "$HOME" "$(printf '%s' "${w#\\\\}" | tr '\\' '/')"
}

P_FOLDER=(); P_WIN=(); P_MAC=()
CODE_PROJ_SRC="$SRC/code/projects"
INDEX="$SRC/code/projects-index.tsv"
if [ "$HAS_CODE" = "true" ] && [ -f "$INDEX" ]; then
  step "Claude Code sessions"
  arch=$(json_get "$MANIFEST" codeArchive)
  if [ -n "$arch" ]; then unpack "$arch" code "$(json_get "$MANIFEST" codeTranscriptCount)"; CODE_PROJ_SRC="$WORK_DIR/code"; fi
  while IFS=$'\t' read -r folder win count last || [ -n "$folder" ]; do
    folder="${folder%$'\r'}"; [ -z "$folder" ] && continue
    [ -d "$CODE_PROJ_SRC/$folder" ] || fail "Sessions for $win are missing from the backup. Re-run the export on the PC."
    mac=$(win_to_mac "$win")
    P_FOLDER+=("$folder"); P_WIN+=("$win"); P_MAC+=("$mac")
    note=""; [ -d "$mac" ] || note="  (folder will be created)"
    printf '    %3s session(s)  %s\n                     -> %s%s\n' "$count" "$win" "$mac" "$note"
  done < "$INDEX"
fi

if [ "$DRY_RUN" = 1 ]; then
  printf '\n\033[32mDry run complete. Nothing was changed.\033[0m Re-run without --dry-run to import.\n'
  exit 0
fi

# -----------------------------------------------------------------------------
BACKUP_DIR="$HOME/Desktop/claude-migration-backup-$(date +%Y%m%d-%H%M%S)"

if [ ${#new_sessions[@]} -gt 0 ]; then
  step "Importing Cowork sessions"
  if pgrep -x "Claude" >/dev/null; then
    confirm "Claude Desktop must quit to import sessions (it reopens afterwards). Quit now?" || fail "Aborted. Nothing was changed."
    osascript -e 'quit app "Claude"' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pgrep -x "Claude" >/dev/null || break; sleep 1; done
    pgrep -x "Claude" >/dev/null && fail "Claude did not quit. Quit it manually (Cmd+Q) and re-run."
  fi
  ok "Claude is closed"
  if [ -d "$APP_SESS" ]; then
    mkdir -p "$BACKUP_DIR"; ditto "$APP_SESS" "$BACKUP_DIR/local-agent-mode-sessions"
    ok "Backed up this Mac's existing sessions to $BACKUP_DIR"
  fi
  mkdir -p "$APP_SESS"
  before=$(find "$APP_SESS" -maxdepth 3 -name 'local_*.json' | wc -l | tr -d ' ')
  for p in "${pairs[@]}"; do
    mkdir -p "$APP_SESS/$p"
    # Session metadata, legacy local_*/ folders and 8-character workspaces. Never overwrites.
    rsync -a --ignore-existing \
      --include='local_*.json' --include='local_*/***' --include='????????/***' \
      --exclude='*' "$COWORK_SRC/$p/" "$APP_SESS/$p/"
  done
  after=$(find "$APP_SESS" -maxdepth 3 -name 'local_*.json' | wc -l | tr -d ' ')
  ok "Cowork sessions on this Mac: $before -> $after"
elif [ "$HAS_COWORK" = "true" ]; then
  step "Importing Cowork sessions"
  ok "All Cowork sessions from the PC are already on this Mac"
fi

# -----------------------------------------------------------------------------
CODE_SRC="$SRC/code/dot-claude"
if [ "$HAS_CODE" = "true" ] && [ -d "$CODE_SRC" ]; then
  step "Merging Claude Code config into ~/.claude"
  mkdir -p "$HOME/.claude"
  for item in CLAUDE.md keybindings.json agents commands skills plans hooks output-styles; do
    [ -e "$CODE_SRC/$item" ] || continue
    rsync -a --ignore-existing "$CODE_SRC/$item" "$HOME/.claude/"
    ok "$item"
  done
  settings_label="~/.claude/settings.json"
  if [ -f "$CODE_SRC/settings.json" ]; then
    if [ -f "$HOME/.claude/settings.json" ] && ! cmp -s "$CODE_SRC/settings.json" "$HOME/.claude/settings.json"; then
      cp "$CODE_SRC/settings.json" "$HOME/.claude/settings.from-pc.json"
      settings_label="~/.claude/settings.from-pc.json"
      warn "settings.json already exists here. PC version saved as ~/.claude/settings.from-pc.json for you to merge."
    else
      cp -n "$CODE_SRC/settings.json" "$HOME/.claude/settings.json" 2>/dev/null || true
      ok "settings.json"
    fi
  fi
  # Only settings and hooks run commands/paths; Windows references in docs, plans or a
  # skill's own PowerShell scripts are harmless, so they aren't flagged.
  check=(); [ -f "$CODE_SRC/settings.json" ] && check+=("$CODE_SRC/settings.json"); [ -d "$CODE_SRC/hooks" ] && check+=("$CODE_SRC/hooks")
  winisms=""
  if [ ${#check[@]} -gt 0 ]; then
    winisms=$(grep -rnIE '[A-Za-z]:\\\\|powershell|pwsh|\.ps1"|\.cmd"|\.exe"' "${check[@]}" 2>/dev/null \
              | sed -e "s|^$CODE_SRC/settings.json|$settings_label|" -e "s|^$CODE_SRC/|~/.claude/|" | head -10 || true)
  fi
  if [ -n "$winisms" ]; then
    warn "Windows paths or commands in Claude Code settings; update these for macOS:"
    printf '%s\n' "$winisms" | sed 's/^/           /'
  fi
fi

code_imported=0; CREATED=()
if [ ${#P_FOLDER[@]} -gt 0 ]; then
  step "Importing Claude Code sessions"
  mkdir -p "$CODE_PROJECTS"
  for i in "${!P_FOLDER[@]}"; do
    mac="${P_MAC[$i]}"
    if [ ! -d "$mac" ]; then mkdir -p "$mac"; CREATED+=("$mac"); fi
    dst_p="$CODE_PROJECTS/$(encode "$mac")"
    mkdir -p "$dst_p"
    n_before=$(find "$dst_p" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')
    rsync -a --ignore-existing "$CODE_PROJ_SRC/${P_FOLDER[$i]}/" "$dst_p/"
    # Point the recorded working folder ("cwd") at the Mac path, including subfolders.
    find "$dst_p" -name '*.jsonl' -print0 | WIN="${P_WIN[$i]}" MAC="$mac" xargs -0 perl -i -pe '
      BEGIN { ($w = $ENV{WIN}) =~ s/\\/\\\\/g; $q = quotemeta $w; $m = $ENV{MAC} }
      s{"cwd":"$q((?:\\\\[^"]*)?)"}{ my $s = $1; $s =~ s{\\\\}{/}g; qq("cwd":"$m$s") }gie'
    n_after=$(find "$dst_p" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')
    code_imported=$((code_imported + n_after - n_before))
    ok "$((n_after - n_before)) new session(s) -> $mac"
  done
  command -v claude >/dev/null 2>&1 || warn "Claude Code CLI not installed. Install: curl -fsSL https://claude.ai/install.sh | bash"
fi

# -----------------------------------------------------------------------------
step "Items that need attention"
attention=0
if [ ${#CREATED[@]} -gt 0 ]; then
  attention=1; warn "These project folders didn't exist, so they were created empty. Copy or clone each project into its folder to work in it:"
  for c in "${CREATED[@]}"; do echo "           $c"; done
fi
MCP_N=$(json_get "$MANIFEST" mcpServerCount); DESK_MCP_N=$(json_get "$MANIFEST" desktopMcpServerCount)
if [ "${MCP_N:-0}" != "0" ]; then
  attention=1; warn "$MCP_N Claude Code MCP server(s) to re-add with 'claude mcp add' (secrets were redacted):"
  echo "           $SRC/code/mcp-servers.redacted.json"
fi
if [ "${DESK_MCP_N:-0}" != "0" ]; then
  attention=1; warn "$DESK_MCP_N Claude Desktop MCP server(s) to re-add in Settings > Developer (fix Windows paths, re-enter secrets):"
  echo "           $SRC/desktop/claude_desktop_config.redacted.json"
fi
CW_REL=$(json_get "$MANIFEST" coworkFolderRelative); CW_WIN=$(json_get "$MANIFEST" coworkFolderWindows)
if [ -n "$CW_REL" ] && [ -n "$ONEDRIVE" ]; then
  attention=1; warn "Connect your Cowork work folder when starting a task: $ONEDRIVE/$CW_REL"
elif [ -n "$CW_WIN" ]; then
  attention=1; warn "The PC's Cowork work folder was outside OneDrive ($CW_WIN). Copy it to the Mac manually."
fi
for n in ${account_notes[@]+"${account_notes[@]}"}; do attention=1; warn "$n"; done
if [ "$code_imported" -gt 0 ]; then
  attention=1; warn "Claude Code: cd into a project and run 'claude --resume'. In VS Code, open the project folder and reload the window."
  echo "           A continued conversation is stored as several session files but listed once, so the list can"
  echo "           show fewer entries than the session count above. That's expected; nothing is missing."
fi
[ "$HAS_COWORK" = "true" ] && { attention=1; warn "Scheduled tasks are stored per device and don't migrate. Recreate them in Cowork."; }
[ "$attention" = 0 ] && ok "None"

if [ "$CLEANUP" = 1 ]; then
  step "Removing credential files from the backup"
  n=$(find "$SRC" -name '.credentials.json' -print -delete | wc -l | tr -d ' ')
  ok "Deleted $n file(s)"
fi

if [ ${#new_sessions[@]} -gt 0 ]; then
  step "Relaunching Claude"
  open -a Claude || warn "Open Claude manually."
fi

printf '\n\033[32mImport complete.\033[0m\n'
[ ${#new_sessions[@]} -gt 0 ] && [ -d "$BACKUP_DIR" ] && echo "Rollback copy of this Mac's previous Cowork sessions: $BACKUP_DIR"
exit 0
