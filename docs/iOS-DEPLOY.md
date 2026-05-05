# iOS Deploy Guide

How to build and run NACA on a physical iPhone (test device or daily driver). Covers Xcode-based and Flutter-CLI-based workflows. Last verified 2026-05-05 against the Apr-22-forked-from-CCC bundle-ID rename in PR #5.

---

## Quick reference

| What | Value |
|---|---|
| Bundle ID | `com.broneotodak.naca` |
| Test target bundle ID | `com.broneotodak.naca.RunnerTests` |
| Apple Developer Team | `YG4N678CT6` (Neo's personal team) |
| Display name | `NACA` |
| iOS deployment target | `13.0` |
| iOS Xcode workspace | `ios/Runner.xcworkspace` (open this, NOT `Runner.xcodeproj`) |

---

## Prerequisites (one-time per Mac)

1. **Xcode** (latest from App Store) + Command Line Tools — `xcode-select --install`
2. **Flutter SDK** (`flutter --version` should print 3.x). If installing fresh, follow [flutter.dev/docs/get-started/install/macos](https://docs.flutter.dev/get-started/install/macos).
3. **CocoaPods** — `sudo gem install cocoapods` (or `brew install cocoapods`).
4. **Apple ID with team membership** — sign into Xcode (`Xcode → Settings → Accounts`). Confirm your account shows team `YG4N678CT6`.
5. **A real iPhone** — simulators won't run NACA properly because the SITI tab and HQ panel hit the live backend over HTTPS, and audio playback paths are different on simulator.

---

## First-time clone setup

```bash
git clone https://github.com/broneotodak/naca-app.git
cd naca-app
flutter pub get
cd ios && pod install && cd ..
cp lib/config.dart.example lib/config.dart
# Edit lib/config.dart — set apiBaseUrl, wsUrl, authToken to match your VPS / proxy.
```

> **Don't commit `lib/config.dart`.** It's gitignored. Same for `backend/.env`.

---

## Connecting an iPhone

**First connection (USB only):**

1. Plug in via USB-C / Lightning.
2. On the iPhone, tap **Trust** when prompted.
3. Enable Developer Mode: `Settings → Privacy & Security → Developer Mode → On`. Phone reboots once.
4. Verify Mac sees the device:
   ```bash
   flutter devices
   ```
   You should see a line like:
   ```
   N16 (mobile) • 00008140-000A14A8213B001C • ios • iOS 26.x
   ```

**After first install — wireless deploy works:**

Once you've installed at least once via USB, Xcode + Flutter can deploy wirelessly as long as both Mac and iPhone are on the same Wi-Fi. `flutter devices` will show the device with `(wireless)` suffix.

---

## Identifying which device is which

If multiple iPhones are connected (e.g. testing on N16 while N17 is charging on the same Mac):

```bash
flutter devices
```

Each device has a unique ID. Use it in `flutter run -d <device-id>` to target a specific one. Examples:

```bash
flutter run -d 00008140-000A14A8213B001C   # N16
flutter run -d 00008150-001E1DE436A1401C   # N17
flutter run -d N16                         # name match also works
```

---

## Build & run

### Path A — Flutter CLI (fastest iteration, hot reload)

```bash
flutter run -d <device-id>
```

- Press `r` for hot reload, `R` for hot restart, `q` to quit.
- Connects to the device, builds, installs, attaches. ~30-60s first build.
- Use this for code edits + visual tweaks.

### Path B — Xcode (when you need to debug native iOS, change signing, or archive for TestFlight)

1. Open the workspace (NOT the project file):
   ```bash
   open ios/Runner.xcworkspace
   ```
2. In the toolbar device picker, select your iPhone.
3. Make sure team is set: **Runner → Signing & Capabilities → Team = YG4N678CT6**. If it shows "None" or a different team, fix it.
4. Press **▶ Run** (`Cmd+R`).

### Path C — Build IPA for distribution

```bash
flutter build ipa --release
# Artifact: build/ios/ipa/naca-app.ipa
```

For TestFlight: open `Xcode → Window → Organizer`, drag the IPA, hit Distribute.

---

## Hard rules — DO NOT violate

1. **Always open `Runner.xcworkspace`, never `Runner.xcodeproj`.** The workspace includes the Pods integration. Opening the bare project loses CocoaPods linkage and you'll get cryptic build failures.
2. **Never hardcode `http://<ip>:<port>` in Dart for iOS calls.** iOS App Transport Security blocks plain HTTP. All backend calls must go through the HTTPS proxy at `https://naca.neotodak.com/api/...` — see PR #6 for the fix history.
3. **Never commit `lib/config.dart`.** It contains the auth token. Use `lib/config.dart.example` as the template.
4. **After any `pubspec.yaml` change, re-run** `cd ios && pod install`. Skipping this is the #1 source of "module not found" errors.
5. **After `flutter clean`, always run `flutter pub get` before `pod install`.** Clean wipes `ios/Flutter/Generated.xcconfig`; pod install requires it. The canonical iOS rebuild sequence is `flutter clean → flutter pub get → cd ios && pod install && cd .. → flutter run`.
6. **If you change the Bundle ID for any reason, also update** `Runner/Info.plist` + the test target — both must match.

---

## Troubleshooting

**"Untrusted Developer" pops up the first time you run NACA on a device.**
On the iPhone: `Settings → General → VPN & Device Management → <Your Apple ID> → Trust`. Then re-launch.

**`flutter run` fails with "Provisioning profile doesn't include the currently selected device."**
Open Xcode, let it auto-select a profile, or manually create one for `com.broneotodak.naca` with your device's UDID added. Apple Developer portal → Certificates, IDs & Profiles.

**`pod install` fails with `Generated.xcconfig must exist`** (very common after `flutter clean`).
`flutter clean` deletes `ios/Flutter/Generated.xcconfig`, but `pod install` requires it. Always run `flutter pub get` between them — pub get re-creates the file. Correct order:
```bash
flutter clean        # wipes build artifacts, Generated.xcconfig
flutter pub get      # restores Generated.xcconfig + pulls Dart deps
cd ios && pod install && cd ..
flutter run -d <device-id>
```

**`pod install` builds stale or fails with module errors after dependency changes.**
Wipe Pods + Podfile.lock and re-resolve from a clean Flutter state:
```bash
flutter clean
flutter pub get
cd ios && rm -rf Pods Podfile.lock && pod install --repo-update && cd ..
```

**"No such module 'audioplayers_darwin'" or similar.**
Same fix as above. The `audioplayers` plugin came in via PR #5; an out-of-date Podfile.lock from before that PR will be missing the iOS module entry.

**App installs but SITI tab shows "not connected" / endpoints time out.**
ATS is blocking. Confirm the call is going through `naca.neotodak.com` (HTTPS proxy), not a raw HTTP IP. Check `lib/config.dart` and `lib/services/*.dart` for any leaking `http://178.156.241.204:*` strings — should all be `https://naca.neotodak.com/...`. PR #6 fixed three such places; if a regression slipped in, grep is your friend.

**Device shows in `flutter devices` but Xcode doesn't see it.**
Quit Xcode completely, run `xcrun devicectl list devices` — if the device appears there but not in Xcode, restart Xcode. If it still doesn't appear, re-plug USB and re-tap "Trust" on the phone.

**Migration note for stale clones:** If you cloned naca-app before 2026-05-04, your local `main` may have old `com.lantodak.lanCcc` bundle ID. Pull latest (`git pull origin main`) to get PR #5's rename + display name fix.

---

## Verification checklist after a fresh install

- [ ] App icon on home screen reads **NACA** (not CCC, not Lan CCC).
- [ ] Lock screen accepts the PIN and tap sounds play.
- [ ] HQ tab loads agent_heartbeats — at least one row shows `live`.
- [ ] SITI tab top bar shows `WA: connected · NUM: ...`.
- [ ] CHAT screen detects installed SSH clients (Termius / Blink / Prompt) when you tap a host.
- [ ] No red error banners.

If all six pass, the install is good.

---

## Pointers

- Repo root: `~/Projects/naca-app`
- Architecture / screens / endpoints reference: see `docs/ARCHITECTURE.md` *(coming next)*
- API endpoint reference: see `docs/API.md` *(coming next)*
- For CC sessions working on this repo: paste `claude-tools-kit/prompts/focus/NACA-APP.md` first.
- Backend is a Node.js server on the Hetzner VPS, port 3100, fronted by Nginx at `https://naca.neotodak.com`.
