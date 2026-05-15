# Surface 4 — SITI tab migration scope

**Status:** scoping only (no code). Companion to `siti-v2-endpoint-gap.md`.
**Date:** 2026-05-15
**Author:** NACA-App CC session (verified against live v1 + v2 state — no assumptions)

## TL;DR

The SITI tab is **not 3 buttons — it's 12 endpoints**, a full Siti ops console
built entirely on the dead `/api/siti/*` proxy (port 3800 v1 monolith, stopped).
Migration splits cleanly into 4 tiers. Two tiers are naca-app's lane and shippable
now; two tiers need siti-v2 work and at least one undecided design question.

## The 12 endpoints (verified from `lib/screens/siti_screen.dart`)

| # | Endpoint | Verb | What it does |
|---|---|---|---|
| 1 | `/api/health` | GET | Siti backend health |
| 2 | `/api/status` | GET | WA connection status + recent messages + settings blob |
| 3 | `/api/contacts` | GET | List WA contacts |
| 4 | `/api/contacts` | POST | Create a contact |
| 5 | `/api/contacts/:id` | POST | Update a contact |
| 6 | `/api/contacts/:id` | DELETE | Delete a contact |
| 7 | `/api/settings` | GET | Siti settings |
| 8 | `/api/settings` | POST | Update Siti settings |
| 9 | `/api/tools` | GET | Siti's tool list (was GEMINI_TOOLS) |
| 10 | `/api/messages` | GET | WA message history (paginated) |
| 11 | `/api/send` | POST | Send a WhatsApp message |
| 12 | `/api/whatsapp/{start,stop,fresh,sync}` | POST | WA lifecycle control |

## v2 backend reality (verified)

- **siti-ingest** (`broneotodak/siti`, `/home/openclaw/siti/siti-ingest/server.js`)
  owns the wacli child process (auto-restart supervisor). Its ONLY HTTP surface:
  `GET /healthz` + `POST /send` — bound to **`127.0.0.1:3501`**, `/send` gated by
  `SEND_API_TOKEN`. Code comment is explicit: *"No agent_commands processing."*
- **No v2 equivalent exists** for: status, contacts CRUD, settings, tools,
  messages, or WA lifecycle control. The v1 monolith held all of that
  (in-memory `state`, `contactCache`, `settings`).
- Tables confirmed present in neo-brain: `contacts` (18 cols), `wa_messages`
  (30 cols), `people` (24 cols), `agent_commands` (14 cols).
- **No `settings` / `siti_settings` / `nclaw_settings` table exists** — v2 Siti
  settings have no persistent home yet. Open question below.
- **Key fact:** naca-backend (`:3100`) and siti-ingest (`:3501`) run on the
  *same VPS* (`178.156.241.204`). naca-backend can reach `127.0.0.1:3501`
  directly — no SSH tunnel needed.

## Migration tiers

### Tier A — read surfaces, naca-app lane, shippable now (~2-3h)

| Endpoint | v2 source | Pattern |
|---|---|---|
| `/api/status` | `agent_heartbeats` + `wa_messages` | extend the existing `/api/siti-status` endpoint |
| `/api/health` | `agent_heartbeats` | fold into `/api/siti-status` |
| `/api/messages` | `wa_messages` table | new naca-backend `GET /api/wa-messages` (Supabase read, paginated) |
| `/api/contacts` GET | `contacts` table | new naca-backend `GET /api/contacts` (Supabase read) |

No cross-session dependency. Same pattern as Surfaces 1-3.

### Tier B — contact writes, naca-app lane, shippable now (~2h)

| Endpoint | Pattern |
|---|---|
| `/api/contacts` POST / `/api/contacts/:id` POST+DELETE | new naca-backend routes, service-role writes to `contacts` table — mirrors the Surface 2 `/api/people/:id` pattern exactly |

Caveat: confirm the `contacts` write shape + any CHECK constraints before wiring.

### Tier C — send message (~1-2h, small cross-check)

`/api/send` → siti-ingest already exposes `POST 127.0.0.1:3501/send`. naca-backend
adds a thin authenticated route that forwards to it with `SEND_API_TOKEN`
(token lives in vault / siti-ingest `.env`). No siti-v2 code change — the
endpoint exists. Just needs naca-backend to hold the token and proxy.

Alternative: the v2-native `agent_commands(to_agent='siti', command='send_whatsapp_*')`
→ outbound-bridge path. Heavier but more consistent with the daily-content
pipeline. **Decision needed** — see open questions.

### Tier D — WA lifecycle control + tools, siti-v2 lane, NOT shippable here

| Endpoint | Why it's blocked |
|---|---|
| `/api/whatsapp/start` `/stop` | siti-ingest has NO control surface — it only auto-supervises wacli. Needs new code IN `broneotodak/siti` (a control endpoint or an agent_commands consumer). siti-v2 lane. |
| `/api/whatsapp/fresh` (re-pair) | Hardest. Needs (a) control to kill+respawn wacli, AND (b) a way to surface the **QR code** back to the phone. Today the QR only renders in `pm2 logs`. Needs siti-ingest to capture the QR string and expose it (endpoint or a table the app polls). |
| `/api/whatsapp/sync` | Contact-sync routine — needs new siti-ingest code. |
| `/api/tools` GET | v1 derived from `GEMINI_TOOLS`; v2 tools are the `@naca/tools` registry. No simple table. Lowest priority — could show a static list or read `agent_registry`. |

## Lane split

- **naca-app session (this lane):** Tiers A + B + C — ~5-7h, no blockers.
- **siti-v2 session:** Tier D — control surface in `broneotodak/siti`, QR-return
  mechanism, contact-sync. Needs design + cross-session coordination.

## Open questions (decide before building)

1. **`/api/send` pattern** — thin proxy to `127.0.0.1:3501/send` (fast, exists)
   vs `agent_commands` + outbound-bridge (v2-consistent, heavier)? Recommend the
   proxy for Tier C now; revisit if outbound should unify later.
2. **Siti settings have no v2 home.** Before Tier B's settings part: decide
   where v2 Siti settings live — a new `siti_settings` table? siti-v2 config?
   Until decided, `/api/settings` (#7-8) stays out of scope.
3. **QR re-pair return path** — this is the same class as gap-spec open
   question #1 (inbound reply path). How does a QR string get from siti-ingest
   to the phone — a polled table row? A Realtime channel? Needs the siti-v2
   session + a design call.
4. **Is on-phone WA lifecycle control even wanted?** Re-pairing Siti's WhatsApp
   is a rare, high-risk operation. Tier D might be deliberately deferred — the
   `/healthz` + status badge already tell you IF something's wrong; the fix
   (re-pair) could stay an SSH-and-pm2 operator task rather than an app button.

## Recommended sequencing

1. **Tier A** — read surfaces. Highest value/effort ratio. SITI tab stops being
   fully dead; status + messages + contact list render.
2. **Tier B (contacts only)** — contact CRUD. Settings deferred pending Q2.
3. **Tier C** — send message via the `127.0.0.1:3501/send` proxy.
4. **Tier D** — hand to the siti-v2 session as its own scoped task. Possibly
   deferred entirely pending Q4.

After Tiers A-C, the SITI tab is a working read + contacts + send console.
Tier D (lifecycle control) is the only genuinely cross-session, design-gated part.

## What this doc is NOT

- Not a prescription — tier patterns are starting points.
- Not a PR — zero code changes.
- Tier D scoping is intentionally shallow; it deserves its own doc when the
  siti-v2 session picks it up.
