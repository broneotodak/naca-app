# NACA App ↔ Siti v2 endpoint gap — audit & migration menu

**Status:** audit only (no code changes). Coordination doc for the in-flight Siti v2 rebuild session.
**Date:** 2026-05-13
**Reporter:** siti-v2-cc session (read-only audit)

## TL;DR

- NACA App routes Siti-related calls through `naca-backend` → proxy `/api/siti/*` → `localhost:3800` on the Siti VPS.
- Port 3800 has **no listener**. The v1 Siti monolith (pm2 process `siti`) is intentionally stopped (per the "Never unpause legacy `siti` pm2 process" rule).
- **5 NACA App surfaces are silently HTTP 502** right now. Sweep test results below.
- v2 architecture has settled on tables-only outbound (agent_commands + outbound-bridge), so the gap is **not "port the HTTP endpoints"** but **"redesign the NACA App data path for v2"**.
- `xiaozhi-dog` is also affected — same `/api/voice-chat` dependency on port 3800.

## What's broken (verified 2026-05-13 14:30 MYT)

Sweep test from local Mac through `naca.neotodak.com`:

```
POST /api/siti/api/voice-chat          → 502
GET  /api/siti/api/people?limit=1      → 502
GET  /api/siti/api/media?limit=1       → 502
POST /api/siti/api/whatsapp/start      → 502
GET  /api/siti/api/health              → 502
GET  /api/siti/api/status              → 502
```

`ss -tlnp` on Siti VPS confirms: no process listening on 3800.

## Per-surface impact

| NACA App surface | File:line | Endpoint hit | Impact |
|---|---|---|---|
| **SITI tab (whole tab)** | `lib/screens/siti_screen.dart:24` | `_sitiBase = ${apiBaseUrl}/api/siti` | Tab loads, every action fails |
| **HQ → SITI service row** | `lib/screens/dashboard_screen.dart:294, 345` | `/api/siti/api/status`, `/api/siti/api/health` | Service shows DOWN even when Siti is fine |
| **CFG → Test SITI connection** | `lib/screens/settings_screen.dart:79` | `/api/siti/api/health` | Settings panel shows SITI offline |
| **MEM → People sub-tab (edit/delete)** | `lib/screens/memory_screen.dart:1357, 1377` | `PATCH/DELETE /api/siti/api/people/:id` | Tap edit → save fails; delete fails |
| **MEM → Media sub-tab (listing/search)** | `lib/screens/memory_screen.dart:1434` | `GET /api/siti/api/media` | Tab empty; semantic search returns nothing |

What's NOT broken (works via direct Supabase or other naca-backend native endpoints):
- HQ heartbeats panel, agent insights, costs, kuma status
- MEM → Memories sub-tab (direct `supabase.from('memories')`)
- MEM → individual `/api/media/:id/blob` byte fetches (naca-backend has its own MinIO bridge)
- PROJ (direct Supabase reads)
- SCHED (naca-backend native `/api/scheduled-actions`, `/api/content-drafts`)
- CHAT terminal (WebSocket + `/api/sessions/*`)
- WSPC (naca-backend `/api/gam/*` via SSH-TDCC)

## Root cause

`backend/server.js` line 1425 proxies any path starting with `/api/siti/` to `localhost:3800`. The v1 monolith `~/siti/server.js` (which served those endpoints) is intentionally stopped (memory: `feedback_naca_siti_no_assumptions`, MEMORY.md note "Never unpause legacy `siti` pm2 process — intentionally stopped").

## v2 architectural pattern (observed)

From memories `8279b9b8` (May 9 — outbound-bridge for agent_commands) and the two in-flight PRs:

```
Outbound (NACA → Siti action):
  INSERT agent_commands(to_agent='siti', command='send_whatsapp_*', payload={...})
  → siti-router/outbound-bridge polls every Ns
  → SendModule (@naca/core/send) handles transport selection
  → wacli (siti repo) delivers to WhatsApp
  → updates agent_commands.status='done' (or 'failed')

Inbound (Siti reaches NACA):
  Real-time: subscribe to neo-brain tables via Supabase Realtime
  Polling: read latest rows on tab focus

Conversational (NACA → Siti → NACA):
  Hypothetical pattern: INSERT agent_intents(source='naca_chat', raw_text='...')
  → siti-router classifies → specialist handles
  → result row inserted somewhere (TBD — voice_responses? content_drafts? agent_intents.reply_text?)
  → NACA subscribes via Realtime, surfaces in UI
```

## Migration menu (per surface)

Three patterns to choose from, ranked by complexity:

- **(a) New native endpoint in naca-backend** — simplest. naca-backend already has service-role to neo-brain. Add a route per surface. No cross-repo coordination.
- **(b) `agent_commands/intents` queue + Realtime subscription** — most v2-native, async-first. Heavier UI work in Flutter (state machines for "in flight" / "completed" / "failed").
- **(c) Direct Dart Supabase reads/writes** where the data already lives in a table. Zero backend work; some operations (mutations needing service-role) can't use this.

