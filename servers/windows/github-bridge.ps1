<#
.SYNOPSIS
    Install the cc.save GitHub-hub bridge as a Windows Scheduled Task that runs at logon and keeps
    this PC's CrossCode (Steam) save in sync with the private GitHub hub (cc-mods/cc-saves).

.DESCRIPTION
    The PC side of the GitHub-hub save sync. The iPhone talks to GitHub directly; this bridge mirrors
    THIS PC's Steam cc.save <-> the hub, so phone progress reaches Steam Cloud (launch CrossCode to let
    Steam upload) and desktop progress reaches the phone.

    Like the save-server wrapper, `install` copies servers/github-steam-bridge.py into
    %USERPROFILE%\.cc-tailsync and runs that copy, so the task is independent of the repo path. Re-run
    `install` after editing the bridge.

    Config: needs %USERPROFILE%\.cc-tailsync\cc-github.json ({ "repo","path","token" } — a fine-grained
    PAT with Contents:R/W on the one repo). No token is passed on the command line (so it never lands
    in task XML or shell history).

    SAFETY DESIGN — two directions, different risk:
      * PUSH (Steam save -> hub): always safe; runs every cycle (no-op when already in sync).
      * PULL (hub -> Steam save): writing the Steam path while Steam thinks its cloud copy is newer can
        make Steam silently overwrite it on next launch. So auto-pull is gated to when CrossCode is NOT
        running, and the bridge never auto-clobbers on a genuine divergence (it reports a conflict and
        changes nothing). Use -PullIntervalSec 0 to disable auto-pull and only ever pull by hand (`run`).

.PARAMETER Save
    Path to the Steam cc.save. Defaults to %LOCALAPPDATA%\CrossCode\cc.save.

.PARAMETER PullIntervalSec
    Seconds between conflict-safe pull checks (default 300; 0 = push-only, never auto-pull).

.EXAMPLE
    .\github-bridge.ps1 install
.EXAMPLE
    .\github-bridge.ps1 install -PullIntervalSec 0     # push-on-cycle only, manual pull
.EXAMPLE
    .\github-bridge.ps1 uninstall
.EXAMPLE
    .\github-bridge.ps1 run                            # one-shot foreground sync (manual)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status', 'run')]
    [string]$Command = 'install',
    [string]$Save,
    [int]$PullIntervalSec = 300
)

$ErrorActionPreference = 'Stop'

$taskName    = 'cc-tailsync GitHub bridge'
$installDir  = Join-Path $env:USERPROFILE '.cc-tailsync'
$installedPy = Join-Path $installDir 'github-steam-bridge.py'
$installedPs = Join-Path $installDir 'github-bridge-run.ps1'
$configJson  = Join-Path $installDir 'cc-github.json'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgePy  = Join-Path $scriptDir '..\github-steam-bridge.py'

function Resolve-Python {
    foreach ($c in @('python', 'python3', 'py')) {
        $p = Get-Command $c -ErrorAction SilentlyContinue
        if ($p) { return $p.Source }
    }
    throw "Python not found in PATH. Install Python 3 and retry."
}

function Write-Runner {
    param([string]$PyExe, [string]$SavePath, [int]$Interval)
    # The task runs this each cycle: always push (no-op if in sync); pull only when the interval has
    # elapsed AND CrossCode isn't running, so we never fight a live game / Steam's own cloud sync.
    $stamp = Join-Path $installDir '.last-pull'
    @"
`$ErrorActionPreference = 'SilentlyContinue'
`$py    = '$PyExe'
`$br    = '$installedPy'
`$save  = '$SavePath'
`$intvl = $Interval
`$stamp = '$stamp'

# PUSH (safe): mirror local -> hub. Bridge is a no-op when in sync and never auto-clobbers.
& `$py `$br --save `$save | Out-Null

# PULL (gated): only every `$intvl s, and only when CrossCode is closed.
if (`$intvl -gt 0 -and -not (Get-Process -Name 'CrossCode','nw' -ErrorAction SilentlyContinue)) {
    `$now  = [int][double]::Parse((Get-Date -UFormat %s))
    `$last = 0
    if (Test-Path `$stamp) { `$last = [int](Get-Content `$stamp -ErrorAction SilentlyContinue) }
    if ((`$now - `$last) -ge `$intvl) {
        & `$py `$br --save `$save | Out-Null   # bridge decides push/pull/in-sync/conflict, safely
        Set-Content -Path `$stamp -Value `$now
    }
}
"@ | Set-Content -Path $installedPs -Encoding UTF8
}

function Invoke-Install {
    if (-not (Test-Path $bridgePy)) { throw "bridge not found: $bridgePy" }
    if (-not (Test-Path $configJson)) {
        throw "config missing: $configJson  (needs { repo, path, token })"
    }
    $pyExe = Resolve-Python
    $save  = if ($Save) { $Save } else { Join-Path $env:LOCALAPPDATA 'CrossCode\cc.save' }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -Force $bridgePy $installedPy
    Write-Runner -PyExe $pyExe -SavePath $save -Interval $PullIntervalSec

    $argument = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installedPs`""
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument

    # At logon + repeat every PullIntervalSec (so the pull check fires even with no save change).
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    if ($PullIntervalSec -gt 0) {
        $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Seconds $PullIntervalSec) `
            -RepetitionDuration ([TimeSpan]::MaxValue)).Repetition
    }
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Force -RunLevel Limited | Out-Null
    Start-ScheduledTask -TaskName $taskName

    Write-Host "Installed + started scheduled task '$taskName'." -ForegroundColor Green
    Write-Host "  bridge: $installedPy  (copied from $bridgePy)"
    Write-Host "  save:   $save"
    Write-Host "  push:   every cycle (no-op when in sync)"
    Write-Host "  pull:   every ${PullIntervalSec}s, only when CrossCode is closed (0 = disabled)"
    Write-Host ""
    Write-Host "Runs at logon. Check it with:  .\github-bridge.ps1 status"
}

function Invoke-Uninstall {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'." -ForegroundColor Green
    } else {
        Write-Host "Task '$taskName' not found; nothing to remove." -ForegroundColor Yellow
    }
    if (Test-Path $installedPs) { Remove-Item -Force $installedPs }
    Write-Host "  (left $installDir in place; delete it manually if you want.)"
}

function Invoke-Status {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Host "not installed."; return }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    Write-Host "task:      $taskName"
    Write-Host "state:     $($task.State)"
    Write-Host "last run:  $($info.LastRunTime)  (result $($info.LastTaskResult))"
    Write-Host "next run:  $($info.NextRunTime)"
}

function Invoke-Run {
    $pyExe = Resolve-Python
    $save  = if ($Save) { $Save } else { Join-Path $env:LOCALAPPDATA 'CrossCode\cc.save' }
    & $pyExe $bridgePy --save $save
}

switch ($Command) {
    'install'   { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'status'    { Invoke-Status }
    'run'       { Invoke-Run }
}
