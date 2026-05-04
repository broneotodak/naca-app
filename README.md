# NACA — Neo's Agentic Centre Application

The Flutter cross-platform operator console for the [NACA](https://github.com/broneotodak) fleet — Neo Todak's personal agentic infrastructure. iOS / macOS / Android / Web from one codebase.

```
███╗   ██╗ █████╗  ██████╗ █████╗
████╗  ██║██╔══██╗██╔════╝██╔══██╗
██╔██╗ ██║███████║██║     ███████║
██║╚██╗██║██╔══██║██║     ██╔══██║
██║ ╚████║██║  ██║╚██████╗██║  ██║
╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝
```

> Forked from [BroLanTodak/ccc](https://github.com/BroLanTodak/ccc) (Claude Command Center) in April 2026 and extended with NACA-specific surfaces. Lan's terminal-streaming functionality is preserved on the **CHAT** tab.

---

## What it is

A single-operator command surface for a fleet of always-on AI agents. NACA reads from the shared `neo-brain` Supabase project (`xsunmervpyrplzarebva`) — agent heartbeats, command queues, scheduled actions, content drafts, memory, project registry, knowledge graph — and proxies into Siti (the WhatsApp gateway agent) and the GAM Workspace bridge.

**Not** a server that drives the fleet. The actual agents (siti, planner, dev-agent, reviewer, verifier, dispatcher, supervisor, twin-ingest, neo-twin, etc.) run on Hetzner VPSes, NAS Docker, CLAW MBA, and Twin VPS. NACA is the read-mostly window into that work.

---

## Surfaces

10 screens, accessible via a hacker-terminal-style tab bar:

| Tab | Code | Reads / Writes |
|---|---|---|
| **HQ** | `dashboard_screen.dart` + `naca_dashboard.dart` | `agent_heartbeats`, `agent_commands`, Kuma status |
| **CHAT** | `home_screen.dart` | Lan's original CCC terminal — Claude Code sessions over WebSocket |
| **SITI** | `siti_screen.dart` | Proxies to Siti's WhatsApp endpoints (`/api/siti/*`) |
| **PROJ** | `projects_screen.dart` | `project_registry`, `project_milestones` |
| **MEM** | `memory_screen.dart` | `memories` table — recent rows, scope-tag filters |
| **SCHED** | `schedule_screen.dart` | `scheduled_actions`, `content_drafts` |
| **WSPC** | `workspace_screen.dart` | GAM Gateway → Drive / Gmail (`/api/gam/*`) |
| **CFG** | `settings_screen.dart` | App config, connection tests |
| **LOCK** | `lock_screen.dart` | PIN gate before any tab |

---

## Live deployment

| Where | What |
|---|---|
| **Web** | https://naca.neotodak.com (auto-deploy on push to `main` via GitHub Actions) |
| **iOS** | Sideloaded via Xcode / `flutter run` to physical iPhone (Neo's N16 + N17). See [`docs/iOS-DEPLOY.md`](docs/iOS-DEPLOY.md). |
| **macOS** | Local desktop builds via `flutter run -d macos` |
| **Android** | Tested but not in regular use |
| **Backend** | Node.js on Hetzner VPS (`178.156.241.204:3100`), fronted by Nginx + HTTPS at `naca.neotodak.com` |

Bundle ID: `com.broneotodak.naca` · Apple Developer Team: `YG4N678CT6`

---

## Tech stack

| Layer | Tech |
|---|---|
| App | Flutter (Dart 3.x), `supabase_flutter`, `xterm.dart`, `audioplayers`, `web_socket_channel` |
| Backend | Node.js (vanilla HTTP + ws), `better-sqlite3` for terminal sessions, REST proxies to Siti / GAM / Kuma |
| Data | Supabase PostgreSQL — `neo-brain` for fleet state, `legacy` for archived rows |
| Auth | Bearer token (CCC pattern) — gated by lock screen PIN in-app |
| Streaming | WebSocket for the CHAT terminal |

---

## Repo layout

```
backend/         Node.js server — REST endpoints + WebSocket terminal
  server.js        18+ /api/* endpoints (agents, kuma, gam, sessions, ...)
  session-manager  Claude Code CLI session lifecycle
  db.js            SQLite for session persistence
lib/             Flutter app
  main.dart      Entry point, lock screen gate
  screens/       10 tab screens
  services/      api_service, ws_service, sound_service (with platform stubs)
  widgets/       Terminal card, blinking cursor, scanline overlay, etc.
  theme.dart     Colors, scanlines, glow
  config.dart    GITIGNORED — auth token + URLs (copy from config.dart.example)
docs/            Project documentation
  iOS-DEPLOY.md  iPhone build + run + troubleshoot
ios/             Xcode project — open Runner.xcworkspace
android/  macos/  web/  windows/   Standard Flutter scaffolding
```

---

## Quick start

```bash
# Clone + install
git clone https://github.com/broneotodak/naca-app.git
cd naca-app
flutter pub get
cd ios && pod install && cd ..

# Configure (one-time)
cp lib/config.dart.example lib/config.dart
# Edit lib/config.dart — apiBaseUrl + wsUrl + authToken

# Run
flutter run -d chrome              # web (no auth gate)
flutter run -d macos               # local desktop
flutter run -d <iphone-device-id>  # iOS — see docs/iOS-DEPLOY.md
```

For backend setup, see `backend/.env.example` and run `node backend/server.js` (or the production `pm2 start` flow on the VPS).

---

## Documentation

- [`docs/iOS-DEPLOY.md`](docs/iOS-DEPLOY.md) — building & deploying to iPhone
- [`CLAUDE.md`](CLAUDE.md) — context for AI coding agents working on this repo

Coming:
- `docs/ARCHITECTURE.md` — full screens × endpoints × data flow
- `docs/API.md` — backend endpoint reference

---

## Project context

NACA-app is part of the broader **NACA ecosystem** — see [`claude-tools-kit/prompts/focus/NACA-APP.md`](https://github.com/broneotodak/claude-tools-kit/blob/main/prompts/focus/NACA-APP.md) for the operator-context overview.

Tier: `tier_1` in `project_registry` (fleet-critical, NORMATIVE workflow rules apply per [`claude-tools-kit/WORKFLOW.md`](https://github.com/broneotodak/claude-tools-kit/blob/main/WORKFLOW.md)).

---

## License

MIT — same as the upstream CCC project it forked from.
