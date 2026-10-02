<#
.SYNOPSIS
    Step 1 of 2 (run on the Windows PC): exports Claude Desktop, Cowork and
    Claude Code data into the current user's OneDrive so it can be restored on a Mac.

.DESCRIPTION
    What it exports (into <OneDrive>\<BackupName>\):
      (BackupName defaults to Claude_Migration_<COMPUTERNAME>)
      - cowork\sessions.tgz            Cowork sessions (conversations, uploads, outputs)
      - code\projects.tgz              Claude Code sessions (~\.claude\projects)
      - code\projects-index.tsv        Each Claude Code project's original Windows folder
      - code\dot-claude\               CLAUDE.md, settings.json, agents, commands, local skills,
                                       plans, hooks, output-styles
      - code\mcp-servers.redacted.json Claude Code MCP servers (secrets redacted)
      - desktop\                       Claude Desktop config, reference only (secrets redacted)
      - manifest.json, manifest-files.txt  Let the Mac script verify everything arrived

    Sessions are packed into archives because their folder names embed full Windows paths,
    which can exceed OneDrive's 400-character path limit. Each archive is read back and
    verified to contain every conversation file before the script continues.

    After exporting, the script pushes OneDrive to sync (restarting it if it stalls) and
    waits until OneDrive has picked up every file.

    Never exported: login tokens, account-synced skills/plugins (they re-sync at sign-in),
    caches, lock and temp files. Works with the Microsoft Store and standard installers,
    and with users who have Cowork only, Claude Code only, both, or neither.

.PARAMETER OneDrivePath
    Root of the user's OneDrive folder. Detected automatically from %OneDriveCommercial% / %OneDrive%.
.PARAMETER BackupName
    Folder created at the OneDrive root. Default: Claude_Migration_<COMPUTERNAME>, so each PC
    gets its own backup. The Mac script finds and imports every Claude_Migration* folder.
.PARAMETER SkipCodeSessions
    Don't export Claude Code session history.
.PARAMETER IncludeSessionCredentials
    Keep per-session sandbox .credentials.json files in Cowork sessions. Off by default; only
    use this if an imported Cowork session fails to open on the Mac.
.PARAMETER SyncTimeoutMinutes
    How long to wait for OneDrive to pick up the backup. Default: 20
.PARAMETER NoSyncWait
    Don't wait for OneDrive.
.PARAMETER Force
    Close Claude without asking.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Export-ClaudeToOneDrive.ps1
