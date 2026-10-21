# SafeCore installer

Turns the developer's `SafeCore-x.y.z.zip` into a branded, universal macOS DMG. Operators install, enrol and control a SafeCore box with no Terminal commands.

## Build (this Mac)

```
./build-dmg.sh ~/Downloads/SafeCore-1.0.0.zip
```

Options: `--endpoint URL` and `--domain NAME` (pre-fill the form), `--version X.Y.Z`.

Output in `dist/`:
- `SafeCore-1.0.0-unsigned.dmg`: for testing on this Mac
- `SafeCore-1.0.0-signing-kit/`: copy to the signing Mac (see `signing/README-signing.md`)
- `package-report.txt`: architectures and signatures of every binary in the developer's package

## Sign (signing Mac)

See [signing/README-signing.md](signing/README-signing.md).

## What the app runs

All commands run as root through one macOS administrator prompt, via `installer-app/Resources/safecore-helper.sh`:

| Button | Command |
|---|---|
| Install & Enrol | `installer -pkg SafeCore.pkg -target /`, then `safecore-setup --non-interactive --user <console user>` with the five answers in its `SAFECORE_*` variables |
| Upgrade (box already enrolled) | `installer -pkg …` only. The package's own postinstall keeps the enrolment and brings the services back |
| Start / Stop / Restart | `safecorectl start / stop / restart` |
| Auto-restart on / off | installs `ai.safespaceglobal.safecore-watchdog` (see below) |

## Control panel

Opening SafeCore from Applications on an enrolled box shows SafeCore Control: every service (database,
WebSocket relay `safecored`, and the services `run_all_bins.sh` started) with Online / Starting / Offline,
PID, uptime and its recent log. It refreshes every 5 seconds without a password; only Start, Stop,
Restart and the auto-restart switch ask for one. Only one SafeCore window runs at a time.

## Auto-restart

`installer-app/Resources/safecore-watchdog.sh` runs as root every 30 s. It never undoes a manual stop
(`safecorectl stop` unloads the SafeCore daemons, and the watchdog only acts while they are loaded).

- A service from `status.json` gone for two checks: `safecorectl restart` (the package has no
  single-service restart). The enrolment, Keychain key and URL are reused; nothing is re-entered.
- `safecored` (WebSocket) process dies: launchd already restarts it (KeepAlive). If it is alive but
  `safecored-cli status` fails three checks in a row: `launchctl kickstart -k system/ai.safecore.safecored`.
- At most 3 full restarts per hour, then it pauses until SafeCore is started again.

Log: `/Library/Logs/SafeCore/watchdog.log`. State for the app: `/Library/Application Support/SafeCore/watchdog-status.json`.

The app never saves the access key itself; safecore-setup stores it in the System Keychain. The app passes it through a private 0600 temp file that the helper deletes right after reading. It is hidden in the output and in `/Library/Logs/SafeCore/installer.log`.

## Layout

- `installer-app/`: SwiftUI app (universal, macOS 13+)
- `tools/make-art.swift`: draws the app icon and DMG background from `brand/safespace-mark.png`
- `build-dmg.sh`: the 7-step build
- `signing/`: sign, notarize and staple script for the signing Mac
