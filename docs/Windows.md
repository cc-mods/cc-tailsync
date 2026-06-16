# cc-tailsync save-server on Windows

Run the save hub on a Windows PC so your iPhone (and other PCs) can sync CrossCode saves over
Tailscale. This is the Windows equivalent of the macOS launchd setup, using a **Scheduled Task**.

## Prerequisites

- **Python 3** on `PATH` (install from [python.org](https://www.python.org/) and tick "Add
  python.exe to PATH"). `python` or the `py` launcher both work.
- CrossCode installed. The default save is `%LOCALAPPDATA%\CrossCode\cc.save`
  (Steam). *(Microsoft Store builds keep it under
  `%LOCALAPPDATA%\Packages\…CrossCodePC…\LocalCache\Local\CrossCode\cc.save` — pass that with
  `-Save` if needed.)*
- [Tailscale for Windows](https://tailscale.com/download/windows) installed and up.

## Run it once (foreground)

From PowerShell, in this repo:

```powershell
servers\windows\save-server.ps1 run                 # binds 0.0.0.0:8765, mirrors the default save
servers\windows\save-server.ps1 run -Port 9000
servers\windows\save-server.ps1 run -Save "D:\path\to\cc.save"
servers\windows\save-server.ps1 run -Token secret   # require Authorization: Bearer secret
```

Or just run the cross-platform server directly: `python servers\save-server.py --port 8765`.

## Run it persistently (Scheduled Task)

```powershell
servers\windows\save-server.ps1 install             # install + start; runs at logon, restarts on failure
servers\windows\save-server.ps1 install -Port 9000
servers\windows\save-server.ps1 install -Token secret
servers\windows\save-server.ps1 status              # task state + last run/result
servers\windows\save-server.ps1 uninstall           # stop + remove
```

`install` copies `save-server.py` into `%USERPROFILE%\.cc-tailsync\` and registers a task named
`cc-tailsync-save-server` that runs it hidden, **at logon**, with no time limit and auto-restart on
failure. It runs as the current user (no admin required). **Re-run `install` after editing the
server.**

> **PowerShell execution policy:** if scripts are blocked, run from an elevated-or-normal PowerShell
> with `-ExecutionPolicy Bypass`, e.g.
> `powershell -ExecutionPolicy Bypass -File servers\windows\save-server.ps1 install`. The installed
> task already runs with `-ExecutionPolicy Bypass`.

> **"Always-on" caveat:** the task triggers **at logon**, so it starts once you sign in and keeps
> running (restarting on crash). For a headless box that should serve before anyone logs in, recreate
> the task to run as `SYSTEM` with a startup trigger (requires admin) — overkill for a personal hub.

## Make it reachable from the phone

Find this PC's Tailscale IP:

```powershell
tailscale ip -4        # e.g. 100.x.y.z
```

Point the app at it via `tools/setup-sync.sh --ip 100.x.y.z` from a Mac (USB), or by dropping a
`cc-sync.json` into the app via the Files app (see [`iOS.md`](iOS.md)):

```json
{ "url": "http://100.x.y.z:8765", "token": "optional-bearer" }
```

With **MagicDNS** you can use the hostname: `{ "url": "http://my-pc:8765" }`.

## Firewall

The first time the server binds a port, Windows may prompt to allow Python through the firewall.
Allow it on **Private** networks. Tailnet traffic arrives on the Tailscale interface; access is still
gated by your **tailnet ACLs**.