#>
[CmdletBinding()]
param(
    [string]$OneDrivePath,
    [string]$BackupName = "Claude_Migration_$env:COMPUTERNAME",
    [switch]$SkipCodeSessions,
    [switch]$IncludeSessionCredentials,
    [int]$SyncTimeoutMinutes = 20,
    [switch]$NoSyncWait,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    [OK]   $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Stop-WithError([string]$m) { Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

function Invoke-Robocopy([string]$Src, [string]$Dst, [string[]]$Extra = @()) {
    $rcArgs = @($Src, $Dst, '/E', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NP', '/NJH', '/NJS') + $Extra
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-WithError "robocopy failed (exit $LASTEXITCODE) copying $Src" }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# Deletes a folder even if it contains paths longer than 260 characters.
function Remove-LongPathFolder([string]$Path) {
    if (Test-Path -LiteralPath $Path) { cmd /c "rmdir /s /q `"\\?\$Path`"" | Out-Null }
}

# Replaces values under env/headers in an mcpServers object with <REDACTED>. Returns server count.
function Protect-McpServers($servers) {
    if ($null -eq $servers) { return 0 }
    $count = 0
    foreach ($s in $servers.PSObject.Properties) {
        $count++
        foreach ($key in 'env', 'headers') {
            $p = $s.Value.PSObject.Properties[$key]
            if ($p -and $p.Value) {
                foreach ($kv in $p.Value.PSObject.Properties) { $kv.Value = '<REDACTED>' }
            }
        }
    }
    return $count
}

# Packs $Items (relative to $SourceDir) into a .tgz with Windows' built-in tar.exe (handles long
# paths), reads it back, and stops unless it holds at least $ExpectedJsonl conversation files.
# Returns the number of conversation files in the archive.
function New-VerifiedArchive([string]$ArchivePath, [string]$SourceDir, [string[]]$Items, [string[]]$Excludes, [int]$ExpectedJsonl) {
    New-Item -ItemType Directory -Force -Path (Split-Path $ArchivePath) | Out-Null
    if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
    $tarArgs = @('-c', '-z', '-f', $ArchivePath, '-C', $SourceDir) + ($Excludes | ForEach-Object { "--exclude=$_" }) + $Items
    & tar.exe @tarArgs
    if ($LASTEXITCODE -ne 0) { Stop-WithError "tar failed (exit $LASTEXITCODE) creating $ArchivePath" }
    $listing = @(& tar.exe -t -z -f $ArchivePath)
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Could not read back $ArchivePath" }
    $inArchive = @($listing | Where-Object { $_ -like '*.jsonl' }).Count
    if ($inArchive -lt $ExpectedJsonl) {
        Stop-WithError "$(Split-Path $ArchivePath -Leaf) has $inArchive of $ExpectedJsonl conversation files. Nothing on this PC was changed."
    }
    $creds = @($listing | Where-Object { $_ -like '*.credentials.json' }).Count
    if ($creds -gt 0 -and -not $IncludeSessionCredentials) {
        Write-Warn "$creds credential file(s) are in $(Split-Path $ArchivePath -Leaf). Delete the backup from OneDrive after the Mac import is verified."
    }
    return $inArchive
}

function Get-OneDriveExe {
    $p = (Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    if (-not $p) {
        $p = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
               "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
               "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe") |
             Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    }
    return $p
}

function Restart-OneDrive {
    $exe = Get-OneDriveExe
    if (-not $exe) { Write-Warn 'OneDrive.exe not found; cannot restart it.'; return }
    Write-Host '    Restarting OneDrive to force a sync pass...'
    & $exe /shutdown
    Start-Sleep -Seconds 5
    Start-Process -FilePath $exe -ArgumentList '/background'
    Start-Sleep -Seconds 10
}

# ---------------------------------------------------------------------------
Write-Step 'Locating OneDrive'
if (-not $OneDrivePath) {
    $OneDrivePath = @($env:OneDriveCommercial, $env:OneDrive) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $OneDrivePath -or -not (Test-Path $OneDrivePath)) {
    Stop-WithError "OneDrive not found. Sign in to OneDrive, or re-run with -OneDrivePath 'C:\Users\<user>\OneDrive - <Org>'"
}
$OneDrivePath = (Resolve-Path $OneDrivePath).Path.TrimEnd('\')
$Dest = Join-Path $OneDrivePath $BackupName
Write-Ok "OneDrive: $OneDrivePath"
Write-Ok "Backup folder: $Dest"

# ---------------------------------------------------------------------------
Write-Step 'Detecting what this user has installed'

# Claude Desktop can live in two places:
#   Standard installer (claude.ai download): %APPDATA%\Claude
#   Microsoft Store (MSIX) package:          %LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude
$desktopCandidates = @()
$std = Join-Path $env:APPDATA 'Claude'
if (Test-Path $std) { $desktopCandidates += [pscustomobject]@{ Type = 'standard'; Path = $std } }
Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Join-Path $_.FullName 'LocalCache\Roaming\Claude'
    if (Test-Path $p) { $desktopCandidates += [pscustomobject]@{ Type = 'microsoft-store'; Path = $p } }
}
# If both exist (e.g. the user switched installers), use the one with the most recent Cowork activity.
$withSessions = @($desktopCandidates | Where-Object { Test-Path (Join-Path $_.Path 'local-agent-mode-sessions') } |
    Sort-Object { (Get-Item (Join-Path $_.Path 'local-agent-mode-sessions')).LastWriteTime } -Descending)
$desktop = if ($withSessions.Count -gt 0) { $withSessions[0] } else { $desktopCandidates | Select-Object -First 1 }
if ($withSessions.Count -gt 1) {
    Write-Warn ("Cowork data found in {0} installs. Using the most recent: {1}" -f $withSessions.Count, $desktop.Path)
}

$ClaudeRoot     = if ($desktop) { $desktop.Path } else { $null }
$InstallType    = if ($desktop) { $desktop.Type } else { 'none' }
$ClaudeCodeDir  = Join-Path $env:USERPROFILE '.claude'
$ClaudeCodeJson = Join-Path $env:USERPROFILE '.claude.json'
$sessSrc        = if ($ClaudeRoot) { Join-Path $ClaudeRoot 'local-agent-mode-sessions' } else { $null }
$projSrc        = Join-Path $ClaudeCodeDir 'projects'

$HasDesktop    = [bool]$ClaudeRoot
$HasCowork     = $HasDesktop -and [bool](Get-ChildItem $sessSrc -Recurse -Depth 2 -Filter 'local_*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
$HasClaudeCode = (Test-Path $ClaudeCodeDir) -or (Test-Path $ClaudeCodeJson)

Write-Host ("    Claude Desktop : {0}" -f $(if ($HasDesktop) { "yes ($InstallType) - $ClaudeRoot" } else { 'not found' }))
Write-Host ("    Cowork         : {0}" -f $(if ($HasCowork) { 'yes - sessions found' } else { 'no sessions (skipping)' }))
Write-Host ("    Claude Code    : {0}" -f $(if ($HasClaudeCode) { "yes - $ClaudeCodeDir" } else { 'not used (skipping)' }))

if (-not $HasDesktop -and -not $HasClaudeCode) {
    Write-Host "`nNothing to migrate: no Claude Desktop data and no Claude Code config for $env:USERNAME." -ForegroundColor Yellow
    Write-Host 'Regular chats and Projects live in the Claude account and need no migration.'
    exit 0
}
if (($HasCowork -or (Test-Path $projSrc)) -and -not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Stop-WithError 'tar.exe not found. Windows 10 version 1803 or later is required.'
}

# ---------------------------------------------------------------------------
Write-Step 'Checking that Claude is closed'
$procs = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)
if ($procs.Count -gt 0) {
    if (-not $Force) {
        $answer = Read-Host '    Claude is running and must be closed so session files are not mid-write. Close it now? (Y/N)'
        if ($answer -notmatch '^[Yy]') { Stop-WithError 'Close Claude Desktop, VS Code and any Claude Code sessions, then re-run.' }
    }
    $procs | ForEach-Object { [void]$_.CloseMainWindow() }
    Start-Sleep -Seconds 5
    Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}
Write-Ok 'Claude is not running'

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
# Remove folder-style session copies left by earlier versions of this script (they can't sync).
Remove-LongPathFolder (Join-Path $Dest 'cowork\local-agent-mode-sessions')
Remove-LongPathFolder (Join-Path $Dest 'code\projects')

$manifest = [ordered]@{
    createdAt                 = (Get-Date).ToString('o')
    sourceComputer            = $env:COMPUTERNAME
    sourceUser                = $env:USERNAME
    installType               = $InstallType
    hasDesktop                = $HasDesktop
    hasCowork                 = [bool]$HasCowork
    hasClaudeCode             = [bool]$HasClaudeCode
    includeSessionCredentials = [bool]$IncludeSessionCredentials
    oneDriveRootWindows       = $OneDrivePath
    windowsUserProfile        = $env:USERPROFILE
    accounts                  = @()
    sessions                  = @()
    coworkArchive             = ''
    coworkTranscriptCount     = 0
    codeArchive               = ''
    codeTranscriptCount       = 0
    codeProjectCount          = 0
    codeSessionCount          = 0
    coworkFolderWindows       = ''
    coworkFolderRelative      = ''
    mcpServerCount            = 0
    desktopMcpServerCount     = 0
}

# ---------------------------------------------------------------------------
Write-Step 'Exporting Cowork sessions'
if ($HasCowork) {
    $onDisk = @(Get-ChildItem $sessSrc -Recurse -File -Force -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike (Join-Path $sessSrc 'skills-plugin\*') }).Count
    $excl = @('skills-plugin', '*.lock', '*.tmp', '~$*')
    if (-not $IncludeSessionCredentials) { $excl += '.credentials.json' }
    $n = New-VerifiedArchive (Join-Path $Dest 'cowork\sessions.tgz') $sessSrc @('.') $excl $onDisk
    $manifest.coworkArchive = 'cowork/sessions.tgz'
    $manifest.coworkTranscriptCount = $n
    Write-Ok ("Packed cowork\sessions.tgz ({0:N0} MB): {1} of {2} conversation file(s) verified" -f ((Get-Item (Join-Path $Dest 'cowork\sessions.tgz')).Length / 1MB), $n, $onDisk)

    $guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    foreach ($acct in Get-ChildItem $sessSrc -Directory | Where-Object Name -match $guid) {
        foreach ($org in Get-ChildItem $acct.FullName -Directory | Where-Object Name -match $guid) {
            $manifest.accounts += [pscustomobject][ordered]@{ account = $acct.Name; org = $org.Name }
            foreach ($f in Get-ChildItem $org.FullName -File -Filter 'local_*.json') {
                try {
                    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
                    $last = if ($j.lastActivityAt) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$j.lastActivityAt).LocalDateTime.ToString('yyyy-MM-dd') } else { '' }
                    $manifest.sessions += [pscustomobject][ordered]@{ id = $j.sessionId; title = $j.title; lastActivity = $last; account = $acct.Name; org = $org.Name }
                } catch { Write-Warn "Could not read session metadata: $($f.Name)" }
            }
        }
    }
    Write-Ok ("{0} Cowork session(s):" -f $manifest.sessions.Count)
    $manifest.sessions | Sort-Object lastActivity -Descending | ForEach-Object { Write-Host ("           {0}  {1}" -f $_.lastActivity, $_.title) }
} else {
    Write-Ok 'Skipped: no Cowork sessions'
}

