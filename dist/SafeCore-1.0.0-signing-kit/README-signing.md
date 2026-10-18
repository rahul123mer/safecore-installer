# Signing the SafeCore DMG

Run these steps on the Mac that holds the SafeSpace Apple Developer certificates.
It needs the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

## One-time setup

1. **Install the certificates.** In Keychain Access, check that both of these are present, each with its private key:
   - `Developer ID Application: <SafeSpace name> (<TEAMID>)`
   - `Developer ID Installer: <SafeSpace name> (<TEAMID>)`

   If they're missing, create them in Xcode under Settings › Accounts › Manage Certificates, or at developer.apple.com › Certificates.
   Only the Account Holder can create Developer ID certificates.

   To list the exact names:
   ```
   security find-identity -v
   ```

2. **Create an app-specific password.** Go to account.apple.com › Sign-In and Security › App-Specific Passwords and create one named "SafeCore notary".
   Notarization does not accept the normal Apple Account password.

3. **Save the notary credentials in the Keychain.** It asks for the app-specific password from step 2:
   ```
   xcrun notarytool store-credentials safecore-notary --apple-id support@safespaceglobal.ai --team-id <TEAMID>
   ```

## Every release

Copy the `SafeCore-<version>-signing-kit` folder to this Mac, then run:

```
cd ~/Desktop/SafeCore-1.0.0-signing-kit
./sign-and-notarize.sh \
  --app-id "Developer ID Application: <SafeSpace name> (<TEAMID>)" \
  --installer-id "Developer ID Installer: <SafeSpace name> (<TEAMID>)" \
  --notary-profile safecore-notary
```

The result is `SafeCore-<version>.dmg` in the same folder. It is signed, notarized and stapled, and ready to send to boxes.

If the script stops, it says exactly why. The most likely cause is that the developer's SafeCore binaries aren't signed for notarization. `package-report.txt` lists each binary.
