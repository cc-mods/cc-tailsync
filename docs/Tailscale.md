# Tailscale setup for cc-tailsync

cc-tailsync moves your CrossCode save between a Mac, a Windows PC, and an iPhone over your private
[Tailscale](https://tailscale.com) network. The defaults work with a basic tailnet, but a few
(free) Tailscale features make it noticeably nicer — stable names instead of IPs, HTTPS, and a
no-server way to push files. This page is the practical setup; everything here is on the **free
Personal plan** unless noted.

## TL;DR — recommended setup

1. **Enable MagicDNS** (admin console → **DNS** → *Enable MagicDNS*) so devices have stable names.
   Then use `http://<host>:8765` in `cc-sync.json` / `cc-endpoints.json` instead of `100.x` IPs.
2. **On the always-on save-server host (the Mac):** `tailscale serve --bg localhost:8765` to expose
   the save-server as **HTTPS** at `https://<host>.<tailnet>.ts.net` with auto-TLS, tailnet-only.
3. **Disable key expiry** on that host (admin console → **Machines** → ⋯ → *Disable key expiry*) so
   sync doesn't silently break in ~180 days.
4. Keep Tailscale **connected on the iPhone** (it's a system VPN profile); allow its notifications.

## 1. MagicDNS — stop hardcoding 100.x IPs

MagicDNS gives every device a name. Within the tailnet, bare names resolve, so the save-server is
just `http://<machine-name>:8765`, and the full form is `<machine-name>.<tailnet>.ts.net`.

- Enable: admin console → **DNS** → **Enable MagicDNS** (on by default for tailnets created after
  2022-10-20). Works on macOS, Windows, iOS, Linux.
- Use it in configs:

  ```json
  { "endpoints": { "windows": "http://small:8765", "mac": "http://my-mac:8765" } }
  ```

  and in `cc-sync.json` for the phone: `{ "url": "http://my-mac:8765" }`.
- Rename a machine: admin console → **Machines** → the machine → edit name.
- macOS gotcha: `dig`/`nslookup`/`host` bypass system DNS and won't resolve MagicDNS names; `ping`,
  `curl`, and apps work fine.

## 2. `tailscale serve` — HTTPS for the save-server

`save-server.py` listens on plain HTTP `:8765`. `tailscale serve` puts an HTTPS reverse proxy with a
free auto-renewing Let's Encrypt cert in front of it, reachable by name across the tailnet (never the
public internet).

Prereqs: MagicDNS (above) + HTTPS certs enabled (admin console → **DNS** → **Enable HTTPS**; the CLI
will prompt you the first time).

```bash
# On the save-server host — persists across reboots and tailscale up/down:
tailscale serve --bg localhost:8765
tailscale serve status          # show what's served
tailscale serve --bg localhost:8765 off   # stop
```

Now point clients at `https://<host>.<tailnet>.ts.net` (port 443, no `:8765`):

```json
{ "endpoints": { "mac": "https://my-mac.tailXXXX.ts.net" } }
```

The save-manager and the iOS client both speak HTTPS transparently. Platform note: port-proxying
works on the macOS **Standalone** and **App Store** apps and on Windows; only raw *directory* serving
is sandbox-restricted on macOS (we don't use that).

## 3. Taildrop — no-server file push (Mac ↔ Windows; manual on iOS)

Taildrop sends a file **directly** device-to-device, no save-server needed — handy for a one-off
"push this save to the other PC." Opt-in: admin console → **Settings** → **General** → **Send files**.

```bash
tailscale file cp ./cc.save small:           # push to the Windows PC (MagicDNS name)
tailscale file cp ./cc.save my-iphone:        # push to the phone
# on the receiver (desktop):
tailscale file get ~/Downloads/               # or: --loop to auto-receive
```

Limits: same Tailscale account only, both devices online, **iOS requires manual accept in the
Tailscale app** (the file lands in the app, then you share it to Files) — so for automated phone sync
the HTTP save-server (§2) is still the better path. Taildrop is in public alpha.

## 4. Keep the always-on host reachable

- **Disable key expiry** on the save-server host: admin console → **Machines** → host row → ⋯ →
  **Disable key expiry**. Otherwise its key expires (~180 days) and all sync silently stops. (Tagging
  a device also disables expiry, but tags remove the device's user identity and break Taildrop /
  user SSH — not recommended for personal machines.)
- If a key already expired, on that machine: `tailscale up --force-reauth` (interactive; never run it
  over a remote shell — it drops the connection).

## 5. Remote access / SSH between your machines

Two different things people mean by "SSH over Tailscale" — don't confuse them:

- **Tailscale SSH** (the built-in `tailscale set --ssh` feature, where *Tailscale* brokers the auth)
  can be **hosted only on Linux and the macOS open-source `tailscaled` build**. **Windows cannot be a
  Tailscale-SSH host**, and the macOS App-Store/Standalone apps can't either.
- **Plain SSH / RDP to a machine, carried over Tailscale** — this works for **every** platform,
  because Tailscale is just the (encrypted) network path. This is what people use for "full remote
  control": **RDP** to Windows (port 3389), or each OS's **normal SSH server**.

So you absolutely *can* SSH into your Windows box over Tailscale — you just enable **Windows OpenSSH
Server** (it's an optional Windows feature), which is independent of Tailscale SSH:

```powershell
# One-time, in an Administrator PowerShell on the Windows box:
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic
```

Then from the Mac: `ssh you@small` (MagicDNS name) over the tailnet. Set up key auth for unattended
use. This is exactly what the **save-manager `ssh://` endpoint** uses to drop a save onto Windows
with no save-server — see [`save-manager.md`](save-manager.md). For full GUI control instead, enable
**Remote Desktop** on Windows and connect to `small:3389` over Tailscale.

On macOS/Linux you can use the real Tailscale SSH feature where supported:

```bash
tailscale set --ssh          # on a Linux / tailscaled-macOS host
ssh you@<host>               # from any device, by MagicDNS name
```

…plus an `ssh` rule in the tailnet policy (admin console → **Access controls**). cc-tailsync never
*requires* SSH; it's an optional serverless transport for desktop↔desktop save moves.

## 6. Locking it down (optional)

By default every device can reach every port on the tailnet. To restrict clients to just the
save-server port, add an ACL in admin console → **Access controls**. For a personal tailnet without
tagging your devices:

```jsonc
{
  "acls": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:member:443"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:member:8765"] }
  ]
}
```

`tailscale lock` (tailnet lock) is a stronger control-plane protection but is a **paid-tier** feature
and overkill for three devices.

## iOS notes

- iOS suspends background apps and has **no Tailscale CLI**, so the phone can't run automated sync
  jobs. cc-ios's design fits this: it pulls a newer save at **app launch** (foreground) and pushes on
  every in-game save — exactly when Tailscale is active.
- Keep the Tailscale VPN **on** (persistent profile) and **allow notifications** (that's how iOS warns
  you about key expiry). Requires iOS 15+.
- Taildrop to the phone needs you to open the Tailscale app and accept the file.

---

*Feature availability and commands per the official Tailscale docs (`tailscale.com/kb`,
`/docs/features/*`). Free Personal plan unless a line says otherwise.*