# ---------------------------------------------------------------------------
Write-Step 'Exporting Claude Code user config'
$ccDst = Join-Path $Dest 'code\dot-claude'
if (Test-Path $ClaudeCodeDir) {
    New-Item -ItemType Directory -Force -Path $ccDst | Out-Null
    foreach ($name in 'CLAUDE.md', 'settings.json', 'keybindings.json') {
        $p = Join-Path $ClaudeCodeDir $name
        if (Test-Path $p) { Copy-Item $p $ccDst -Force; Write-Ok $name }
    }
    foreach ($name in 'agents', 'commands', 'skills', 'plans', 'hooks', 'output-styles') {
        $p = Join-Path $ClaudeCodeDir $name
        if (Test-Path $p) {
            # skills\synced is re-synced from the Claude account; do not copy it.
            Invoke-Robocopy $p (Join-Path $ccDst $name) @('/XD', (Join-Path $p 'synced'), '/XF', '.credentials.json')
            Write-Ok "$name\"
        }
    }
} else {
    Write-Ok 'Skipped: Claude Code not used'
}

# ---------------------------------------------------------------------------
Write-Step 'Exporting Claude Code sessions'
if ($SkipCodeSessions) {
    Write-Ok 'Skipped (-SkipCodeSessions)'
} elseif (Test-Path $projSrc) {
    # Sessions are filed under a folder named after the Windows path they ran in
    # (e.g. C--Users-jdoe-repos-app). Record each project's real path from the "cwd"
    # field so the Mac can re-file them.
    $index = @(); $expected = 0
    foreach ($dir in Get-ChildItem $projSrc -Directory) {
        $top = @(Get-ChildItem $dir.FullName -Filter '*.jsonl' -File)
        if ($top.Count -eq 0) { continue }
        $m = $top | Sort-Object LastWriteTime | Select-String -Pattern '"cwd":"([^"]+)"' -List | Select-Object -First 1
        if (-not $m) { Write-Warn "No working folder recorded in $($dir.Name); skipped"; continue }
        $cwd  = $m.Matches[0].Groups[1].Value -replace '\\\\', '\'
        $last = ($top | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime.ToString('yyyy-MM-dd')
        $expected += @(Get-ChildItem $dir.FullName -Recurse -File -Force -Filter '*.jsonl' -ErrorAction SilentlyContinue).Count
        $index += [pscustomobject][ordered]@{ Folder = $dir.Name; Cwd = $cwd; Sessions = $top.Count; LastUsed = $last }
    }
    if ($index.Count -gt 0) {
        $n = New-VerifiedArchive (Join-Path $Dest 'code\projects.tgz') $projSrc @($index.Folder) @('*.lock', '*.tmp', '~$*') $expected
        # Tab-separated (paths can contain commas); read by the Mac script.
        $tsv = ($index | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.Folder, $_.Cwd, $_.Sessions, $_.LastUsed }) -join "`n"
        Write-Utf8NoBom (Join-Path $Dest 'code\projects-index.tsv') ($tsv + "`n")
        $manifest.codeArchive         = 'code/projects.tgz'
        $manifest.codeTranscriptCount = $n
        $manifest.codeProjectCount    = $index.Count
        $manifest.codeSessionCount    = ($index | Measure-Object Sessions -Sum).Sum
        Write-Ok ("Packed code\projects.tgz: {0} of {1} conversation file(s) verified" -f $n, $expected)
        Write-Ok ("{0} session(s) across {1} project(s):" -f $manifest.codeSessionCount, $index.Count)
        $index | Sort-Object LastUsed -Descending | ForEach-Object { Write-Host ("           {0}  {1,3}  {2}" -f $_.LastUsed, $_.Sessions, $_.Cwd) }
    } else {
        Write-Ok 'No Claude Code sessions found'
    }
} else {
    Write-Ok 'No Claude Code sessions found'
}

