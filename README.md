# Claude PC → Mac Migration

Two scripts move a user's Claude data from one or more Windows PCs to a Mac through **their own OneDrive**. Each one detects what the user has and runs only the parts that apply, without asking the user to make decisions along the way.

| Detects | Handled |
|---|---|
| Claude Desktop install type | Microsoft Store or standard installer; uses the most recent if both exist |
| Cowork sessions | Restored into the Mac app's sidebar with full history |
| Claude Code sessions | Moved under the matching Mac folders, so they show in `claude --resume`, the VS Code extension and the Desktop app's Code tab. Missing folders are created |
| Claude Code config | `CLAUDE.md`, settings, agents, commands, local skills, plans and hooks merged into `~/.claude` |
| Several PCs | Each PC exports to its own folder; the Mac finds and imports all of them |
| Neither Cowork nor Claude Code | Exits cleanly. Chats and Projects already live in the Claude account |

**Never migrated:** login tokens, account-synced skills and plugins (they re-sync at sign-in), caches. MCP secrets are replaced with `<REDACTED>`.

## Prerequisites

- **PC and Mac:** OneDrive signed in to the **same account** on both machines.
- **Mac:** OneDrive's Finder integration turned on, under **System Settings → General → Login Items & Extensions → File Providers → OneDrive**. If it's off, Finder shows an old copy of OneDrive and new files never arrive. If you have to turn it on, restart the Mac.
- **Cowork users:** Claude Desktop installed on the Mac and signed in to the **same Claude account** as the PC.

## Step 1: Export (each Windows PC, as the user)

1. Close Claude Desktop, VS Code and any `claude` terminal sessions.
2. Open PowerShell (not as admin) in the folder containing `Export-ClaudeToOneDrive.ps1` and run:

   ```powershell
   Unblock-File .\Export-ClaudeToOneDrive.ps1
   powershell -ExecutionPolicy Bypass -File .\Export-ClaudeToOneDrive.ps1
   ```

The script:

