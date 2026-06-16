<#
.SYNOPSIS
    Manage the cc-tailsync save-server as a persistent Windows service via a Scheduled Task, so
    wireless (Tailscale) save sync keeps working across logins/reboots without a console open.

.DESCRIPTION
    Wraps servers/save-server.py. The task mirrors the desktop CrossCode save
    (%LOCALAPPDATA%\CrossCode\cc.save by default) and serves it on 0.0.0.0:<port>, reachable over
    your tailnet. It runs at logon and auto-restarts on failure.

    Like the macOS launchd wrapper, `install` copies save-server.py into %USERPROFILE%\.cc-tailsync
    and runs that copy, so the task is independent of the repo path. Re-run `install` after editing
    the server. The Scheduled Task runs as the current user (no admin required); it starts when you
    log in. For a truly always-on host, keep the machine logged in (or adapt the trigger to SYSTEM
    with admin rights).

.PARAMETER Command
    install | uninstall | status | run

.PARAMETER Port
    TCP port to listen on (default 8765).

.PARAMETER Save
    Path to the cc.save to mirror (default: %LOCALAPPDATA%\CrossCode\cc.save, detected by the server).

.PARAMETER Token
    Optional bearer token to require (Authorization: Bearer <token>). Defaults to $env:CC_SYNC_TOKEN.

.EXAMPLE
    .\save-server.ps1 install
.EXAMPLE
    .\save-server.ps1 install -Port 9000 -Token secret
.EXAMPLE
    .\save-server.ps1 status
.EXAMPLE
    .\save-server.ps1 uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status', 'run')]
    [string]$Command = 'status',
    [int]$Port = 8765,
    [string]$Save = '',
    [string]$Token = $env:CC_SYNC_TOKEN
)

$ErrorActionPreference = 'Stop'

$taskName   = 'cc-tailsync-save-server'
$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$serverPy   = Join-Path $repoRoot 'servers\save-server.py'
$installDir = Join-Path $env:USERPROFILE '.cc-tailsync'
$installedPy = Join-Path $installDir 'save-server.py'

function Resolve-Python {
    $c = Get-Command python -ErrorAction SilentlyContinue
    if (-not $c) { $c = Get-Command py -ErrorAction SilentlyContinue }
    if (-not $c) { throw "Python 3 not found on PATH. Install it from https://python.org and re-run." }
    return $c.Source
}

function Invoke-Install {
    if (-not (Test-Path $serverPy)) { throw "server not found: $serverPy" }
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -Force $serverPy $installedPy

    $pyExe = Resolve-Python

    # Build the inner PowerShell command the task will run. The token (if any) is set as an env var
    # for the server process; the save path is passed through when provided.
    $envPrefix = if ($Token) { "`$env:CC_SYNC_TOKEN='$Token'; " } else { "" }
    $saveArg   = if ($Save)  { " --save '$Save'" } else { "" }
    $inner     = "$envPrefix& '$pyExe' '$installedPy' --port $Port$saveArg"
    $argument  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$inner`""

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Force -RunLevel Limited | Out-Null
    Start-ScheduledTask -TaskName $taskName

    Write-Host "Installed + started scheduled task '$taskName' (port $Port)." -ForegroundColor Green
    Write-Host "  script: $installedPy  (copied from $serverPy)"
    Write-Host "  mirrors: $(if ($Save) { $Save } else { "$env:LOCALAPPDATA\CrossCode\cc.save (auto)" })"
    Write-Host "  auth:   $(if ($Token) { 'token required' } else { 'open (rely on tailnet ACLs)' })"
    Write-Host ""
    Write-Host "It runs at logon and restarts on failure. Check it with:  .\save-server.ps1 status"
}

function Invoke-Uninstall {
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Removed scheduled task '$taskName'." -ForegroundColor Green
    } else {
        Write-Host "Task '$taskName' not found; nothing to remove." -ForegroundColor Yellow
    }
    if (Test-Path $installedPy) { Remove-Item -Force $installedPy }
    Write-Host "  (left $installDir in place; delete it manually if you want.)"
}

function Invoke-Status {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Host "not installed."; return }
    $info = Get-ScheduledTaskInfo -TaskName $taskName
    Write-Host "task:        $taskName"
    Write-Host "state:       $($task.State)"
    Write-Host "lastRun:     $($info.LastRunTime)"
    Write-Host "lastResult:  $($info.LastTaskResult)"
    Write-Host "nextRun:     $($info.NextRunTime)"
}

function Invoke-Run {
    # Foreground run (handy for a quick test). Ctrl-C to stop.
    $pyExe = Resolve-Python
    if ($Token) { $env:CC_SYNC_TOKEN = $Token }
    $args = @($serverPy, '--port', $Port)
    if ($Save) { $args += @('--save', $Save) }
    & $pyExe @args
}

switch ($Command) {
    'install'   { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'status'    { Invoke-Status }
    'run'       { Invoke-Run }
}