if ($HasClaudeCode -and (Test-Path $ClaudeCodeJson)) {
    $cj = Get-Content $ClaudeCodeJson -Raw | ConvertFrom-Json
    $mcp = [ordered]@{ user = $cj.mcpServers; projects = [ordered]@{} }
    $total = Protect-McpServers $cj.mcpServers
    if ($cj.projects) {
        foreach ($proj in $cj.projects.PSObject.Properties) {
            $servers = $proj.Value.mcpServers
            $c = Protect-McpServers $servers
            if ($c -gt 0) { $mcp.projects[$proj.Name] = $servers; $total += $c }
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'code') | Out-Null
    Write-Utf8NoBom (Join-Path $Dest 'code\mcp-servers.redacted.json') ($mcp | ConvertTo-Json -Depth 20)
    $manifest.mcpServerCount = $total
    Write-Ok "Claude Code MCP servers: $total (secrets redacted)"
}

# ---------------------------------------------------------------------------
Write-Step 'Exporting Claude Desktop config (reference only)'
$deskCfg = if ($ClaudeRoot) { Join-Path $ClaudeRoot 'claude_desktop_config.json' } else { $null }
if ($deskCfg -and (Test-Path $deskCfg)) {
    $dc = Get-Content $deskCfg -Raw | ConvertFrom-Json
    $manifest.desktopMcpServerCount = Protect-McpServers $dc.mcpServers
    $cwf = $dc.coworkUserFilesPath
    if ($cwf) {
        $manifest.coworkFolderWindows = $cwf
        if ($cwf.StartsWith($OneDrivePath, [StringComparison]::OrdinalIgnoreCase)) {
            $manifest.coworkFolderRelative = $cwf.Substring($OneDrivePath.Length).TrimStart('\').Replace('\', '/')
        } else {
            Write-Warn "Cowork work folder is NOT in OneDrive: $cwf. Move it into OneDrive to bring those files across."
        }
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'desktop') | Out-Null
    Write-Utf8NoBom (Join-Path $Dest 'desktop\claude_desktop_config.redacted.json') ($dc | ConvertTo-Json -Depth 30)
    Write-Ok ("Desktop MCP servers: {0}" -f $manifest.desktopMcpServerCount)
    if ($cwf) { Write-Ok "Cowork work folder: $cwf" }
} else {
    Write-Ok 'Skipped: no claude_desktop_config.json'
}

# ---------------------------------------------------------------------------
Write-Step 'Writing manifest'
$skip = @('manifest.json', 'manifest-files.txt')
$files = @(Get-ChildItem $Dest -Recurse -File -Force |
    ForEach-Object { $_.FullName.Substring($Dest.Length + 1).Replace('\', '/') } |
    Where-Object { $skip -notcontains $_ } | Sort-Object)
Write-Utf8NoBom (Join-Path $Dest 'manifest-files.txt') (($files -join "`n") + "`n")
Write-Utf8NoBom (Join-Path $Dest 'manifest.json') ($manifest | ConvertTo-Json -Depth 6)
Write-Ok ("{0} files listed in manifest" -f $files.Count)

$leftover = @(Get-ChildItem $Dest -Recurse -Force -Filter '.credentials.json' -ErrorAction SilentlyContinue)
if ($leftover.Count -gt 0 -and -not $IncludeSessionCredentials) {
    $leftover | Remove-Item -Force
    Write-Ok "Removed $($leftover.Count) credential file(s) left by an earlier export"
}

# ---------------------------------------------------------------------------
# OneDrive turns each file into a cloud placeholder (reparse point) once it has taken it into
# sync. Wait for that on every backup file, restarting OneDrive if it stalls.
Write-Step 'Syncing the backup to OneDrive'
$synced = $false
if ($NoSyncWait) {
    Write-Ok 'Skipped (-NoSyncWait)'
} else {
    $isPending = { param($f) -not ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) }
    $sample = @(Get-ChildItem $OneDrivePath -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$Dest\*" } | Select-Object -First 25)
    $filesOnDemand = ($sample.Count -eq 0) -or [bool]($sample | Where-Object { -not (& $isPending $_) })
    if (-not $filesOnDemand) {
        Restart-OneDrive
        Write-Warn 'OneDrive Files On-Demand is off, so upload progress cannot be checked from here.'
    } else {
        $start = Get-Date; $deadline = $start.AddMinutes($SyncTimeoutMinutes); $restarts = 0; $lastCount = -1; $lastChange = $start
        while ($true) {
            $pending = @(Get-ChildItem $Dest -Recurse -File -Force | Where-Object { & $isPending $_ })
            if ($pending.Count -eq 0) { Write-Host ''; Write-Ok 'OneDrive has picked up every file'; $synced = $true; break }
            if ($pending.Count -ne $lastCount) { $lastCount = $pending.Count; $lastChange = Get-Date }
            if ((Get-Date) -gt $deadline) {
                Write-Host ''
                Write-Warn "$($pending.Count) file(s) still not synced after $SyncTimeoutMinutes minutes:"
                $pending | Select-Object -First 5 | ForEach-Object { Write-Host "           $($_.FullName.Substring($Dest.Length + 1))" }
                break
            }
            # No progress for 2 minutes: restart OneDrive (at most twice).
            if (((Get-Date) - $lastChange).TotalSeconds -ge 120 -and $restarts -lt 2) {
                Write-Host ''; Restart-OneDrive; $restarts++; $lastChange = Get-Date
            }
            Write-Host -NoNewline ("`r    Waiting for OneDrive: {0} file(s) left ({1:mm\:ss} elapsed)   " -f $pending.Count, ((Get-Date) - $start))
            Start-Sleep -Seconds 10
        }
    }
}

Write-Host "`nExport complete: $Dest" -ForegroundColor Green
if ($synced) {
    Write-Host "Next: confirm the OneDrive tray icon shows 'Up to date', then run import-claude-from-onedrive.sh on the Mac."
} else {
    Write-Host "Next: open the OneDrive tray icon. Resume syncing if it is paused, fix any error it lists, and wait for 'Up to date'."
    Write-Host "      Then run import-claude-from-onedrive.sh on the Mac."
}
Write-Host "      The Mac script finds this backup ($BackupName) automatically, along with any from other PCs."
