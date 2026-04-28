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

// === MinIO media bytes — fixes mixed-content for browser image render ======
// Pulls minio-nas creds from neo-brain credentials vault on boot. Replicates
// Siti's s3SignedGet helper (SigV4 presigned GET) so we can sign URLs without
// going through Siti. Used by /api/media/:id/blob to fetch MinIO bytes
// server-side (HTTP fine on Tailscale) and stream them over HTTPS to the
// browser — avoids the http://100.85.18.97:9000/... URLs that Chrome blocks
// on a https://naca.neotodak.com page.
let minioCfg = null;
async function loadMinioCfg() {
  if (!supabase) return;
  try {
    const { data, error } = await supabase.rpc('get_credential', {
      p_owner_id: '00000000-0000-0000-0000-000000000001',
      p_service: 'minio-nas',
      p_credential_type: 'sdk_service_account',
    });
    if (error) { console.error('[minio] vault fetch failed:', error.message); return; }
    if (!data?.[0]?.credential_value) { console.error('[minio] no credential value'); return; }
    minioCfg = JSON.parse(data[0].credential_value);
    console.log('[minio] config loaded — endpoint=' + minioCfg.endpoint + ' bucket=' + minioCfg.bucket);
  } catch (e) { console.error('[minio] cfg load error:', e.message); }
}
loadMinioCfg();

