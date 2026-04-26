// Backend changes auto-deploy via .github/workflows/deploy.yml — pushes to
// main fast-forward this checkout on the VPS and `pm2 restart naca-backend`.
require('dotenv').config();
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');
const SessionManager = require('./session-manager');

// === NACA: Supabase for agent state ===
let supabase = null;
if (process.env.NEO_BRAIN_URL && process.env.NEO_BRAIN_SERVICE_ROLE_KEY) {
  const { createClient } = require('@supabase/supabase-js');
  supabase = createClient(process.env.NEO_BRAIN_URL, process.env.NEO_BRAIN_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  console.log('[NACA] Supabase connected to neo-brain');
}

const UPLOAD_DIR = '/tmp/ccc-uploads';
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const PORT = parseInt(process.env.PORT || '3100');
const AUTH_TOKEN = process.env.AUTH_TOKEN;
const sm = new SessionManager();

// 15-second TTL cache for Uptime Kuma status-page fetches.
let kumaCache = null;

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // GitHub webhook bypasses Bearer auth — it uses HMAC SHA-256 signature.
  // Must be checked BEFORE Bearer auth, because GitHub sends X-Hub-Signature-256, not Authorization.
  if (req.url === '/api/webhooks/github' && req.method === 'POST') {
    return handleGithubWebhook(req, res);
  }

  const auth = req.headers.authorization;
  if (auth !== `Bearer ${AUTH_TOKEN}`) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Unauthorized' }));
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);
  const urlPath = url.pathname;

  if (urlPath === '/api/sessions' && req.method === 'GET') { json(res, sm.list()); return; }

  if (urlPath === '/api/sessions' && req.method === 'POST') {
    readBody(req, (body) => {
      try {
        const { name, projectDir } = body;
        if (!name) { json(res, { error: 'name required' }, 400); return; }
        json(res, sm.create(name, projectDir), 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  const sessionMatch = urlPath.match(/^\/api\/sessions\/([a-f0-9-]+)$/);

  if (sessionMatch && req.method === 'GET') {
    const s = sm.get(sessionMatch[1]);
    if (!s?.id) { json(res, { error: 'not found' }, 404); return; }
    json(res, s);
    return;
  }

  if (sessionMatch && req.method === 'PATCH') {
    readBody(req, (body) => {
      try {
        sm.renameSession(sessionMatch[1], body.name);
        json(res, { ok: true });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  if (sessionMatch && req.method === 'DELETE') {
    try { sm.deleteSession(sessionMatch[1]); json(res, { ok: true }); }
    catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  const startMatch = urlPath.match(/^\/api\/sessions\/([a-f0-9-]+)\/start$/);
  if (startMatch && req.method === 'POST') {
    try { json(res, sm.startSession(startMatch[1])); }
    catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  const stopMatch = urlPath.match(/^\/api\/sessions\/([a-f0-9-]+)\/stop$/);
  if (stopMatch && req.method === 'POST') {
    try { sm.stopSession(stopMatch[1]); json(res, { ok: true }); }
    catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  const restartMatch = urlPath.match(/^\/api\/sessions\/([a-f0-9-]+)\/restart$/);
  if (restartMatch && req.method === 'POST') {
    try {
      sm.stopSession(restartMatch[1]);
      setTimeout(() => {
        try { sm.startSession(restartMatch[1]); } catch {}
      }, 500);
      json(res, { ok: true });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  if (urlPath === '/api/upload' && req.method === 'POST') {
    readBody(req, (body) => {
      try {
        if (!body.data || !body.filename) {
          json(res, { error: 'data (base64) and filename required' }, 400);
          return;
        }
        const ext = path.extname(body.filename) || '.png';
        const id = crypto.randomBytes(8).toString('hex');
        const fname = `${id}${ext}`;
        const fpath = path.join(UPLOAD_DIR, fname);
        const buf = Buffer.from(body.data, 'base64');
        fs.writeFileSync(fpath, buf);
        // Make readable by lanccc user
        fs.chmodSync(fpath, 0o644);
        console.log(`[UPLOAD] ${fname} (${(buf.length / 1024).toFixed(1)}KB)`);
        json(res, { path: fpath, filename: fname, size: buf.length });
      } catch (e) { json(res, { error: e.message }, 500); }
    }, 20 * 1024 * 1024); // 20MB limit
    return;
  }

  if (urlPath === '/api/health') {
    json(res, { status: 'ok', uptime: process.uptime(), sessions: sm.list().length });
    return;
  }

  // =============================================
  // NACA ENDPOINTS — Agent Dashboard Data
  // =============================================

  // GET /api/agents/heartbeats — all agent health status
  if (urlPath === '/api/agents/heartbeats' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const { data, error } = await supabase.from('agent_heartbeats').select('*').order('reported_at', { ascending: false });
      if (error) throw error;
      json(res, { heartbeats: data || [] });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/agents/commands?status=pending&limit=20 — command queue
  if (urlPath === '/api/agents/commands' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const status = url.searchParams.get('status');
      const limit = parseInt(url.searchParams.get('limit') || '20');
      let q = supabase.from('agent_commands').select('*').order('created_at', { ascending: false }).limit(limit);
      if (status) q = q.eq('status', status);
      const { data, error } = await q;
      if (error) throw error;
      json(res, { commands: data || [] });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // POST /api/agents/commands — dispatch a command to an agent
  if (urlPath === '/api/agents/commands' && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    readBody(req, async (body) => {
      try {
        const { to_agent, command, payload, priority } = body;
        if (!to_agent || !command) { json(res, { error: 'to_agent and command required' }, 400); return; }
        const { data, error } = await supabase.from('agent_commands').insert({
          from_agent: 'naca-app',
          to_agent,
          command,
          payload: payload || {},
          priority: priority || 5,
        }).select().single();
        if (error) throw error;
        json(res, { ok: true, command: data }, 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // GET /api/agents/locks — active project locks
  if (urlPath === '/api/agents/locks' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const { data, error } = await supabase.from('agent_locks').select('*');
      if (error) throw error;
      json(res, { locks: data || [] });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/agents/summary — dashboard overview (heartbeats + pending commands + locks)
  if (urlPath === '/api/agents/summary' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const [hb, pending, running, failed, locks] = await Promise.all([
        supabase.from('agent_heartbeats').select('*'),
        supabase.from('agent_commands').select('id', { count: 'exact', head: true }).eq('status', 'pending'),
        supabase.from('agent_commands').select('id', { count: 'exact', head: true }).eq('status', 'running'),
        supabase.from('agent_commands').select('id', { count: 'exact', head: true }).in('status', ['failed', 'dead_letter', 'needs_review']),
        supabase.from('agent_locks').select('*'),
      ]);
      json(res, {
        agents: hb.data || [],
        queue: { pending: pending.count || 0, running: running.count || 0, failed: failed.count || 0 },
        locks: locks.data || [],
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/media-batch?ids=uuid1,uuid2 — fetch media metadata for memory cross-links
  // Returns kind/mime/transcript/caption only (no signed URLs — those still come from Siti).
  if (urlPath === '/api/media-batch' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const idsParam = url.searchParams.get('ids') || '';
      const ids = idsParam.split(',').map(s => s.trim()).filter(Boolean).slice(0, 200);
      if (!ids.length) { json(res, { media: [] }); return; }
      const { data, error } = await supabase.from('media')
        .select('id, kind, mime_type, transcript, caption, source, source_ref, subject_id, bytes, created_at')
        .in('id', ids);
      if (error) throw error;
      json(res, { media: data || [] });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // =============================================
  // SCHEDULED ACTIONS — operator cockpit for timekeeper queue
  // =============================================

  // GET /api/scheduled-actions?status=&kind=&since=&owner=&limit=
  if (urlPath === '/api/scheduled-actions' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const status = url.searchParams.get('status'); // scheduled|fired|failed|cancelled|dead_letter
      const kind = url.searchParams.get('kind');     // send_whatsapp|agent_command|agent_intent
      const since = url.searchParams.get('since');   // ISO timestamp; filters fire_at >=
      const owner = url.searchParams.get('owner');   // owner_subject_id uuid
      const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '100'), 1), 500);

      let q = supabase.from('scheduled_actions').select('*');
      if (status) q = q.eq('status', status);
      if (kind) q = q.eq('action_kind', kind);
      if (owner) q = q.eq('owner_subject_id', owner);
      if (since) q = q.gte('fire_at', since);
      // Sort: pending soonest first, history most-recent first
      q = (status === 'scheduled')
        ? q.order('fire_at', { ascending: true })
        : q.order('fire_at', { ascending: false });
      q = q.limit(limit);

      const { data, error } = await q;
      if (error) throw error;

      // Lightweight stats so the UI can show counts without a second call
      const counts = await Promise.all([
        supabase.from('scheduled_actions').select('id', { count: 'exact', head: true }).eq('status', 'scheduled'),
        supabase.from('scheduled_actions').select('id', { count: 'exact', head: true }).eq('status', 'fired'),
        supabase.from('scheduled_actions').select('id', { count: 'exact', head: true }).eq('status', 'failed'),
        supabase.from('scheduled_actions').select('id', { count: 'exact', head: true }).eq('status', 'cancelled'),
      ]);
      json(res, {
        actions: data || [],
        stats: {
          scheduled: counts[0].count || 0,
          fired: counts[1].count || 0,
          failed: counts[2].count || 0,
          cancelled: counts[3].count || 0,
        },
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // POST /api/scheduled-actions/:id/cancel — operator cancellation
  const cancelMatch = urlPath.match(/^\/api\/scheduled-actions\/([0-9a-f-]{36})\/cancel$/);
  if (cancelMatch && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = cancelMatch[1];
    try {
      // Only cancel rows still in 'scheduled' state — already-fired/cancelled rows are immutable
      const { data, error } = await supabase.from('scheduled_actions')
        .update({
          status: 'cancelled',
          cancelled_at: new Date().toISOString(),
          cancelled_by: 'naca:operator',
        })
        .eq('id', id)
        .eq('status', 'scheduled')
        .select()
        .single();
      if (error) {
        // 0 rows updated = either not-found or wrong status
        if (error.code === 'PGRST116') { json(res, { error: 'not cancellable (already fired/cancelled or not found)' }, 409); return; }
        throw error;
      }
      json(res, { ok: true, action: data });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // POST /api/scheduled-actions — operator create (currently send_whatsapp parity)
  if (urlPath === '/api/scheduled-actions' && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    readBody(req, async (body) => {
      try {
        const kind = (body.action_kind || 'send_whatsapp').toString();
        const fireAtRaw = (body.fire_at || '').toString().trim();
        if (!fireAtRaw) { json(res, { error: 'fire_at required' }, 400); return; }
        const fireAt = new Date(fireAtRaw);
        if (isNaN(fireAt.getTime())) { json(res, { error: 'fire_at not a valid ISO 8601 timestamp' }, 400); return; }
        if (fireAt.getTime() <= Date.now()) { json(res, { error: 'fire_at must be in the future' }, 400); return; }

        // Validate payload by kind. We only allow operator-side reminders for now;
        // agent_command / agent_intent are reserved for the agents themselves.
        let payload;
        if (kind === 'send_whatsapp') {
          const to = (body.to || '').toString().trim();
          const message = (body.message || '').toString().trim();
          if (!to || !message) { json(res, { error: 'to and message required' }, 400); return; }
          payload = { to, message };
        } else {
          json(res, { error: `action_kind '${kind}' not allowed from operator UI` }, 400); return;
        }

        const recurrence = body.recurrence ? body.recurrence.toString().trim() : null;
        const description = (body.description || (payload.message || '')).toString().slice(0, 80);
        const ownerId = (body.owner_subject_id || '00000000-0000-0000-0000-000000000001').toString();

        const { data, error } = await supabase.from('scheduled_actions').insert({
          fire_at: fireAt.toISOString(),
          action_kind: kind,
          action_payload: payload,
          recurrence,
          status: 'scheduled',
          created_by: 'naca:operator',
          owner_subject_id: ownerId,
          description,
        }).select().single();
        if (error) throw error;
        json(res, { ok: true, action: data }, 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // =============================================
  // COST MONITOR — ElevenLabs subscription + usage estimates
  // =============================================
  if (urlPath === '/api/costs' && req.method === 'GET') {
    const costs = { services: [], totalEstimate: 0 };

    // ElevenLabs — direct API call (key from env)
    const elKey = process.env.ELEVENLABS_API_KEY;
    if (elKey) {
      try {
        const elRes = await new Promise((resolve, reject) => {
          const https = require('https');
          const req = https.get('https://api.elevenlabs.io/v1/user/subscription', {
            headers: { 'xi-api-key': elKey },
            timeout: 8000,
          }, (res) => {
            let body = '';
            res.on('data', c => body += c);
            res.on('end', () => {
              try { resolve(JSON.parse(body)); } catch { resolve(null); }
            });
          });
          req.on('error', reject);
          req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
        });
        if (elRes) {
          costs.services.push({
            name: 'ElevenLabs',
            tier: elRes.tier,
            cost: (elRes.next_invoice?.amount_due_cents || 0) / 100,
            currency: elRes.currency || 'usd',
            usage: `${elRes.character_count?.toLocaleString() || 0} / ${elRes.character_limit?.toLocaleString() || 0} chars`,
            usagePct: elRes.character_limit ? Math.round((elRes.character_count / elRes.character_limit) * 100) : 0,
            resetUnix: elRes.next_character_count_reset_unix,
            status: elRes.status,
          });
        }
      } catch (_) {
        costs.services.push({ name: 'ElevenLabs', cost: 22, currency: 'usd', usage: 'API unreachable', status: 'unknown' });
      }
    }

    // Hetzner VPS — fixed cost
    costs.services.push({ name: 'Hetzner VPS (CPX31)', cost: 28, currency: 'eur', usage: '4vCPU / 8GB / 160GB SSD', status: 'active' });

    // Supabase — paid Pro plan (neo-brain + legacy)
    costs.services.push({ name: 'Supabase (neo-brain)', cost: 25, currency: 'usd', tier: 'pro', usage: 'Primary memory + agent bus', status: 'active' });
    costs.services.push({ name: 'Supabase (legacy)', cost: 25, currency: 'usd', tier: 'pro', usage: 'nclaw tables + THR/Academy', status: 'active' });

    // Claude API — estimate from agent_commands in last 30 days
    if (supabase) {
      try {
        const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString();
        const { count } = await supabase.from('agent_commands')
          .select('id', { count: 'exact', head: true })
          .gte('created_at', thirtyDaysAgo);
        const estimatedCost = Math.round((count || 0) * 0.15); // ~$0.15 per command avg
        costs.services.push({
          name: 'Claude API (Anthropic)',
          cost: estimatedCost || 50,
          currency: 'usd',
          usage: `~${count || 0} commands (30d)`,
          status: 'estimated',
          note: estimatedCost < 10 ? 'Low usage — estimate $30-50/mo baseline' : null,
        });
      } catch (_) {
        costs.services.push({ name: 'Claude API (Anthropic)', cost: 50, currency: 'usd', usage: 'Estimate', status: 'estimated' });
      }
    } else {
      costs.services.push({ name: 'Claude API (Anthropic)', cost: 50, currency: 'usd', usage: 'Estimate', status: 'estimated' });
    }

    // Gemini — Ultra plan (Google AI Studio subscription)
    costs.services.push({ name: 'Gemini (Google)', cost: 190, currency: 'myr', tier: 'ultra', usage: 'AI Studio Ultra plan (~RM190/mo) + pay-per-use API', status: 'active', note: 'Siti primary LLM (Flash 2.5 Tier 2)' });

    // Twilio — annual plan divided monthly
    costs.services.push({ name: 'Twilio', cost: 8, currency: 'usd', usage: 'MY +60360431442 + per-min calls (~$100/yr ÷ 12)', status: 'estimated' });

    // Telnyx — annual plan divided monthly
    costs.services.push({ name: 'Telnyx', cost: 1.25, currency: 'usd', usage: 'US +17072160581 (~$15/yr ÷ 12) + TTS backup', status: 'estimated' });

    // Netlify — paid plan
    costs.services.push({ name: 'Netlify', cost: 19, currency: 'usd', tier: 'pro', usage: 'Academy, ClaudeN, Presentation deploys', status: 'active' });

    // Total (convert all to USD: EUR*1.08, MYR/4.5)
    costs.totalEstimate = costs.services.reduce((sum, s) => {
      let usd = s.cost;
      if (s.currency === 'eur') usd = s.cost * 1.08;
      else if (s.currency === 'myr') usd = s.cost / 4.5;
      return sum + usd;
    }, 0);
    costs.totalCurrency = 'usd';

    json(res, costs);
    return;
  }

  // =============================================
  // UPTIME KUMA — status page proxy (NAS at 100.85.18.97:3001 is Tailnet-only)
  // Returns combined { groups, monitors, lastUpdated }. Cached 15s.
  // =============================================
  if (urlPath === '/api/kuma/status' && req.method === 'GET') {
    try {
      const now = Date.now();
      if (kumaCache && (now - kumaCache.ts) < 15000) {
        json(res, kumaCache.data);
        return;
      }
      const base = process.env.KUMA_URL || 'http://100.85.18.97:3001';
      const slug = process.env.KUMA_SLUG || 'neo-fleet';
      const fetchJson = (u) => new Promise((resolve, reject) => {
        const r = http.get(u, { timeout: 5000 }, (resp) => {
          let body = '';
          resp.on('data', c => body += c);
          resp.on('end', () => {
            try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
          });
        });
        r.on('error', reject);
        r.on('timeout', () => { r.destroy(); reject(new Error('timeout')); });
      });
      const [page, hb] = await Promise.all([
        fetchJson(`${base}/api/status-page/${slug}`),
        fetchJson(`${base}/api/status-page/heartbeat/${slug}`),
      ]);
      const groups = (page.publicGroupList || []).map(g => ({
        id: g.id,
        name: g.name,
        weight: g.weight,
        monitors: (g.monitorList || []).map(m => {
          const beats = hb.heartbeatList?.[m.id] || [];
          const last = beats[beats.length - 1];
          const uptime24 = hb.uptimeList?.[`${m.id}_24`];
          return {
            id: m.id,
            name: m.name,
            type: m.type,
            status: last?.status ?? null,         // 0=down, 1=up, 2=pending, 3=maintenance
            statusLabel: last?.status === 1 ? 'up' : last?.status === 0 ? 'down' : last?.status === 2 ? 'pending' : 'unknown',
            ping_ms: last?.ping ?? null,
            msg: last?.msg ?? null,
            last_seen: last?.time ?? null,
            uptime_24h: typeof uptime24 === 'number' ? uptime24 : null,
          };
        }),
      }));
      const counts = { up: 0, down: 0, pending: 0, unknown: 0 };
      for (const g of groups) for (const m of g.monitors) {
        if (m.status === 1) counts.up++;
        else if (m.status === 0) counts.down++;
        else if (m.status === 2) counts.pending++;
        else counts.unknown++;
      }
      const data = {
        slug,
        title: page.config?.title || 'Fleet',
        statusPageUrl: `${base}/status/${slug}`,
        groups,
        counts,
        lastUpdated: new Date().toISOString(),
      };
      kumaCache = { ts: now, data };
      json(res, data);
    } catch (e) {
      json(res, { error: `kuma unreachable: ${e.message}` }, 502);
    }
    return;
  }

  // =============================================
  // SITI PROXY — forward to localhost:3800 (same VPS, no CORS issue)
  // =============================================
  if (urlPath.startsWith('/api/siti/')) {
    const sitiPath = urlPath.replace('/api/siti', '');
    const sitiPin = process.env.SITI_PIN || '404282';
    const sitiUrl = new URL(`http://localhost:3800${sitiPath}`);

    // Read request body for POST/PATCH/DELETE
    readBody(req, (reqBody) => {
      const options = {
        hostname: sitiUrl.hostname,
        port: sitiUrl.port,
        path: sitiUrl.pathname + sitiUrl.search,
        method: req.method,
        timeout: 15000,
        headers: {
          'x-pin': sitiPin,
          'content-type': 'application/json',
        },
      };

      const proxyReq = http.request(options, (proxyRes) => {
        let body = '';
        proxyRes.on('data', c => body += c);
        proxyRes.on('end', () => {
          res.writeHead(proxyRes.statusCode || 200, { 'Content-Type': 'application/json' });
          res.end(body);
        });
      });
      proxyReq.on('error', (err) => json(res, { error: `Siti unreachable: ${err.message}` }, 502));
      if (reqBody && Object.keys(reqBody).length > 0) {
        proxyReq.write(JSON.stringify(reqBody));
      }
      proxyReq.end();
    });
    return;
  }

  json(res, { error: 'not found' }, 404);
});

// ════════════════════════════════════════════════════════════════════
// GITHUB WEBHOOK RELAY (Phase 2 C)
//
// GitHub POSTs events here → we verify HMAC, classify by event type,
// and write rows into agent_commands so the relevant agent (reviewer,
// dev-agent, planner) can pick them up. Phase 3 wires the consumers.
//
// Setup on each repo (one-time, via gh CLI or GitHub UI):
//   gh api -X POST /repos/{owner}/{repo}/hooks \
//     -f name=web -F active=true -f events[]=push -f events[]=pull_request \
//     -f events[]=check_suite -f events[]=issue_comment \
//     -f config[url]=https://naca.neotodak.com/api/webhooks/github \
//     -f config[content_type]=json -f config[secret]=$GITHUB_WEBHOOK_SECRET
// ════════════════════════════════════════════════════════════════════
function handleGithubWebhook(req, res) {
  const secret = process.env.GITHUB_WEBHOOK_SECRET;
  if (!secret) { res.writeHead(503, { 'Content-Type': 'application/json' }); res.end('{"error":"webhook secret not configured"}'); return; }

  const sig = req.headers['x-hub-signature-256'];
  const event = req.headers['x-github-event'];
  const deliveryId = req.headers['x-github-delivery'];
  if (!sig || !event) { res.writeHead(400, { 'Content-Type': 'application/json' }); res.end('{"error":"missing GitHub headers"}'); return; }

  // Read raw body for signature verification (must be exact bytes GitHub signed)
  let raw = '';
  req.on('data', c => raw += c);
  req.on('end', async () => {
    try {
      const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(raw).digest('hex');
      const valid = sig.length === expected.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected));
      if (!valid) { res.writeHead(401, { 'Content-Type': 'application/json' }); res.end('{"error":"signature mismatch"}'); return; }

      let payload;
      try { payload = JSON.parse(raw); } catch { res.writeHead(400, { 'Content-Type': 'application/json' }); res.end('{"error":"bad json"}'); return; }

      const repo = payload.repository?.full_name || 'unknown';
      const commands = []; // collect what to insert

      // ── event mappings (Phase 2 baseline; Phase 3 will tune routing) ──
      switch (event) {
        case 'push': {
          // Push to main on a deploy-tracked repo → notify deploy worker
          const branch = (payload.ref || '').replace('refs/heads/', '');
          if (branch === 'main' || branch === 'master') {
            commands.push({
              from_agent: 'github-actions',
              to_agent: 'dev-agent',
              command: 'on_main_push',
              payload: { repo, branch, commits: payload.commits?.length || 0, head_commit: payload.head_commit?.id, message: payload.head_commit?.message },
              priority: 4,
            });
          }
          break;
        }
        case 'pull_request': {
          // Opened / synchronized → reviewer should look at it.
          // Contract from /home/openclaw/reviewer-agent/index.js:
          //   to_agent='reviewer' (NOT 'reviewer-agent'), command='review_pr',
          //   payload requires { project, repo, branch }.
          if (['opened', 'synchronize', 'reopened', 'ready_for_review'].includes(payload.action)) {
            const project = repo.split('/').pop() || repo;     // 'broneotodak/naca-app' → 'naca-app'
            const branch = payload.pull_request?.head?.ref;     // PR head branch name (the actual ref)
            commands.push({
              from_agent: 'github-actions',
              to_agent: 'reviewer',
              command: 'review_pr',
              payload: {
                project,
                repo,
                branch,
                pr_number: payload.pull_request?.number,
                pr_title: payload.pull_request?.title,
                pr_url: payload.pull_request?.html_url,
                head_sha: payload.pull_request?.head?.sha,
                base: payload.pull_request?.base?.ref,
                action: payload.action,
                reporter: payload.pull_request?.user?.login,
              },
              priority: 3,
            });
          }
          // Closed/merged → notify dev-agent (deploy hook)
          if (payload.action === 'closed' && payload.pull_request?.merged) {
            commands.push({
              from_agent: 'github-actions',
              to_agent: 'dev-agent',
              command: 'on_pr_merged',
              payload: { repo, pr_number: payload.pull_request.number, pr_title: payload.pull_request.title, merged_by: payload.pull_request.merged_by?.login },
              priority: 4,
            });
          }
          break;
        }
        case 'check_suite': {
          if (payload.action === 'completed' && payload.check_suite?.conclusion === 'failure') {
            commands.push({
              from_agent: 'github-actions',
              to_agent: 'planner-agent',
              command: 'investigate_check_failure',
              payload: { repo, head_sha: payload.check_suite.head_sha, branch: payload.check_suite.head_branch, app: payload.check_suite.app?.slug },
              priority: 5,
            });
          }
          break;
        }
        case 'issue_comment': {
          // Comments mentioning @dev-agent or @planner-agent
          const body = payload.comment?.body || '';
          for (const target of ['dev-agent', 'planner-agent', 'reviewer-agent', 'siti']) {
            if (body.includes('@' + target)) {
              commands.push({
                from_agent: 'github-actions',
                to_agent: target,
                command: 'github_mention',
                payload: { repo, issue_number: payload.issue?.number, comment_url: payload.comment?.html_url, body, author: payload.comment?.user?.login },
                priority: 3,
              });
            }
          }
          break;
        }
        case 'ping': {
          // GitHub's setup ping — just acknowledge.
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, event: 'ping', delivery: deliveryId }));
          return;
        }
        default: {
          // Unhandled event — accept but record nothing
          console.log(`[github-webhook] unhandled event '${event}' from ${repo} (delivery ${deliveryId})`);
        }
      }

      // Insert all queued commands in one shot via Supabase REST
      let inserted = 0;
      if (commands.length && supabase) {
        const { data, error } = await supabase.from('agent_commands').insert(commands).select('id');
        if (error) {
          console.error('[github-webhook] insert failed:', error.message);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: error.message }));
          return;
        }
        inserted = data?.length || 0;
      }

      console.log(`[github-webhook] ${event}/${payload.action || '-'} from ${repo} → queued ${inserted} command(s)`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, event, action: payload.action || null, repo, queued: inserted, delivery: deliveryId }));
    } catch (e) {
      console.error('[github-webhook] error:', e.message);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    }
  });
}

const wss = new WebSocketServer({ server });

// Ping all clients every 30s to keep connections alive
const pingInterval = setInterval(() => {
  wss.clients.forEach(ws => {
    if (ws.isAlive === false) { ws.terminate(); return; }
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

wss.on('close', () => clearInterval(pingInterval));

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const token = url.searchParams.get('token');
  if (token !== AUTH_TOKEN) { ws.close(4001, 'Unauthorized'); return; }

  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  console.log('[WS] Client connected');
  let subscribedSession = null;

  const onEvent = (event) => {
    if (subscribedSession && event.sessionId !== subscribedSession) return;
    try {
      ws.send(JSON.stringify(event));
    } catch (e) {
      console.error('[WS] Send error:', e.message);
    }
  };
  sm.on('event', onEvent);

  ws.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      switch (msg.action) {
        case 'ping': {
          ws.send(JSON.stringify({ type: 'pong' }));
          break;
        }
        case 'subscribe': {
          subscribedSession = msg.sessionId;
          console.log(`[WS] Subscribe to session ${msg.sessionId.substring(0, 8)}`);
          const buffer = sm.getBuffer(msg.sessionId);
          console.log(`[WS] Replay buffer for ${msg.sessionId.substring(0, 8)}: ${buffer.length} events`);
          if (buffer.length > 0) ws.send(JSON.stringify({ type: 'replay', sessionId: msg.sessionId, events: buffer }));
          ws.send(JSON.stringify({ type: 'subscribed', sessionId: msg.sessionId }));
          break;
        }
        case 'unsubscribe': { subscribedSession = null; break; }
        case 'prompt': {
          if (!msg.sessionId || !msg.content) {
            ws.send(JSON.stringify({ type: 'error', content: 'sessionId and content required' }));
            break;
          }
          console.log(`[WS] Prompt for ${msg.sessionId.substring(0, 8)}: "${msg.content.substring(0, 50)}"`);
          try { sm.sendPrompt(msg.sessionId, msg.content); }
          catch (e) { ws.send(JSON.stringify({ type: 'error', content: e.message })); }
          break;
        }
      }
    } catch (e) {
      ws.send(JSON.stringify({ type: 'error', content: 'Invalid JSON' }));
    }
  });

  ws.on('close', () => {
    sm.removeListener('event', onEvent);
    console.log('[WS] Client disconnected');
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[CCC] Server on port ${PORT}`);
  console.log(`[CCC] Auth: ${AUTH_TOKEN.slice(0, 15)}...`);

  // Heartbeat: register naca-backend in neo-brain every 60s
  if (supabase) {
    const doHeartbeat = async () => {
      try {
        await supabase.from('agent_heartbeats').upsert({
          agent_name: 'naca-backend',
          status: 'ok',
          meta: {
            version: 'naca-backend-v1',
            port: PORT,
            sessions: sm.list().length,
            ws_clients: wss.clients.size,
            memory_mb: Math.round(process.memoryUsage().rss / 1024 / 1024),
            uptime_sec: Math.round(process.uptime()),
          },
          reported_at: new Date().toISOString(),
        }, { onConflict: 'agent_name' });
      } catch (e) {
        console.error('[NACA] Heartbeat failed:', e.message);
      }
    };
    doHeartbeat();
    setInterval(doHeartbeat, 60_000);
    console.log('[NACA] Heartbeat ticker started (every 60s)');
  }
});

function json(res, data, code = 200) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}
function readBody(req, cb, maxSize = 1024 * 1024) {
  let body = '';
  let size = 0;
  req.on('data', c => {
    size += c.length;
    if (size > maxSize) { req.destroy(); return; }
    body += c;
  });
  req.on('end', () => { try { cb(JSON.parse(body)); } catch { cb({}); } });
}
