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
| Refresh / Start / Stop / Restart | `safecorectl status / start / stop / restart` |

The app never saves the access key itself; safecore-setup stores it in the System Keychain. The app passes it through a private 0600 temp file that the helper deletes right after reading. It is hidden in the output and in `/Library/Logs/SafeCore/installer.log`.

## Layout

- `installer-app/`: SwiftUI app (universal, macOS 13+)
- `tools/make-art.swift`: draws the app icon and DMG background from `brand/safespace-mark.png`
- `build-dmg.sh`: the 7-step build
- `signing/`: sign, notarize and staple script for the signing Mac