1. Packs the Cowork and Claude Code sessions into archives. This avoids OneDrive's 400-character path limit.
2. Reads each archive back to verify that every conversation file is in it.
3. Writes everything to `<OneDrive>\Claude_Migration_<COMPUTERNAME>\`.
4. Waits until OneDrive has picked up every file, restarting OneDrive if the sync stalls.

Repeat on every PC you're migrating from; each one gets its own folder. When it finishes, confirm the OneDrive tray icon shows **Up to date**.

Optional switches:

- `-OneDrivePath <path>`: use this if OneDrive isn't detected.
- `-BackupName <name>`: use a different backup folder name.
- `-SkipCodeSessions`: leave out Claude Code session history.
- `-SyncTimeoutMinutes <n>`: how long to wait for OneDrive (default 20).
- `-NoSyncWait`: don't wait for OneDrive.
- `-Force`: close Claude without asking.

## Step 2: Import (Mac, once, as the same user)

In Terminal, run:

```bash
bash import-claude-from-onedrive.sh --dry-run   # verifies every backup and shows the plan; changes nothing
bash import-claude-from-onedrive.sh             # imports; quits and relaunches Claude Desktop
```

Run it with `bash` as shown. Don't paste the script's contents into the terminal.

The script:

1. Finds every `Claude_Migration*` folder in OneDrive and imports each one in turn. It waits up to 3 minutes for OneDrive to deliver them, restarting OneDrive if the sync stalls. If they still haven't arrived, it shows the website-download steps below.
2. Checks every file against the PC's file list, unpacks the archives and confirms their conversation counts match the PC's.
3. Backs up the Mac's existing Cowork sessions to `~/Desktop/claude-migration-backup-<timestamp>/`.
4. Imports the sessions. It never overwrites existing files, so running it again is safe.

Optional switches:

- `--backup-name <name>`: import only that backup.
- `--onedrive <path>`: use this if several OneDrive accounts are signed in.
- `--source <folder>`: import from a downloaded copy instead (see below).
- `--map 'WINPATH=MACPATH'`: put a Windows folder somewhere specific.
- `--wait <seconds>`: how long to wait for OneDrive.
- `--yes`: quit Claude without asking.
- `--cleanup`: delete the backup's credential files afterwards.

### Where Claude Code sessions go

Claude Code files each session under the folder it ran in, so every Windows folder gets a matching Mac folder. The script uses the first rule that applies:

| Windows folder | Mac folder |
|---|---|
| Matches a `--map 'WINPATH=MACPATH'` rule | The folder you specified |
| Inside OneDrive | The same place in the Mac's OneDrive |
| `C:\Users\<name>\repos\app` | `~/repos/app` |
| `D:\work\infra` (another drive) | `~/D-drive/work/infra` |

If the Mac folder doesn't exist, it's created empty and listed at the end, so you can copy or clone the project into it. To place projects somewhere else, re-run with `--map`, for example `--map 'D:\work=~/code'`.

Once the import finishes, `cd` into a project and run `claude --resume`. In VS Code, open the project folder and reload the window (Cmd+Shift+P → **Developer: Reload Window**).

**Fewer entries than sessions is normal.** When a conversation is continued or resumed, Claude Code saves it as a new session file that carries the earlier history forward, and `claude --resume` lists only the latest one. For example, 6 imported sessions can show as 5 entries, with nothing lost.

## If the Mac's OneDrive doesn't deliver the backup

1. Check the Finder integration setting in the prerequisites, then restart the Mac.
2. Or skip the Mac's OneDrive app entirely:
   1. Open OneDrive in a browser and press **Cmd+Shift+R** to refresh.
   2. Select the `Claude_Migration_<PC>` folder, click **Download** and double-click the zip.
   3. Run the import against the unzipped folder:

      ```bash
      bash import-claude-from-onedrive.sh --source ~/Downloads/Claude_Migration_<PC>
      ```

## Passing the OneDrive path manually (only if needed)

- **PC:** in File Explorer, click your work OneDrive in the sidebar, copy the path from the address bar, and pass it in quotes: `-OneDrivePath "C:\Users\jdoe\OneDrive - Contoso"`.
- **Mac:** run `ls ~/Library/CloudStorage/` and pass the work OneDrive folder: `--onedrive ~/Library/CloudStorage/OneDrive-Contoso`.

Pass the **OneDrive root**, not the backup folder.

## Step 3: Verify and clean up

1. Open Cowork, confirm the PC sessions appear, and open the most recent one to check its full history.
2. `cd` into a migrated project and run `claude --resume`, then check VS Code and the Desktop app's **Code** tab.
3. Work through **"Items that need attention"** at the end of the import. It may include:
   - **New project folders:** copy or clone each project into the folder that was created for it.
   - **Settings:** merge `~/.claude/settings.from-pc.json` if the Mac already had its own settings.
   - **MCP servers:** re-add them, since secrets were redacted.
   - **Cowork work folder:** connect it in Cowork.
   - **Scheduled tasks:** recreate them, because they don't migrate.
4. Delete the `Claude_Migration_*` folders from OneDrive, any downloaded copies, and the Desktop backup folder.

## Troubleshooting

| Symptom | Fix |
|---|---|
| PC: "has X of Y conversation files" | The archive check failed and nothing was changed. Close Claude and VS Code, then re-run. |
| PC: files still not synced after the wait | Open the OneDrive tray icon, resume syncing if it's paused, fix any error listed, and wait for "Up to date". |
| Mac: Finder doesn't show new OneDrive files, even though the PC says synced | Turn on the Finder integration (see Prerequisites) and restart the Mac. |
| Mac: "OneDrive on this Mac hasn't delivered the backup" | Check the Finder integration, or use the website download with `--source`. |
| Mac: "sessions belong to Claude account …" | Sign in to Claude Desktop with the account used on the PC. The sessions are already in place and will appear. |
| Mac: "Could not unpack" | The download is incomplete or corrupted. Re-download it, or re-run the export on the PC. |
| `claude --resume` shows fewer sessions than were imported | Expected for continued conversations (see above). |
| A Claude Code session doesn't appear at all | Open the **exact** Mac folder shown for it in the import output, then reload the VS Code window. |
| An imported Cowork session lists but won't open | Re-export with `-IncludeSessionCredentials`, re-import, then run the import with `--cleanup`. |

> **Note:** this is a community workaround. It relies on Claude's internal file layout, which Anthropic hasn't documented and could change in a future update. It was tested in production by migrating two Windows PCs (both with the Microsoft Store version of Claude Desktop) to a Mac with Claude Code 2.1.286.
