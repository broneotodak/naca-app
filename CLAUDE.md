# CLAUDE.md — NACA App

Context for AI coding agents working on this repo. For human onboarding see `README.md`.

## What this is

The Flutter cross-platform operator console for the NACA fleet. Forked from `BroLanTodak/ccc` April 2026, extended with NACA-specific tabs (HQ, SITI, PROJ, MEM, SCHED, WSPC, CFG) on top of Lan's original terminal-streaming CHAT screen. Bundle ID renamed to `com.broneotodak.naca` in PR #5 (May 4 2026).

## Tier + workflow

- `project_registry.tier = tier_1` — NORMATIVE rules apply (see `claude-tools-kit/WORKFLOW.md`)
- Branch + PR + reviewer + admin merge for any non-cosmetic change
- Confirm with Neo before destructive ops (drop, force-push, mass DELETE)

## Tech stack

| Layer | Tech |
|---|---|
| App | Flutter / Dart 3.x |
| Key packages | `supabase_flutter`, `xterm.dart`, `audioplayers`, `web_socket_channel`, `flutter_secure_storage` |
| Backend | Node.js (vanilla HTTP + ws), SQLite for terminal sessions |
| Data | Supabase neo-brain (`xsunmervpyrplzarebva`) for fleet state |
| Auth | Bearer token, lock-screen PIN gate |

## Structure (current)

```
backend/server.js            ~2000 lines, 18+ /api/* endpoints
lib/
  main.dart                  Entry, lock screen
  screens/
    home_screen.dart           CHAT — Lan's original terminal
    dashboard_screen.dart      HQ — agent_heartbeats + Kuma summary
    naca_dashboard.dart        HQ extension — agent insights
    siti_screen.dart           SITI tab — WhatsApp surfaces
    projects_screen.dart       PROJ — project_registry + milestones
    memory_screen.dart         MEM — recent neo-brain rows
    schedule_screen.dart       SCHED — scheduled_actions + content_drafts
    workspace_screen.dart      WSPC — GAM Gateway proxy (Drive/Gmail)
    settings_screen.dart       CFG — config + connection tests
    lock_screen.dart           PIN gate
  services/                  api_service, ws_service, sound_service (+ stubs)
  widgets/                   terminal_card, blinking_cursor, scanline_overlay
  theme.dart
  config.dart                GITIGNORED — auth token + URLs
docs/
  iOS-DEPLOY.md              iPhone build + run + troubleshoot
ios/                         Open Runner.xcworkspace, NOT Runner.xcodeproj
```

## Backend endpoints (current)

```
/api/agents/heartbeats     /api/agents/commands       /api/agents/insights
/api/agents/locks          /api/agents/summary
/api/content-drafts        /api/content/schedule      /api/scheduled-actions
/api/costs                 /api/health                /api/kuma/status
/api/gam/files             /api/gam/health            /api/gam/orgs
/api/gam/shareddrives      /api/gam/users             /api/gam/users-quota
/api/media-batch           /api/sessions              /api/upload
                              + /api/siti/*  (proxy)
                              + /api/twin-reply
                              + /api/comments
```

Plus the WebSocket endpoint at `/` for streaming Claude Code terminal sessions.

## Hard rules

1. **Always open `ios/Runner.xcworkspace`, never `.xcodeproj`.** Pods linkage breaks otherwise.
2. **No plain HTTP on iOS.** App Transport Security blocks it. All backend calls go via the HTTPS proxy at `naca.neotodak.com`. PR #6 fixed three regressions of this.
3. **`lib/config.dart` and `backend/.env` are gitignored.** Use the `.example` files as templates. Never commit real tokens.
4. **Don't break Lan's terminal (CHAT tab).** Add NACA functionality as new tabs / screens, not by modifying `home_screen.dart`.
5. **Hacker-terminal aesthetic stays.** Green-on-black, scanlines, monospace. Don't introduce material-design surprises.
6. **After any `pubspec.yaml` change, run `cd ios && pod install`.** Skipping = "module not found" pain.
7. **Test on real iPhone before claiming iOS works.** Simulator isn't enough — sound playback paths and ATS rules differ.
8. **Web build still has to work.** Many calls have separate web vs native paths via conditional imports.

## Deploy methods

| Platform | Method |
|---|---|
| Web | `git push origin main` → GitHub Actions → Flutter web build → SCP to VPS → served from `naca.neotodak.com` |
| iOS | `flutter run -d <device-id>` or Xcode `Cmd+R`. See `docs/iOS-DEPLOY.md`. |
| macOS | `flutter run -d macos` |
| Android | `flutter build apk --release`, sideload |
| Backend | SSH VPS → `cd ~/naca-app/backend && git pull && pm2 restart naca-backend` |

## Common gotchas

- **Bundle ID mismatch** — old clones may still have `com.lantodak.lanCcc`. PR #5 (May 4 2026) renamed to `com.broneotodak.naca`. `git pull origin main` fixes.
- **Pods stale after dep change** — `cd ios && rm -rf Pods Podfile.lock && pod install --repo-update`.
- **Flutter "device not found"** — re-trust the iPhone, check `flutter devices`, sometimes need to re-plug USB.
- **Audio silent on iOS** — check `sound_service_stub.dart` is being conditionally imported (PR #5 fixed this regression).
- **SITI tab "not connected"** — PR #6 issue. Confirm calls go via `naca.neotodak.com` HTTPS proxy, not raw VPS IP.

## Pointers

- `claude-tools-kit/WORKFLOW.md` — canonical 5-phase work flow
- `claude-tools-kit/prompts/focus/NACA-APP.md` — operator focus prompt for CC sessions
- `docs/iOS-DEPLOY.md` — iPhone deploy walkthrough
- `README.md` — human-facing project overview
