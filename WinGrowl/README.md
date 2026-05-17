# WinGrowl

A modern GNTP listener that bridges Growl-protocol notifications to native Windows 10/11 toast notifications.

[Growl for Windows](https://www.growlforwindows.com/) was last released in 2011 and no longer runs cleanly on modern Windows. WinGrowl is a clean-room re-implementation: same on-the-wire protocol so existing Growl clients (Firestorm, Pidgin, Foobar2000, anything that speaks GNTP/1.0) work without modification, but the receiving end is a small .NET 8 tray app that renders notifications through the native Windows toast system instead of GfW's custom display layer.

## Status

Working:

- GNTP/1.0 message parsing — REGISTER, NOTIFY, SUBSCRIBE
- Tolerant parsing for real-world clients (e.g. Firestorm sends `Notifications-Count` without inline type blocks; accepted, types auto-register on first NOTIFY)
- Native Windows toast rendering via `Microsoft.Toolkit.Uwp.Notifications` — icons, app attribution, priority-based expiration
- System tray UI: status indicator, list of registered apps, quit
- Optional password-protected listening (HMAC key hash per the GNTP spec)
- Optional network listen (default: loopback only)

Not yet:

- Encryption beyond `NONE` (AES / DES message body decryption is stubbed)
- Per-notification type configuration UI (currently auto-enable on first arrival; toggle is in code only)
- GNTP CALLBACK / subscription delivery

## Install

### Via installer (recommended)

Download `WinGrowl-<version>-Setup.exe` from the [Releases page](https://github.com/anne-skydancer/WinGrowl/releases) and run it. Installs per-user (no admin) or per-machine (your choice at the UAC prompt). Includes a Start Menu shortcut with the `AppUserModelID` that Windows requires for unpackaged apps to surface toast notifications, and an optional "start on sign-in" checkbox.

### Portable

Download `WinGrowl.exe` (self-contained single file, ~94 MB — bundles the .NET 8 runtime so no separate install is needed) and run it from anywhere. Toast notifications may be less reliable in portable mode without the AUMID registration the installer provides; if you don't see toasts, install via the installer.

## Configure your client

Point any GNTP-speaking app at `127.0.0.1:23053` (the Growl default port — WinGrowl listens there on the loopback interface).

In Firestorm: **Preferences → Notifications → Growl** — pick which notification types route to Growl. WinGrowl auto-registers them on first arrival; no manual sender-side registration step needed.

For other clients, consult their Growl integration docs; the wire protocol is the same as GfW so any existing Growl configuration should "just work."

## Configuration

WinGrowl reads `%APPDATA%\WinGrowl\config.json` on startup. Defaults are sensible; the file only needs to exist if you want to change something:

```json
{
  "ListenAddress": "127.0.0.1",
  "Port": 23053,
  "Password": null,
  "AllowNetworkClients": false,
  "ShowToasts": true,
  "PlaySound": true
}
```

- `AllowNetworkClients: true` binds `0.0.0.0` instead of loopback — lets other machines on your network send notifications. Pair with `Password` for HMAC auth.
- Diagnostic log: `%LOCALAPPDATA%\WinGrowl\wingrowl.log`.

## Build from source

Requirements: .NET 8 SDK, Windows 10 build 19041 (May 2020 update) or newer.

```powershell
dotnet build WinGrowl.sln                  # debug build into bin/Debug
tools\publish.ps1                          # self-contained single-file release into publish\win-x64
tools\build-installer.ps1                  # publish + Inno Setup installer (requires Inno Setup 6+)
```

Inno Setup is the only external dependency for building the installer. Download from https://jrsoftware.org/isdl.php (one-time).

## Architecture

Two projects:

- `WinGrowl.Core` — protocol-only. Parses GNTP, manages an in-memory application registry, no UI dependencies. Reusable as a library in any .NET host.
- `WinGrowl.App` — Windows Forms host. Owns the TCP listener startup, the tray icon, and the `ToastBridge` that translates GNTP notifications into `ToastContentBuilder` calls.

## License

GPL-3.0-or-later. See `LICENSE` for the full text.