| Surface | Endpoint | Suggested pattern | Notes |
|---|---|---|---|
| SITI status badge | `/api/siti/api/status` | (a) `/api/siti-status` in naca-backend | Aggregate from `agent_heartbeats` rows for `siti-ingest` + `siti-router` |
| SITI tab health probe | `/api/siti/api/health` | (a) Same as above | |
| CFG test SITI | `/api/siti/api/health` | (a) Same as above | |
| MEM Media listing | `/api/siti/api/media` | (c) Direct Supabase via Dart, calling RPC `match_media` | RPC + table already exist; siti's old impl was thin |
| MEM People edit | `PATCH /api/siti/api/people/:id` | (a) `PATCH /api/people/:id` in naca-backend | Service-role write to `people` table |
| MEM People delete | `DELETE /api/siti/api/people/:id` | (a) `DELETE /api/people/:id` in naca-backend | Honor `NEO_SELF_ID` delete-protect (memory `project_naca_app`) |
| SITI tab WhatsApp start/fresh/stop | `POST /api/siti/api/whatsapp/{start,fresh,stop}` | (b) `agent_commands(to_agent='siti', command='wacli_{start,fresh,stop}')` | wacli is Siti's lane, not naca-backend's |
| SITI tab person familiarity | `/api/siti/api/contacts/:id/familiarity` | (c) Direct Supabase | Already computed in tables |
| SITI tab events stream | `/api/siti/api/events` (SSE) | (c) Supabase Realtime channel on relevant table | Realtime is already used elsewhere in the app |
| (parked) Voice phase A1 | `POST /api/siti/api/voice-chat` | (b) Hypothetical `agent_intents(source='naca_voice', raw_text=transcript)` + subscribe to reply | Decision needed: where does the reply land? `agent_intents.reply_text`? new table? |

## Coordination with the in-flight session

As of 2026-05-13 ~14:38, the parallel CC session is shipping:

- **broneotodak/siti-v2 PR #71** — `runVideoOutboundCycle` parallel to `runOutboundCycle`. Handles `agent_commands{command='send_whatsapp_video'}` rows. NAS-fetch via SSH+cat for `media_store='nas'`.
- **broneotodak/siti PR #60** — `mediaPath → filePath` wire-format translator in /send so wacli accepts SendModule's path-based payloads.

**Neither overlaps with the 5 broken NACA App surfaces above.** They're outbound-bridge enrichment, not /api/siti/* migration. Safe to start NACA App migration without conflict, provided new `agent_commands` shapes follow the established pattern from PR #71 (`to_agent='siti'`, `command='send_whatsapp_<kind>'`, `payload={...}`).

## Also affected: xiaozhi-dog

Memory `e808b673` (2026-04-30 — "Dog v2 Phase B.4 COMPLETE"): doggy-Siti routes voice through `/api/voice-chat` on port 3800. **That path is dead now.** Status unknown — verify whether the dog is currently broken, silently failing, or has been rerouted out-of-band. If broken, it's a parallel reason to land a v2 voice path.

## Recommended port order (cheapest → most architectural)

1. **MEM → Media listing** via pattern (c). 1-2 hours. Zero backend work.
2. **People edit/delete** via pattern (a). 2-3 hours. New routes in naca-backend.
3. **SITI status badge + CFG SITI test** via pattern (a). 1-2 hours. Aggregator endpoint.
4. **SITI tab WhatsApp controls** via pattern (b). 4-6 hours. Requires Realtime subscription on `agent_commands.status` for the dispatched command.
5. **Voice phase A1** (parked). Unblocked once a response-back pattern lands (one of: new HTTP endpoint, new `agent_intents.reply_text` column with Realtime, or a new `voice_responses` table). Plus client-side ASR + TTS (Flutter packages, ~1 day).
6. **xiaozhi-dog voice path** — separate concern but same blocker as #5.

## What this doc is NOT

- Not a prescription. Pattern recommendations are starting points, not decisions.
- Not a PR. No code changes.
- Not closed scope. New broken endpoints may turn up as we touch the app.

## Open questions

1. Should the inbound reply path for "NACA asks Siti something" land in `agent_intents.reply_text` (in-place), a new `voice_responses` table, or a generalized `naca_replies` table for any NACA-originated intent?
2. Is there a v2 plan for SSE / events streaming, or are we standardizing on Supabase Realtime for everything?
3. Should NACA App start writing `agent_commands` directly to neo-brain (currently does that for some things), or always go through naca-backend (server-side validation + audit)?

## Related memories

- `feedback_naca_siti_no_assumptions` — verify state before changes, blast radius is wide
- `feedback_siti_vs_neo_twin` — identity boundaries
- `feedback_code_merged_not_deploy_live` — code-merged ≠ deploy-live
- `8279b9b8` — outbound-bridge for agent_commands (May 9)
- `e808b673` — Dog v2 Phase B.4 (Apr 30, /api/voice-chat dependency)
- `c1a9b95f` — Platform Refactor v1 complete (May 11, npm package split — separate concern from this gap)
- This doc's companion `shared_infra_change` memory (to be saved alongside).