function _s3SigningKey(secret, dateStamp, region) {
  const kDate = crypto.createHmac('sha256', 'AWS4' + secret).update(dateStamp).digest();
  const kRegion = crypto.createHmac('sha256', kDate).update(region).digest();
  const kService = crypto.createHmac('sha256', kRegion).update('s3').digest();
  return crypto.createHmac('sha256', kService).update('aws4_request').digest();
}
function s3SignedGet(storageUrlOrKey, expiresIn = 900) {
  if (!minioCfg) return null;
  let key = storageUrlOrKey;
  if (storageUrlOrKey.startsWith('http')) {
    const u = new URL(storageUrlOrKey);
    const prefix = (minioCfg.pathStyle === false) ? '/' : `/${minioCfg.bucket}/`;
    if (u.pathname.startsWith(prefix)) key = decodeURIComponent(u.pathname.slice(prefix.length));
    else key = decodeURIComponent(u.pathname.slice(1));
  }
  const amzDate = new Date().toISOString().replace(/[:-]/g, '').replace(/\..{3}/, '');
  const dateStamp = amzDate.slice(0, 8);
  const credential = `${minioCfg.accessKeyId}/${dateStamp}/${minioCfg.region}/s3/aws4_request`;
  const canonicalUri = (minioCfg.pathStyle === false) ? `/${encodeURI(key)}` : `/${minioCfg.bucket}/${encodeURI(key)}`;
  const host = (minioCfg.pathStyle === false)
    ? `${minioCfg.bucket}.${new URL(minioCfg.endpoint).host}`
    : new URL(minioCfg.endpoint).host;
  const query = new URLSearchParams({
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': credential,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(expiresIn),
    'X-Amz-SignedHeaders': 'host',
  });
  const cr = ['GET', canonicalUri, query.toString(), `host:${host}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n');
  const scope = `${dateStamp}/${minioCfg.region}/s3/aws4_request`;
  const sts = ['AWS4-HMAC-SHA256', amzDate, scope, crypto.createHash('sha256').update(cr).digest('hex')].join('\n');
  const sig = crypto.createHmac('sha256', _s3SigningKey(minioCfg.secretAccessKey, dateStamp, minioCfg.region)).update(sts).digest('hex');
  query.set('X-Amz-Signature', sig);
  const baseUrl = (minioCfg.pathStyle === false)
    ? minioCfg.endpoint.replace('://', `://${minioCfg.bucket}.`)
    : minioCfg.endpoint.replace(/\/$/, '');
  return `${baseUrl}${canonicalUri}?${query.toString()}`;
}

// === GAM (Google Apps Manager) wrapper — Phase 4b Step 1A ==================
// Centralized Workspace gateway. Every /api/gam/* endpoint funnels through
// gamExec, which:
//   1) validates verb against ALLOWED_GAM_VERBS (no destructive ops, ever)
//   2) SSHes to TDCC VPS as the `tdcc` host alias (key on this VPS)
//   3) runs `gam <verb> <args>` and captures stdout/stderr/exit code
//   4) writes a row to neo-brain.gam_audit so we have a single source of
//      truth on what was queried by whom
// Siti's GAM tools are designed as thin clients of this layer (Phase 4b
// Step 1B in the parallel CC session) — agents NEVER SSH to TDCC directly.
const { spawn } = require('child_process');
const ALLOWED_GAM_VERBS = new Set([
  'info',     // info user, info domain, info group
  'print',    // print users, print orgs, print shareddrives, etc.
  'show',     // show ous, show users
  'report',   // report users, report customer (audit/usage reports)
  'redirect', // `redirect csv -` for piping reports as CSV; verb word matched verbatim
]);
const FORBIDDEN_GAM_TOKENS = [
  // belt-and-braces: even though only read verbs are allowed above, refuse
  // any args that mention destructive verbs in case someone smuggles them
  // through args. NEVER allow these tokens in the args string.
  'delete', 'remove', 'create', 'update', 'modify', 'transfer', 'undelete',
  'add ', 'replace ', 'move ', 'cancel',
];

function gamLog(row) {
  if (!supabase) return;
  supabase.from('gam_audit').insert(row).then(({ error }) => {
    if (error) console.error('[gam] audit insert failed:', error.message?.slice(0, 80));
  });
}

// Run a GAM command via SSH to TDCC. Returns { stdout, stderr, exitCode, ms }.
// Caller MUST validate verb + args via gamValidate before calling.
async function gamExec(verb, args, meta = {}) {
  const argStr = args.join(' ');
  const fullCmd = `/home/neo/bin/gam7/gam ${verb} ${argStr}`.trim();
  const sshTarget = process.env.GAM_SSH_TARGET || 'tdcc';
  return new Promise((resolve) => {
    const startedAt = Date.now();
    const proc = spawn('ssh', [sshTarget, fullCmd], { timeout: 60_000 });
    let stdout = '', stderr = '';
    proc.stdout.on('data', d => { stdout += d.toString(); });
    proc.stderr.on('data', d => { stderr += d.toString(); });
    proc.on('close', code => {
      const ms = Date.now() - startedAt;
      gamLog({
        from_agent: meta.from_agent || 'naca-app',
        requested_by: meta.requested_by || null,
        verb,
        args: { argv: args },
        exit_code: code,
        output_summary: stdout.slice(0, 500),
        ms_elapsed: ms,
        error: code === 0 ? null : (stderr.slice(0, 500) || `exit ${code}`),
      });
      resolve({ stdout, stderr, exitCode: code, ms });
    });
    proc.on('error', err => {
      const ms = Date.now() - startedAt;
      gamLog({
        from_agent: meta.from_agent || 'naca-app',
        requested_by: meta.requested_by || null,
        verb,
        args: { argv: args },
        exit_code: -1,
        output_summary: null,
        ms_elapsed: ms,
        error: err.message?.slice(0, 500),
      });
      resolve({ stdout: '', stderr: err.message, exitCode: -1, ms });
    });
  });
}

function gamValidate(verb, args) {
  if (!ALLOWED_GAM_VERBS.has(verb)) {
    return { ok: false, reason: `verb '${verb}' not in allowlist` };
  }
  const flat = (args || []).join(' ').toLowerCase();
  for (const tok of FORBIDDEN_GAM_TOKENS) {
    if (flat.includes(tok)) return { ok: false, reason: `forbidden token '${tok.trim()}' in args` };
  }
  return { ok: true };
}

// Parse gam's CSV output (`gam redirect csv - print ...`) into [{...}, ...].
// gam's print commands emit CSV with a header line. Trivial parser — no
// fancy quote handling, since gam quotes consistently and we only need
// fields that don't contain commas in practice.
function parseGamCSV(stdout) {
  const lines = stdout.split('\n').filter(l => l.trim());
  if (lines.length < 2) return [];
  const headers = lines[0].split(',').map(h => h.trim());
  return lines.slice(1).map(line => {
    // CSV split that respects quoted fields
    const cells = [];
    let cur = '', inQ = false;
    for (const ch of line) {
      if (ch === '"') inQ = !inQ;
      else if (ch === ',' && !inQ) { cells.push(cur); cur = ''; }
      else cur += ch;
    }
    cells.push(cur);
    const row = {};
    headers.forEach((h, i) => { row[h] = (cells[i] || '').trim(); });
    return row;
  });
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

  // GET /api/agents/insights — per-agent rollup for last 24h
  // Aggregates from agent_heartbeats + agent_commands + gam_audit +
  // memory_writes_log to give a "what each agent did today" view. Drives the
  // HQ AGENT INSIGHTS panel — observational, no actions exposed.
  if (urlPath === '/api/agents/insights' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const [hb, cmds, gam, memWrites] = await Promise.all([
        supabase.from('agent_heartbeats').select('agent_name, status, meta, reported_at'),
        supabase.from('agent_commands').select('to_agent, from_agent, status, error, command, created_at').gte('created_at', since),
        supabase.from('gam_audit').select('requested_by, verb, exit_code, ms_elapsed, error, created_at').gte('created_at', since),
        supabase.from('memory_writes_log').select('source, created_at').gte('created_at', since),
      ]);
      const heartbeats = hb.data || [];
      const commands = cmds.data || [];
      const gamCalls = gam.data || [];
      const memCounts = (memWrites.data || []).reduce((acc, r) => { acc[r.source || '?'] = (acc[r.source || '?'] || 0) + 1; return acc; }, {});

      // Build per-agent rollup. Start from heartbeats (canonical agent list)
      // then enrich with command + audit + memory metrics.
      const now = Date.now();
      const byAgent = {};
      for (const h of heartbeats) {
        const ageMin = Math.round((now - new Date(h.reported_at).getTime()) / 60000);
        byAgent[h.agent_name] = {
          agent: h.agent_name,
          status: h.status || 'unknown',
          last_seen_min: ageMin,
          stale: ageMin > 5,
          memory_mb: h.meta?.memory_mb ?? null,
          version: h.meta?.version ?? null,
          cmd_total: 0, cmd_done: 0, cmd_failed: 0, cmd_pending: 0,
          gam_calls: 0, gam_failed: 0, gam_p95_ms: 0,
          mem_writes: memCounts[h.agent_name] || 0,
          recent_failures: [],
        };
      }
      // Commands: count by to_agent (agent that should execute)
      for (const c of commands) {
        const a = byAgent[c.to_agent];
        if (!a) continue;
        a.cmd_total++;
        if (c.status === 'completed') a.cmd_done++;
        else if (c.status === 'pending' || c.status === 'running') a.cmd_pending++;
        else if (['failed', 'dead_letter', 'needs_review'].includes(c.status)) {
          a.cmd_failed++;
          if (a.recent_failures.length < 3 && c.error) a.recent_failures.push((c.command + ': ' + c.error).slice(0, 100));
        }
      }
      // GAM calls: bucket by requested_by (siti, naca-ui, etc.)
      const gamByCaller = {};
      for (const g of gamCalls) {
        const caller = g.requested_by || 'naca-ui';
        if (!gamByCaller[caller]) gamByCaller[caller] = { calls: 0, failed: 0, latencies: [] };
        gamByCaller[caller].calls++;
        if (g.exit_code !== 0) gamByCaller[caller].failed++;
        if (g.ms_elapsed) gamByCaller[caller].latencies.push(g.ms_elapsed);
      }
      // Calculate p95 per caller
      for (const [caller, stats] of Object.entries(gamByCaller)) {
        const sorted = stats.latencies.sort((a, b) => a - b);
        stats.p95 = sorted.length ? sorted[Math.floor(sorted.length * 0.95)] : 0;
      }
      // Map gam stats onto agents (siti = siti, naca-ui = naca-app)
      for (const a of Object.values(byAgent)) {
        const gamKey = a.agent === 'naca-app' ? 'naca-ui' : a.agent;
        const g = gamByCaller[gamKey];
        if (g) { a.gam_calls = g.calls; a.gam_failed = g.failed; a.gam_p95_ms = g.p95; }
      }

      // Sort: stale agents first (operator concern), then by command volume
      const agents = Object.values(byAgent).sort((x, y) => {
        if (x.stale !== y.stale) return x.stale ? -1 : 1;
        return y.cmd_total - x.cmd_total;
      });

      json(res, {
        window: '24h',
        generated_at: new Date().toISOString(),
        agents,
        totals: {
          agent_count: agents.length,
          stale_count: agents.filter(a => a.stale).length,
          cmd_total: commands.length,
          cmd_failed: commands.filter(c => ['failed', 'dead_letter', 'needs_review'].includes(c.status)).length,
          gam_calls: gamCalls.length,
          gam_failed: gamCalls.filter(g => g.exit_code !== 0).length,
          mem_writes: (memWrites.data || []).length,
        },
      });
    } catch (e) { json(res, { error: e.message }, 500); }
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

  // =============================================
  // GAM (Workspace gateway) — Phase 4b Step 1A
  // Read-only endpoints. SSH→TDCC→gam→parse. Audited to neo-brain.gam_audit.
  // Siti's tools call these endpoints, never SSH to TDCC directly.
  // =============================================

  // GET /api/gam/health — cheap probe for Kuma. Verifies SSH path to TDCC
  // works without actually invoking gam (which is slower). Sub-second.
  if (urlPath === '/api/gam/health' && req.method === 'GET') {
    const startedAt = Date.now();
    const proc = spawn('ssh', ['tdcc', 'echo ok'], { timeout: 8_000 });
    let out = '';
    proc.stdout.on('data', d => { out += d.toString(); });
    proc.on('close', code => {
      const ms = Date.now() - startedAt;
      const ok = code === 0 && out.trim() === 'ok';
      json(res, { ok, ms, exitCode: code }, ok ? 200 : 503);
    });
    proc.on('error', () => {
      json(res, { ok: false, ms: Date.now() - startedAt, error: 'ssh spawn failed' }, 503);
    });
    return;
  }

  // GET /api/gam/orgs — list all OUs (Org Units) in the Workspace
  if (urlPath === '/api/gam/orgs' && req.method === 'GET') {
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const args = ['csv', '-', 'print', 'orgs'];
    const v = gamValidate('redirect', args);
    if (!v.ok) { json(res, { error: v.reason }, 400); return; }
    const r = await gamExec('redirect', args, meta);
    if (r.exitCode !== 0) { json(res, { error: r.stderr || 'gam failed', exitCode: r.exitCode }, 502); return; }
    json(res, { orgs: parseGamCSV(r.stdout), count: parseGamCSV(r.stdout).length, ms: r.ms });
    return;
  }

  // GET /api/gam/shareddrives — list all shared drives (paginated by gam itself)
  if (urlPath === '/api/gam/shareddrives' && req.method === 'GET') {
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const args = ['csv', '-', 'print', 'shareddrives'];
    const v = gamValidate('redirect', args);
    if (!v.ok) { json(res, { error: v.reason }, 400); return; }
    const r = await gamExec('redirect', args, meta);
    if (r.exitCode !== 0) { json(res, { error: r.stderr || 'gam failed', exitCode: r.exitCode }, 502); return; }
    const drives = parseGamCSV(r.stdout);
    json(res, { drives, count: drives.length, ms: r.ms });
    return;
  }

  // GET /api/gam/users?q=<search> — list/search Workspace users
  if (urlPath === '/api/gam/users' && req.method === 'GET') {
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const q = (url.searchParams.get('q') || '').trim();
    // Always run as `redirect csv - print users` so output is parseable
    const args = ['csv', '-', 'print', 'users'];
    if (q) {
      // gam's `query` filter uses Directory API search. Valid fields are
      // email, givenName, familyName. We default to email match — most
      // common case. Caller can post-filter for fuzzier searches.
      // Block any quote/semicolon to prevent escaping.
      if (/['";`$\\]/.test(q)) { json(res, { error: 'invalid characters in q' }, 400); return; }
      args.push('query', `"email:${q}*"`);
    }
    const v = gamValidate('redirect', args);
    if (!v.ok) { json(res, { error: v.reason }, 400); return; }
    const r = await gamExec('redirect', args, meta);
    if (r.exitCode !== 0) { json(res, { error: r.stderr || 'gam failed', exitCode: r.exitCode }, 502); return; }
    const users = parseGamCSV(r.stdout);
    json(res, { users, count: users.length, ms: r.ms });
    return;
  }

  // GET /api/gam/files?q=<search>&user=<email> — search Drive files
  // Defaults to searching Neo's drives if user unspecified.
  if (urlPath === '/api/gam/files' && req.method === 'GET') {
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const q = (url.searchParams.get('q') || '').trim();
    const user = (url.searchParams.get('user') || 'neo@todak.com').trim();
    if (!q) { json(res, { error: 'q required (file name or content keyword)' }, 400); return; }
    if (/['";`$\\]/.test(q) || /['";`$\\]/.test(user)) {
      json(res, { error: 'invalid characters in q or user' }, 400); return;
    }
    // gam user <email> print filelist query "<q>" — emits CSV
    const args = ['csv', '-', 'user', user, 'print', 'filelist',
                  'query', `"name contains '${q}' or fullText contains '${q}'"`,
                  'fields', 'id,name,mimeType,size,modifiedTime,owners,webViewLink'];
    const v = gamValidate('redirect', args);
    if (!v.ok) { json(res, { error: v.reason }, 400); return; }
    const r = await gamExec('redirect', args, meta);
    if (r.exitCode !== 0) { json(res, { error: r.stderr || 'gam failed', exitCode: r.exitCode }, 502); return; }
    const files = parseGamCSV(r.stdout);
    json(res, { files, count: files.length, ms: r.ms, searched_as: user });
    return;
  }

  // GET /api/gam/file/:id/download?user=<email> — stream file bytes (Phase 4b Step 1B.5)
  // Two-stage: (1) SSH to TDCC, gam download to mktemp dir, capture metadata
  // (filename, size, full path); enforce 50MB cap. (2) SSH+cat to stream bytes
  // back, then `rm -rf` the tmp dir on TDCC. Audited.
  // Used by Siti's send_workspace_file_to_owner tool (recipient hardcoded
  // to Neo's primary phone there) — never lands as bytes-on-disk on Siti
  // VPS for longer than the wacli send_document call.
  const downloadMatch = urlPath.match(/^\/api\/gam\/file\/([A-Za-z0-9_-]+)\/download$/);
  if (downloadMatch && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const fileId = downloadMatch[1];
    const user = (url.searchParams.get('user') || 'neo@todak.com').trim();
    if (/['";`$\\\s]/.test(user)) { json(res, { error: 'invalid characters in user' }, 400); return; }
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const startedAt = Date.now();
    const SIZE_CAP = 50 * 1024 * 1024; // 50 MB

    // Stage script: download via gam, report metadata, leave file at known path.
    // Single-quoted shell strings around interpolated values prevent expansion;
    // both fileId and user are pre-validated regex-clean before we get here.
    const stageScript = `
set -e
TMP=$(mktemp -d /tmp/naca-dl-XXXXXX)
/home/neo/bin/gam7/gam user '${user}' get drivefile '${fileId}' targetfolder "$TMP" >/dev/null 2>&1 || (echo "ERROR:gam_failed" >&2; rm -rf "$TMP"; exit 1)
F=$(ls "$TMP" 2>/dev/null | head -1)
if [ -z "$F" ]; then rm -rf "$TMP"; echo "ERROR:no_file" >&2; exit 1; fi
SIZE=$(stat -c%s "$TMP/$F")
if [ "$SIZE" -gt ${SIZE_CAP} ]; then rm -rf "$TMP"; echo "ERROR:too_large_$SIZE" >&2; exit 1; fi
echo "PATH=$TMP/$F"
echo "FILENAME=$F"
echo "SIZE=$SIZE"
echo "TMPDIR=$TMP"
`;
    const stage = await new Promise((resolve) => {
      const proc = spawn('ssh', ['tdcc', stageScript], { timeout: 120_000 });
      let stdout = '', stderr = '';
      proc.stdout.on('data', d => stdout += d.toString());
      proc.stderr.on('data', d => stderr += d.toString());
      proc.on('close', code => resolve({ stdout, stderr, code }));
      proc.on('error', err => resolve({ stdout: '', stderr: err.message, code: -1 }));
    });

    if (stage.code !== 0) {
      gamLog({ ...meta, verb: 'download', args: { argv: ['get', 'drivefile', fileId, 'user='+user] }, exit_code: stage.code, output_summary: null, ms_elapsed: Date.now() - startedAt, error: stage.stderr.slice(0, 500) });
      const err = stage.stderr || '';
      if (err.includes('too_large')) {
        const m = err.match(/too_large_(\d+)/);
        json(res, { error: 'file too large for WhatsApp transfer', size: m ? parseInt(m[1]) : null, max: SIZE_CAP, hint: 'use webViewLink instead' }, 413); return;
      }
      if (err.includes('no_file')) {
        json(res, { error: 'no file downloaded — file not found, no access, or not a downloadable type' }, 404); return;
      }
      json(res, { error: err.slice(0, 200) || 'gam download failed', exitCode: stage.code }, 502); return;
    }

    // Parse PATH/FILENAME/SIZE/TMPDIR from stdout
    const map = {};
    for (const line of stage.stdout.split('\n')) {
      const eq = line.indexOf('=');
      if (eq > 0) map[line.slice(0, eq)] = line.slice(eq + 1);
    }
    const filePath = map.PATH;
    const filename = map.FILENAME;
    const size = parseInt(map.SIZE || '0');
    const tmpdir = map.TMPDIR;
    if (!filePath || !filename || !tmpdir) {
      json(res, { error: 'malformed staging metadata', stdout: stage.stdout.slice(0, 200) }, 502); return;
    }

    // Stream phase: ssh+cat the file, then cleanup tmpdir on TDCC.
    // Content-Disposition uses RFC 5987-safe ASCII fallback.
    const safeName = filename.replace(/[^\w\s.\-()]/g, '_');
    const ext = (filename.split('.').pop() || '').toLowerCase();
    const mimeMap = {
      pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg',
      gif: 'image/gif', svg: 'image/svg+xml', webp: 'image/webp',
      mp3: 'audio/mpeg', mp4: 'video/mp4', mov: 'video/quicktime', m4a: 'audio/mp4',
      ogg: 'audio/ogg', wav: 'audio/wav',
      doc: 'application/msword',
      docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      xls: 'application/vnd.ms-excel',
      xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ppt: 'application/vnd.ms-powerpoint',
      pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      txt: 'text/plain', csv: 'text/csv', json: 'application/json',
      zip: 'application/zip', tar: 'application/x-tar',
    };
    const contentType = mimeMap[ext] || 'application/octet-stream';

    res.writeHead(200, {
      'Content-Type': contentType,
      'Content-Disposition': `attachment; filename="${safeName}"`,
      'Content-Length': size,
      'X-NACA-Filename': encodeURIComponent(filename),
      'X-NACA-Source-User': user,
      'X-NACA-File-Id': fileId,
    });
    // The cat+rm pattern: if cat succeeds, rm runs. If cat fails, tmpdir lingers
    // on TDCC — accept this minor leak. A periodic /tmp cleanup pass on TDCC
    // (anything matching /tmp/naca-dl-*) would mop them up; not critical for now.
    const catScript = `cat '${filePath}' && rm -rf '${tmpdir}'`;
    const cat = spawn('ssh', ['tdcc', catScript], { timeout: 180_000 });
    cat.stdout.pipe(res);
    cat.on('close', code => {
      gamLog({ ...meta, verb: 'download', args: { argv: ['get', 'drivefile', fileId, 'user='+user, 'size='+size, 'name='+filename] }, exit_code: code, output_summary: `streamed ${size} bytes (${contentType})`, ms_elapsed: Date.now() - startedAt, error: code === 0 ? null : `cat exit ${code}` });
      if (!res.writableEnded) res.end();
    });
    cat.on('error', () => { if (!res.writableEnded) res.end(); });
    return;
  }

  // GET /api/gam/file/:id?user=<email> — fetch file metadata + small text excerpt
  // For text-like mimeTypes we pull a small excerpt; binary types return metadata only.
  const fileMatch = urlPath.match(/^\/api\/gam\/file\/([A-Za-z0-9_-]+)$/);
  if (fileMatch && req.method === 'GET') {
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const fileId = fileMatch[1];
    const user = (url.searchParams.get('user') || 'neo@todak.com').trim();
    if (/['";`$\\]/.test(user)) { json(res, { error: 'invalid characters in user' }, 400); return; }
    // Use `print filelist select <id>` — emits clean CSV like the search
    // endpoint, vs `show fileinfo` which uses a different output format.
    if (!/^[A-Za-z0-9_-]+$/.test(fileId)) { json(res, { error: 'invalid file id' }, 400); return; }
    const metaArgs = ['csv', '-', 'user', user, 'print', 'filelist', 'select', fileId,
                      'fields', 'id,name,mimeType,size,modifiedTime,owners,webViewLink'];
    const v = gamValidate('redirect', metaArgs);
    if (!v.ok) { json(res, { error: v.reason }, 400); return; }
    const r = await gamExec('redirect', metaArgs, meta);
    if (r.exitCode !== 0) { json(res, { error: r.stderr || 'gam failed', exitCode: r.exitCode }, 502); return; }
    const rows = parseGamCSV(r.stdout);
    if (!rows.length) { json(res, { error: 'file not found or no access' }, 404); return; }
    const fileMeta = rows[0];
    // For now we return metadata only; actual content fetch (gam user <u> get drivefile <id>)
    // writes to disk — deferred. UI shows webViewLink as the practical action.
    json(res, { file: fileMeta, ms: r.ms, accessed_as: user });
    return;
  }

  // GET /api/media/:id/blob — stream MinIO bytes over HTTPS
  // Fixes mixed-content: browsers refuse http://100.85.18.97:9000/... signed URLs
  // when the page is HTTPS. We sign + fetch server-side (HTTP fine on Tailscale)
  // and stream the bytes to the client over HTTPS.
  const mediaBlob = urlPath.match(/^\/api\/media\/([0-9a-f-]{36})\/blob$/);
  if (mediaBlob && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    if (!minioCfg) { json(res, { error: 'minio not configured (vault load pending or failed)' }, 503); return; }
    const mediaId = mediaBlob[1];
    try {
      const { data: row, error } = await supabase.from('media')
        .select('id, kind, mime_type, bytes, storage_url')
        .eq('id', mediaId)
        .maybeSingle();
      if (error || !row) { json(res, { error: 'media not found' }, 404); return; }
      const signedUrl = s3SignedGet(row.storage_url, 60);
      if (!signedUrl) { json(res, { error: 'failed to sign url' }, 500); return; }
      // Server-side fetch from MinIO (plain HTTP via Tailscale is fine here)
      const upstream = await new Promise((resolve, reject) => {
        const r = http.get(signedUrl, { timeout: 30_000 }, resolve);
        r.on('error', reject);
        r.on('timeout', () => { r.destroy(); reject(new Error('upstream timeout')); });
      });
      if (upstream.statusCode !== 200) {
        let body = '';
        upstream.on('data', c => body += c);
        upstream.on('end', () => json(res, { error: 'minio fetch failed', status: upstream.statusCode, body: body.slice(0, 200) }, 502));
        return;
      }
      res.writeHead(200, {
        'Content-Type': row.mime_type || upstream.headers['content-type'] || 'application/octet-stream',
        'Content-Length': upstream.headers['content-length'] || row.bytes || '',
        'Cache-Control': 'private, max-age=300',
        'X-NACA-Media-Id': mediaId,
        'X-NACA-Media-Kind': row.kind || '',
      });
      upstream.pipe(res);
    } catch (e) {
      json(res, { error: e.message }, 500);
    }
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
  // CONTENT DRAFTS — Phase 5c
  // Drafts come from CLAW daily-content generator (and future sources).
  // Operator reviews in NACA SCHED → DRAFTS lane → APPROVE/EDIT/REJECT.
  // On approve, we insert into scheduled_actions (action_kind='agent_command'
  // to_agent='claw-mac' command='post_to_<channel>') and link the draft via
  // scheduled_action_id. timekeeper fires the action at the chosen fire_at.
  // =============================================

  // GET /api/content-drafts?status=&since=&limit=
  if (urlPath === '/api/content-drafts' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const status = url.searchParams.get('status'); // pending_approval|approved|rejected|...
      const since = url.searchParams.get('since');
      const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '50'), 1), 200);
      let q = supabase.from('content_drafts').select('*').order('created_at', { ascending: false }).limit(limit);
      if (status) q = q.eq('status', status);
      if (since) q = q.gte('created_at', since);
      const { data, error } = await q;
      if (error) throw error;
      // Stats per status for the UI
      const counts = await Promise.all([
        supabase.from('content_drafts').select('id', { count: 'exact', head: true }).eq('status', 'pending_approval'),
        supabase.from('content_drafts').select('id', { count: 'exact', head: true }).eq('status', 'approved'),
        supabase.from('content_drafts').select('id', { count: 'exact', head: true }).eq('status', 'rejected'),
      ]);
      json(res, {
        drafts: data || [],
        stats: {
          pending: counts[0].count || 0,
          approved: counts[1].count || 0,
          rejected: counts[2].count || 0,
        },
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // PATCH /api/content-drafts/:id — edit caption (only on pending_approval)
  const draftEdit = urlPath.match(/^\/api\/content-drafts\/([0-9a-f-]{36})$/);
  if (draftEdit && req.method === 'PATCH') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = draftEdit[1];
    readBody(req, async (body) => {
      try {
        const patch = {};
        if ('caption' in body) patch.caption = body.caption?.toString() || '';
        if (!Object.keys(patch).length) { json(res, { error: 'no editable fields in body' }, 400); return; }
        const { data, error } = await supabase.from('content_drafts')
          .update(patch).eq('id', id).eq('status', 'pending_approval')
          .select().single();
        if (error) {
          if (error.code === 'PGRST116') { json(res, { error: 'draft not editable (already approved/rejected or not found)' }, 409); return; }
          throw error;
        }
        json(res, { ok: true, draft: data });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // POST /api/content-drafts/:id/approve  body: { channels: ['linkedin',...], fire_at: ISO }
  const draftApprove = urlPath.match(/^\/api\/content-drafts\/([0-9a-f-]{36})\/approve$/);
  if (draftApprove && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const draftId = draftApprove[1];
    readBody(req, async (body) => {
      try {
        const channels = Array.isArray(body.channels) ? body.channels : [];
        const allowedCh = ['linkedin', 'instagram', 'threads', 'tiktok', 'twitter', 'x'];
        const cleanCh = channels.map(c => c.toString().toLowerCase()).filter(c => allowedCh.includes(c));
        if (!cleanCh.length) { json(res, { error: `channels required (subset of ${allowedCh.join(', ')})` }, 400); return; }
        const fireAtRaw = (body.fire_at || '').toString().trim();
        if (!fireAtRaw) { json(res, { error: 'fire_at required' }, 400); return; }
        const fireAt = new Date(fireAtRaw);
        if (isNaN(fireAt.getTime())) { json(res, { error: 'fire_at not valid ISO 8601' }, 400); return; }
        if (fireAt.getTime() <= Date.now() - 60_000) {
          // allow tiny clock drift but reject "post 5 minutes ago"
          json(res, { error: 'fire_at must be now or future' }, 400); return;
        }

        // 1. Fetch the draft
        const { data: draft, error: dErr } = await supabase.from('content_drafts')
          .select('*').eq('id', draftId).maybeSingle();
        if (dErr) throw dErr;
        if (!draft) { json(res, { error: 'draft not found' }, 404); return; }
        if (draft.status !== 'pending_approval') {
          json(res, { error: `draft is ${draft.status}, can't re-approve` }, 409); return;
        }

        // 2. Insert a scheduled_action per channel (claw-mac dispatch).
        // Each platform gets its own scheduled_action so partial-success
        // (e.g. LinkedIn ok, IG fails) is visible per row.
        const mediaPath = (draft.media_paths?.[0]?.path) || null;
        const mediaKind = (draft.media_paths?.[0]?.kind) || 'video';
        const insertedActions = [];
        for (const channel of cleanCh) {
          const desc = `${channel} post: ${(draft.caption || '').slice(0, 50)}`;
          const { data: act, error: aErr } = await supabase.from('scheduled_actions').insert({
            fire_at: fireAt.toISOString(),
            action_kind: 'agent_command',
            action_payload: {
              from_agent: 'naca-app',
              to_agent: 'claw-mac',
              command: `post_to_${channel}`,
              payload: {
                caption: draft.caption,
                media_path: mediaPath,
                media_kind: mediaKind,
                media_host: 'claw-mac',
                draft_id: draftId,
                idempotency_key: `draft-${draftId}-${channel}`,
              },
            },
            status: 'scheduled',
            created_by: 'naca:operator',
            owner_subject_id: draft.owner_subject_id,
            description: desc,
          }).select().single();
          if (aErr) throw aErr;
          insertedActions.push(act);
        }

        // 3. Mark draft approved + link to first scheduled_action_id
        const { data: updated, error: uErr } = await supabase.from('content_drafts').update({
          status: 'approved',
          approved_at: new Date().toISOString(),
          approved_by: 'naca:operator',
          channels: cleanCh,
          scheduled_for: fireAt.toISOString(),
          scheduled_action_id: insertedActions[0].id,
        }).eq('id', draftId).select().single();
        if (uErr) throw uErr;

        json(res, { ok: true, draft: updated, scheduled_actions: insertedActions }, 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // POST /api/content-drafts/:id/reject  body: { reason }
  const draftReject = urlPath.match(/^\/api\/content-drafts\/([0-9a-f-]{36})\/reject$/);
  if (draftReject && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = draftReject[1];
    readBody(req, async (body) => {
      try {
        const reason = (body.reason || '').toString().slice(0, 200) || null;
        const { data, error } = await supabase.from('content_drafts')
          .update({
            status: 'rejected',
            rejected_at: new Date().toISOString(),
            rejected_reason: reason,
          })
          .eq('id', id).eq('status', 'pending_approval')
          .select().single();
        if (error) {
          if (error.code === 'PGRST116') { json(res, { error: 'draft not rejectable (already approved/rejected or not found)' }, 409); return; }
          throw error;
        }
        json(res, { ok: true, draft: data });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
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

  // POST /api/content/schedule — Phase 4 Step E2 first-slice (UI scaffold)
  // Creates a scheduled_action pointing at poster-agent. The agent itself
  // doesn't exist yet (TODO: spec at neo-brain memory). Operator-side data
  // flow goes live now so when poster-agent ships, queued posts just fire.
  if (urlPath === '/api/content/schedule' && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    readBody(req, async (body) => {
      try {
        const channel = (body.channel || '').toString().trim();
        const allowedChannels = ['linkedin', 'threads', 'instagram', 'tiktok', 'twitter'];
        if (!allowedChannels.includes(channel)) {
          json(res, { error: `channel must be one of: ${allowedChannels.join(', ')}` }, 400); return;
        }
        const caption = (body.caption || '').toString();
        if (!caption.trim()) { json(res, { error: 'caption required' }, 400); return; }
        const fireAtRaw = (body.fire_at || '').toString().trim();
        if (!fireAtRaw) { json(res, { error: 'fire_at required' }, 400); return; }
        const fireAt = new Date(fireAtRaw);
        if (isNaN(fireAt.getTime())) { json(res, { error: 'fire_at invalid ISO 8601' }, 400); return; }
        if (fireAt.getTime() <= Date.now()) { json(res, { error: 'fire_at must be in the future' }, 400); return; }
        // Optional attachment: drive file id OR neo-brain media id (one or the other)
        const driveFileId = body.drive_file_id ? body.drive_file_id.toString().trim() : null;
        const mediaId = body.media_id ? body.media_id.toString().trim() : null;
        if (driveFileId && !/^[A-Za-z0-9_-]+$/.test(driveFileId)) {
          json(res, { error: 'invalid drive_file_id' }, 400); return;
        }
        if (mediaId && !/^[0-9a-f-]{36}$/.test(mediaId)) {
          json(res, { error: 'invalid media_id (uuid expected)' }, 400); return;
        }
        const ownerId = (body.owner_subject_id || '00000000-0000-0000-0000-000000000001').toString();

        const description = `${channel} post: ${caption.slice(0, 60)}`;
        const actionPayload = {
          from_agent: 'naca-app',
          to_agent: 'poster-agent', // TODO: agent doesn't exist yet — see neo-brain memory for spec
          command: 'post_content',
          payload: {
            channel,
            caption,
            drive_file_id: driveFileId,
            media_id: mediaId,
          },
        };
        const { data, error } = await supabase.from('scheduled_actions').insert({
          fire_at: fireAt.toISOString(),
          action_kind: 'agent_command',
          action_payload: actionPayload,
          recurrence: null,
          status: 'scheduled',
          created_by: 'naca:operator',
          owner_subject_id: ownerId,
          description,
        }).select().single();
        if (error) throw error;
        json(res, { ok: true, action: data, note: 'poster-agent does not exist yet — this row will sit at status=scheduled until that agent ships' }, 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
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
    // Forward the original query string verbatim — urlPath is path-only,
    // so kind/person_id/limit etc. would be dropped without `url.search`.
    const queryString = url.search || '';

    // Read request body for POST/PATCH/DELETE
    readBody(req, (reqBody) => {
      const options = {
        hostname: 'localhost',
        port: 3800,
        path: sitiPath + queryString,
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
