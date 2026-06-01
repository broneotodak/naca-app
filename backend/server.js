// Backend changes auto-deploy via .github/workflows/deploy.yml — pushes to
// main fast-forward this checkout on the VPS and `pm2 restart naca-backend`.
require('dotenv').config();
const http = require('http');
const fs = require('fs');
const os = require('os');
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

// CTK audit-memory helper — fire-and-forget child_process spawn of the
// canonical save-memory.js script. Used by Studio v2 admin writes
// (agent_registry PATCH) so each operator action lands in neo-brain as
// a shared_infra_change row with an ACTION: first-line audit prefix.
// Best-effort: spawn failures log to stderr but don't fail the request.
// Knowledge writes must go through the SDK (DB trigger rejects raw POST
// with NULL embedding) — this helper inherits that contract.
const CTK_SAVE_MEMORY = path.resolve(os.homedir(), 'Projects/claude-tools-kit/tools/save-memory.js');
const CTK_SAVE_MEMORY_AVAILABLE = fs.existsSync(CTK_SAVE_MEMORY);
if (!CTK_SAVE_MEMORY_AVAILABLE) {
  console.warn('[NACA] CTK save-memory.js not found at', CTK_SAVE_MEMORY, '— Studio v2 audit memories will be skipped');
}
function writeAuditMemory({ action, agentName, operator, ok, detail }) {
  if (!CTK_SAVE_MEMORY_AVAILABLE) return;
  const { spawn } = require('child_process');
  const iso = new Date().toISOString();
  const firstLine = `ACTION: ${action} agent=${agentName} by=${operator || 'naca-app'} at=${iso} result=${ok ? 'ok' : 'error'}`;
  const body = detail ? `${firstLine}\n\n${detail}` : firstLine;
  const title = `Studio: ${action} ${agentName} (${ok ? 'ok' : 'error'})`;
  const child = spawn('node', [CTK_SAVE_MEMORY, 'shared_infra_change', title, body, '5'], {
    detached: true, stdio: 'ignore',
  });
  child.on('error', (e) => console.error('[audit-memory] spawn failed:', e.message));
  child.unref();
}

// === Studio v2 agent classifier ===
// MIRROR of @naca/tools/src/check-agent-status.js classify() — also mirrored
// in naca-monitor/src/checks/heartbeats.js (skip ladder there, classifier
// here). Drift contract: any change to the threshold table or branch order
// in the canonical @naca/tools file MUST be ported here and to naca-monitor
// in the same change set. See agent-registry-schema-v1.md §2.6 for the
// on_leave vs suppress_alerts distinction. This duplication is the MVP
// compromise — the canonical source is monorepo-local and naca-mcp-bridge
// speaks MCP not REST, so neither (a) workspace dep nor (c) HTTP-proxy
// landed cleanly in the time available.
const CLASSIFY_STALE_MS = 5 * 60 * 1000;
const CLASSIFY_DOWN_MS = 15 * 60 * 1000;
function cadenceWindowMinutes(cadence) {
  if (cadence === 'hourly') return 70;
  if (cadence === 'weekly') return 8 * 24 * 60;
  if (typeof cadence === 'string' && cadence.startsWith('daily')) return 25 * 60;
  return 24 * 60;
}
function classifyAgent({ ageMs, reg }) {
  if (reg?.status === 'archived') return 'retired';
  if (reg?.meta?.on_leave === true) return 'on_leave';
  if (reg?.meta?.suppress_alerts === true) return 'suppressed';
  const cadence = reg?.meta?.cadence;
  const isScheduled = reg?.meta?.always_running === false || cadence != null;
  if (isScheduled) {
    if (ageMs === null) return 'down';
    const okMs = cadenceWindowMinutes(cadence) * 60 * 1000;
    return ageMs <= okMs ? 'live' : 'down';
  }
  if (ageMs === null) return 'unknown';
  if (ageMs > CLASSIFY_DOWN_MS) return 'down';
  if (ageMs > CLASSIFY_STALE_MS) return 'stale';
  return 'live';
}

// === MinIO media bytes — fixes mixed-content for browser image render ======
// Pulls minio-nas creds from neo-brain credentials vault on boot. Replicates
// Siti's s3SignedGet helper (SigV4 presigned GET) so we can sign URLs without
// going through Siti. Used by /api/media/:id/blob to fetch MinIO bytes
// server-side (HTTP fine on Tailscale) and stream them over HTTPS to the
// browser — avoids the http://100.85.18.97:9000/... URLs that Chrome blocks
// on a https://naca.neotodak.com page.
// === GitHub @-mentionable agents — registry-driven (refactor v2 step 5) ====
// Replaces the previous hardcoded ['dev-agent','planner-agent','reviewer-agent','siti'].
// Adding a new mentionable agent is now a single registry edit:
//   UPDATE agent_registry SET meta = jsonb_set(meta, '{github_mentionable}', 'true')
// Cache TTL 5 min — webhook handler picks up changes on its next fire.
// Schema: broneotodak/naca docs/spec/agent-registry-schema-v1.md §2.4.
let mentionableAgentsCache = [];
let mentionableLoadedAt = 0;
const MENTIONABLE_TTL_MS = 5 * 60 * 1000;
async function getMentionableAgents() {
  if (Date.now() - mentionableLoadedAt < MENTIONABLE_TTL_MS && mentionableAgentsCache.length) {
    return mentionableAgentsCache;
  }
  if (!supabase) return mentionableAgentsCache; // graceful: keep prior cache
  try {
    const { data, error } = await supabase
      .from('agent_registry')
      .select('agent_name, meta')
      .eq('status', 'active');
    if (error) { console.warn('[mentionable] load failed:', error.message); return mentionableAgentsCache; }
    mentionableAgentsCache = (data || [])
      .filter(r => r.meta?.github_mentionable === true)
      .map(r => r.agent_name);
    mentionableLoadedAt = Date.now();
    return mentionableAgentsCache;
  } catch (e) { console.warn('[mentionable] load error:', e.message); return mentionableAgentsCache; }
}

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

// --- NAS draft-media staging ----------------------------------------------
// content-creator writes draft videos to the Ugreen NAS filesystem. To serve
// them with HTTP Range (iOS video playback REQUIRES 206/Range — an SSH-cat
// pipe has no size and can't seek), we stage the file to a local tempfile
// once, then serve it range-capable from disk. Draft media is immutable, so a
// staged file is reused indefinitely. An in-flight Map collapses the
// concurrent connections iOS opens for one video into a single SSH fetch.
const NACA_MEDIA_CACHE = path.join(os.tmpdir(), 'naca-draft-media');
const stagingInFlight = new Map(); // cacheFile -> Promise

function stageNasFile(remotePath, cacheFile) {
  try { if (fs.statSync(cacheFile).size > 0) return Promise.resolve(); } catch { /* not staged yet */ }
  if (stagingInFlight.has(cacheFile)) return stagingInFlight.get(cacheFile);
  const p = new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
    const tmp = cacheFile + '.part';
    const out = fs.createWriteStream(tmp);
    // spawn arg-array (no shell our side); remote path single-quoted so the
    // NAS shell keeps spaces as one arg.
    const proc = spawn('ssh', [
      '-i', `${process.env.HOME}/.ssh/id_naca_nas`,
      '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
      'Neo@100.85.18.97', `cat '${remotePath}'`,
    ], { timeout: 180_000 });
    let errBuf = '';
    proc.stdout.pipe(out);
    proc.stderr.on('data', d => { errBuf += d.toString(); });
    proc.on('error', err => { out.destroy(); try { fs.unlinkSync(tmp); } catch {} reject(err); });
    proc.on('close', code => {
      out.end(() => {
        if (code !== 0) { try { fs.unlinkSync(tmp); } catch {} return reject(new Error(`ssh exit ${code}: ${errBuf.slice(0, 200)}`)); }
        try {
          if (fs.statSync(tmp).size === 0) { fs.unlinkSync(tmp); return reject(new Error('empty file from nas')); }
          fs.renameSync(tmp, cacheFile); // atomic — concurrent readers see the whole file or nothing
          resolve();
        } catch (e) { reject(e); }
      });
    });
  }).finally(() => stagingInFlight.delete(cacheFile));
  stagingInFlight.set(cacheFile, p);
  return p;
}

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

// NEO_SELF_ID — Neo's canonical person id in neo-brain.people.
// Treated as delete-protected by the people endpoints below (matches the
// v1 siti server.js safety rail — feedback memory project_naca_app §
// "Identity editing in NACA (2026-04-24)").
const NEO_SELF_ID = '00000000-0000-0000-0000-000000000001';

// applyPersonPatch — ported from siti/server.js (v1 monolith, line 604).
// Pure logic + Supabase update. Returns { ok, data, changed } or { error }.
// Differences from v1: drops in-memory personCache index + SSE broadcast
// (naca-backend doesn't keep a cache; NACA App uses Supabase Realtime if
// it wants live updates). Field semantics are byte-for-byte identical so
// the v1 PEOPLE UI behaviour migrates without surprises.
async function applyPersonPatch(person, args) {
  if (!person) return { error: 'person required' };
  if (!supabase) return { error: 'neo-brain not configured' };
  const patch = {};
  const changed = [];

  if (typeof args.display_name === 'string' && args.display_name.trim()) {
    patch.display_name = args.display_name.trim();
    changed.push('display_name');
  }
  if (typeof args.push_name === 'string') {
    patch.push_name = args.push_name.trim() || null;
    changed.push('push_name');
  }
  if (typeof args.relationship === 'string') {
    patch.relationship = args.relationship.trim() || null;
    changed.push('relationship');
  }
  if (typeof args.bio === 'string') {
    patch.bio = args.bio.trim() || null;
    changed.push('bio');
  }
  if (Array.isArray(args.languages)) {
    patch.languages = args.languages.map((s) => String(s).trim()).filter(Boolean);
    changed.push('languages');
  }

  // Nicknames — add/remove/replace with case-insensitive dedup
  let nextNicks = Array.isArray(person.nicknames) ? [...person.nicknames] : [];
  if (Array.isArray(args.replace_nicknames)) {
    nextNicks = args.replace_nicknames.map((s) => String(s).trim()).filter(Boolean);
    changed.push('nicknames(replaced)');
  } else {
    if (Array.isArray(args.add_nicknames) && args.add_nicknames.length) {
      let added = 0;
      for (const raw of args.add_nicknames) {
        const n = String(raw).trim();
        if (!n) continue;
        if (!nextNicks.some((x) => String(x).toLowerCase() === n.toLowerCase())) {
          nextNicks.push(n); added++;
        }
      }
      if (added) changed.push('nicknames(+' + added + ')');
    }
    if (Array.isArray(args.remove_nicknames) && args.remove_nicknames.length) {
      const removeSet = new Set(args.remove_nicknames.map((s) => String(s).trim().toLowerCase()));
      const before = nextNicks.length;
      nextNicks = nextNicks.filter((x) => !removeSet.has(String(x).toLowerCase()));
      if (nextNicks.length !== before) changed.push('nicknames(-' + (before - nextNicks.length) + ')');
    }
  }
  if (changed.some((c) => c.startsWith('nicknames'))) patch.nicknames = nextNicks;

  // Facts — add (max 30 cap, dedup) OR direct replace
  if (Array.isArray(args.add_facts) && args.add_facts.length) {
    const existing = Array.isArray(person.facts) ? [...person.facts] : [];
    const lowered = new Set(existing.map((f) => String(f).toLowerCase()));
    let added = 0;
    for (const raw of args.add_facts) {
      const f = String(raw).trim();
      if (!f) continue;
      if (!lowered.has(f.toLowerCase())) { existing.push(f); lowered.add(f.toLowerCase()); added++; }
    }
    if (added) { patch.facts = existing.slice(0, 30); changed.push('facts(+' + added + ')'); }
  }
  if (!args.add_facts && Array.isArray(args.facts)) {
    patch.facts = args.facts.map((s) => String(s).trim()).filter(Boolean).slice(0, 30);
    changed.push('facts(replaced)');
  }

  // Traits — same shape as facts
  if (Array.isArray(args.add_traits) && args.add_traits.length) {
    const existing = Array.isArray(person.traits) ? [...person.traits] : [];
    const lowered = new Set(existing.map((f) => String(f).toLowerCase()));
    let added = 0;
    for (const raw of args.add_traits) {
      const t = String(raw).trim();
      if (!t) continue;
      if (!lowered.has(t.toLowerCase())) { existing.push(t); lowered.add(t.toLowerCase()); added++; }
    }
    if (added) { patch.traits = existing.slice(0, 30); changed.push('traits(+' + added + ')'); }
  }
  if (!args.add_traits && Array.isArray(args.traits)) {
    patch.traits = args.traits.map((s) => String(s).trim()).filter(Boolean).slice(0, 30);
    changed.push('traits(replaced)');
  }

  if (Object.keys(patch).length === 0) return { error: 'no fields to update' };
  patch.updated_at = new Date().toISOString();

  const { data, error } = await supabase.from('people').update(patch).eq('id', person.id).select().maybeSingle();
  if (error) return { error: error.message };
  if (!data) return { error: 'update returned no row' };
  return { ok: true, data, changed };
}

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

  // Auth: prefer `Authorization: Bearer <token>` header. Also accept the same
  // token as a `?token=` query param so external launchers (iOS Safari opening
  // a video URL via url_launcher.externalApplication) can pass auth without
  // headers. Same token value either way — no relaxation of access control.
  // Only used today by /api/media/:id/blob (video/audio open-in-system-player).
  const url = new URL(req.url, `http://${req.headers.host}`);
  const urlPath = url.pathname;
  const headerAuth = req.headers.authorization;
  const queryToken = url.searchParams.get('token');
  const authedByHeader = headerAuth === `Bearer ${AUTH_TOKEN}`;
  const authedByQuery = queryToken === AUTH_TOKEN;
  if (!authedByHeader && !authedByQuery) {
    res.writeHead(401, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Unauthorized' }));
    return;
  }

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
  // PEOPLE — Identity CRUD (ported from siti v1, 2026-05-14)
  // Replaces /api/siti/api/people/:id PATCH+DELETE that went 502 after the
  // v1 monolith on port 3800 was stopped. See docs/spec/siti-v2-endpoint-gap.md.
  // =============================================

  // PATCH /api/people/:id — edit display_name / push_name / relationship /
  // bio / languages / nicknames / facts / traits. Body shape matches v1
  // applyPersonPatch args. Returns { ok, person, changed }.
  const peopleEditMatch = urlPath.match(/^\/api\/people\/([0-9a-f-]{36})$/);
  if (peopleEditMatch && req.method === 'PATCH') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = peopleEditMatch[1];
    readBody(req, async (body) => {
      try {
        const { data: person, error: fetchErr } = await supabase.from('people').select('*').eq('id', id).maybeSingle();
        if (fetchErr) { json(res, { error: fetchErr.message }, 500); return; }
        if (!person) { json(res, { error: 'person not found' }, 404); return; }
        const result = await applyPersonPatch(person, body || {});
        if (result.error) { json(res, { error: result.error }, 400); return; }
        json(res, { ok: true, person: result.data, changed: result.changed });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // DELETE /api/people/:id — refuses NEO_SELF_ID; otherwise hard-deletes.
  if (peopleEditMatch && req.method === 'DELETE') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = peopleEditMatch[1];
    if (id === NEO_SELF_ID) { json(res, { error: 'refusing to delete self-identity' }, 400); return; }
    try {
      const { data, error } = await supabase.from('people').delete().eq('id', id).select('id, display_name').maybeSingle();
      if (error) { json(res, { error: error.message }, 500); return; }
      if (!data) { json(res, { error: 'person not found' }, 404); return; }
      json(res, { ok: true, id, display_name: data.display_name });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // =============================================
  // SITI STATUS — aggregator (Surface 3 of siti-v2 gap, 2026-05-14)
  // Replaces /api/siti/api/status + /api/siti/api/health that went 502
  // when the v1 monolith on port 3800 was intentionally stopped.
  // Reads agent_heartbeats for the two v2 processes (siti-ingest +
  // siti-router) and derives a single "is Siti alive?" verdict. See
  // docs/spec/siti-v2-endpoint-gap.md for the migration plan.
  // =============================================

  // GET /api/siti-status — { status, contacts, instance_slug, hostname,
  //   ingest, router, age_sec }. Response shape covers all 3 Dart
  // consumer sites (HQ services panel, HQ SITI agent row, CFG SITI test).
  if (urlPath === '/api/siti-status' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const FRESH_THRESHOLD_SEC = 360; // matches agent_registry.siti.meta.monitor_threshold_sec
      const { data: hbRows, error } = await supabase.from('agent_heartbeats')
        .select('agent_name, status, meta, reported_at')
        .in('agent_name', ['siti-ingest', 'siti-router']);
      if (error) throw error;
      const now = Date.now();
      const lookup = {};
      for (const r of (hbRows || [])) {
        const ageSec = Math.floor((now - new Date(r.reported_at).getTime()) / 1000);
        lookup[r.agent_name] = {
          status: r.status,
          age_sec: ageSec,
          fresh: ageSec < FRESH_THRESHOLD_SEC,
          meta: r.meta || {},
        };
      }
      const ingest = lookup['siti-ingest'] || null;
      const router = lookup['siti-router'] || null;
      const bothFresh = !!ingest?.fresh && !!router?.fresh;
      const eitherFresh = !!ingest?.fresh || !!router?.fresh;
      const overallStatus = bothFresh ? 'connected' : (eitherFresh ? 'degraded' : 'offline');

      // contacts — count of distinct WA contacts as a proxy for "Siti's
      // address book size" (what the old v1 surface displayed).
      let contacts = null;
      try {
        const { count } = await supabase.from('people').select('id', { count: 'exact', head: true }).not('phone', 'is', null);
        contacts = count;
      } catch { /* best-effort */ }

      // Return shape covers every consumer field:
      //   status        — site 1 + 3 (badge colour)
      //   contacts      — site 1 (display)
      //   instance_slug — site 1 (meta display)
      //   hostname      — site 3 (CFG connection-test detail)
      //   ingest/router — debug fields for future SITI tab use
      //   age_sec       — whichever is more recent
      const newestAge = Math.min(
        ingest ? ingest.age_sec : Number.POSITIVE_INFINITY,
        router ? router.age_sec : Number.POSITIVE_INFINITY,
      );
      json(res, {
        status: overallStatus,
        contacts,
        instance_slug: 'siti-vps',
        hostname: 'siti-vps (Hetzner)',
        ingest: ingest ? { fresh: ingest.fresh, age_sec: ingest.age_sec, status: ingest.status, version: ingest.meta?.version || null } : null,
        router: router ? { fresh: router.fresh, age_sec: router.age_sec, status: router.status, version: router.meta?.version || null } : null,
        age_sec: Number.isFinite(newestAge) ? newestAge : null,
      });
    } catch (e) { json(res, { error: e.message }, 500); }
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
        // `error` is not a column on agent_commands — failure details live in `result.error`.
        supabase.from('agent_commands').select('to_agent, from_agent, status, result, command, created_at').gte('created_at', since),
        supabase.from('gam_audit').select('requested_by, verb, exit_code, ms_elapsed, error, created_at').gte('created_at', since),
        // memory_writes_log columns: written_by + written_at
        // (no `source`, no `created_at` — common copy-paste hazard).
        supabase.from('memory_writes_log').select('written_by, written_at').gte('written_at', since),
      ]);
      const heartbeats = hb.data || [];
      const commands = cmds.data || [];
      const gamCalls = gam.data || [];
      const memCounts = (memWrites.data || []).reduce((acc, r) => { acc[r.written_by || '?'] = (acc[r.written_by || '?'] || 0) + 1; return acc; }, {});

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
          const errMsg = c.result?.error || c.result?.message;
          if (a.recent_failures.length < 3 && errMsg) a.recent_failures.push((c.command + ': ' + errMsg).slice(0, 100));
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

  // GET /api/agents/registry — full agent_registry rows for Studio v2 AGENTS view.
  // Returns the canonical columns Studio needs to render an agent card +
  // the full meta blob (host, runtime, on_leave, suppress_alerts, cadence,
  // always_running, version, etc.) — Flutter client picks what it renders.
  if (urlPath === '/api/agents/registry' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const { data, error } = await supabase.from('agent_registry')
        .select('agent_name, display_name, emoji, role_description, host, agent_type, status, meta, updated_at')
        .order('agent_name', { ascending: true });
      if (error) throw error;
      json(res, { rows: data || [] });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // PATCH /api/agents/registry/:agent_name — operator-write surface for
  // Studio v2 (pause/resume an agent). MVP whitelist: only meta.on_leave
  // and meta.leave_started_at are writable; any other meta key is
  // rejected so future scope additions (cost caps, etc.) are explicit.
  // Read-modify-write on the meta JSONB — no jsonb_set RPC; solo-operator
  // collision risk is acceptable. Fires a shared_infra_change audit
  // memory via CTK save-memory.js (ACTION: prefix per Studio v2 design
  // Q6 — operator audit trail is queryable by grep over memories).
  const registryPatch = urlPath.match(/^\/api\/agents\/registry\/([^/]+)$/);
  if (registryPatch && req.method === 'PATCH') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const agentName = decodeURIComponent(registryPatch[1]);
    readBody(req, async (body) => {
      const operator = (typeof body?.operator === 'string' && body.operator.trim())
        ? body.operator.trim().slice(0, 64) : 'naca-app';
      try {
        const patch = body?.meta_patch || {};
        if (typeof patch !== 'object' || Array.isArray(patch)) {
          json(res, { error: 'meta_patch must be an object' }, 400); return;
        }
        const allowedKeys = new Set(['on_leave', 'leave_started_at']);
        for (const key of Object.keys(patch)) {
          if (!allowedKeys.has(key)) {
            json(res, { error: `meta_patch key "${key}" not in MVP whitelist (allowed: ${[...allowedKeys].join(', ')})` }, 400);
            return;
          }
        }
        if ('on_leave' in patch && typeof patch.on_leave !== 'boolean' && patch.on_leave !== null) {
          json(res, { error: 'on_leave must be boolean or null' }, 400); return;
        }
        if ('leave_started_at' in patch && patch.leave_started_at !== null) {
          if (typeof patch.leave_started_at !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(patch.leave_started_at)) {
            json(res, { error: 'leave_started_at must be ISO-8601 string or null' }, 400); return;
          }
        }
        // Classify action verb for the audit ACTION: prefix. on_leave
        // changes get pause/resume; everything else is generic meta_update.
        // Computed before DB calls so the error path can audit the same
        // verb as the success path would have.
        const action = patch.on_leave === true ? 'pause'
          : patch.on_leave === false ? 'resume'
          : 'meta_update';
        const { data: row, error: readErr } = await supabase.from('agent_registry')
          .select('meta').eq('agent_name', agentName).maybeSingle();
        if (readErr) throw readErr;
        if (!row) {
          writeAuditMemory({ action, agentName, operator, ok: false, detail: 'not_found' });
          json(res, { error: `agent "${agentName}" not found` }, 404); return;
        }
        const newMeta = { ...(row.meta || {}) };
        for (const [k, v] of Object.entries(patch)) {
          if (v === null || v === undefined) delete newMeta[k];
          else newMeta[k] = v;
        }
        const { data: updated, error: writeErr } = await supabase.from('agent_registry')
          .update({ meta: newMeta }).eq('agent_name', agentName).select().single();
        if (writeErr) throw writeErr;
        writeAuditMemory({
          action, agentName, operator, ok: true,
          detail: `patch=${JSON.stringify(patch)}`,
        });
        json(res, { ok: true, row: updated });
      } catch (e) {
        // Best-effort audit on error; if patch was malformed we never got
        // an action verb so fall back to meta_update.
        writeAuditMemory({
          action: 'meta_update', agentName, operator, ok: false,
          detail: `error=${e.message}`,
        });
        json(res, { error: e.message }, 500);
      }
    });
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

  // GET /api/studio/agents — Studio v2 AGENTS view data source.
  // Joins agent_registry + agent_heartbeats and classifies each row
  // server-side so Flutter doesn't reimplement the classifier (see the
  // MIRROR comment above classifyAgent). Returned shape is render-ready:
  // {rows: [{agent_name, display_name, emoji, host, agent_type, status,
  //          meta, heartbeat_age_s, last_reported_at, classification}]}.
  // Sorted: archived/retired pushed to bottom, then by classification
  // urgency (down > stale > on_leave > suppressed > live), then name.
  if (urlPath === '/api/studio/agents' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const [regResp, hbResp] = await Promise.all([
        supabase.from('agent_registry')
          .select('agent_name, display_name, emoji, role_description, host, agent_type, status, meta, updated_at'),
        supabase.from('agent_heartbeats')
          .select('agent_name, status, reported_at')
          .order('reported_at', { ascending: false }),
      ]);
      if (regResp.error) throw regResp.error;
      if (hbResp.error) throw hbResp.error;
      // Pick the most-recent heartbeat per agent (the select is already
      // ordered DESC so first occurrence wins).
      const latestHb = new Map();
      for (const h of hbResp.data || []) {
        if (!latestHb.has(h.agent_name)) latestHb.set(h.agent_name, h);
      }
      const now = Date.now();
      const rows = (regResp.data || []).map((reg) => {
        const hb = latestHb.get(reg.agent_name) || null;
        const ageMs = hb?.reported_at ? now - new Date(hb.reported_at).getTime() : null;
        const classification = classifyAgent({ ageMs, reg });
        return {
          agent_name: reg.agent_name,
          display_name: reg.display_name,
          emoji: reg.emoji,
          role_description: reg.role_description,
          host: reg.host,
          agent_type: reg.agent_type,
          status: reg.status,
          meta: reg.meta || {},
          heartbeat_age_s: ageMs !== null ? Math.round(ageMs / 1000) : null,
          last_reported_at: hb?.reported_at || null,
          classification,
        };
      });
      // Sort urgency-first: operator should see problems before steady-state.
      const urgency = { down: 0, stale: 1, on_leave: 2, suppressed: 3, live: 4, unknown: 5, retired: 6 };
      rows.sort((a, b) => {
        const ua = urgency[a.classification] ?? 99;
        const ub = urgency[b.classification] ?? 99;
        if (ua !== ub) return ua - ub;
        return a.agent_name.localeCompare(b.agent_name);
      });
      json(res, { rows });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/studio/jobs — Studio v2 JOBS view data source. SCOPED to the
  // content pipeline (this is the Studio tab, not a fleet-wide command log).
  // Three buckets:
  //   running  — agent_commands in flight (status not done/failed/cancelled)
  //   recent   — agent_commands finished (status done|failed), newest first
  //   upcoming — scheduled_actions that drive a studio agent, soonest first
  // STUDIO SCOPE is derived from agent_registry at runtime (NOT a hardcoded
  // agent list — Agent Plug & Play): agents whose meta.chain is 'creative' or
  // 'publisher'. This keeps fleet noise (siti send_whatsapp_notification,
  // reviewer review_pr, etc.) out of the Studio view; a new content agent
  // shows up automatically once its registry row is chain-tagged.
  // Bucketing is by STATUS, not completed_at (cancelled commands leave
  // completed_at NULL — a backlog of expired-cancelled rows would otherwise
  // masquerade as "running"). payload/action_payload blobs are stripped to
  // keep it lean; `result` is kept so failed jobs show their error.
  if (urlPath === '/api/studio/jobs' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '25'), 1), 100);

      // Resolve the studio agent set from the registry (chain = creative|publisher).
      const STUDIO_CHAINS = new Set(['creative', 'publisher']);
      const reg = await supabase.from('agent_registry').select('agent_name, meta');
      if (reg.error) throw reg.error;
      const studioAgents = (reg.data || [])
        .filter((a) => STUDIO_CHAINS.has(a.meta?.chain))
        .map((a) => a.agent_name);
      if (!studioAgents.length) {
        json(res, { studio_agents: [], running: [], recent: [], upcoming: [], stats: { running: 0, recent_done: 0, recent_failed: 0, upcoming: 0 } });
        return;
      }
      const studioSet = new Set(studioAgents);

      const cmdCols = 'id, from_agent, to_agent, command, status, priority, retry_count, max_retries, created_at, claimed_at, completed_at, expires_at, result';
      const [running, recent, upcomingRaw] = await Promise.all([
        supabase.from('agent_commands').select(cmdCols)
          .in('to_agent', studioAgents)
          .not('status', 'in', '(done,failed,cancelled)').order('created_at', { ascending: false }).limit(limit),
        supabase.from('agent_commands').select(cmdCols)
          .in('to_agent', studioAgents)
          .in('status', ['done', 'failed']).order('created_at', { ascending: false }).limit(limit),
        // Wider scheduled slice; scope by the action's target agent in JS
        // (need action_payload to read to_agent — stripped from the response).
        supabase.from('scheduled_actions')
          .select('id, fire_at, action_kind, action_payload, status, attempts, max_attempts, recurrence, description, created_by, created_at')
          .eq('status', 'scheduled').order('fire_at', { ascending: true }).limit(limit * 4),
      ]);
      if (running.error) throw running.error;
      if (recent.error) throw recent.error;
      if (upcomingRaw.error) throw upcomingRaw.error;

      const upcoming = (upcomingRaw.data || [])
        .filter((s) => studioSet.has(s.action_payload?.to_agent))
        .slice(0, limit)
        .map(({ action_payload, ...rest }) => ({
          ...rest,
          to_agent: action_payload?.to_agent || null,
          command: action_payload?.command || null,
        }));

      const recentRows = recent.data || [];
      json(res, {
        studio_agents: studioAgents,
        running: running.data || [],
        recent: recentRows,
        upcoming,
        stats: {
          running: (running.data || []).length,
          recent_done: recentRows.filter((r) => r.status === 'done').length,
          recent_failed: recentRows.filter((r) => r.status === 'failed').length,
          upcoming: upcoming.length,
        },
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/studio/costs — Studio v2 COST view, provider-activity half.
  // Month-to-date generation activity per provider from creator_billing.
  // IMPORTANT: creator_billing logs usage EVENTS, not dollars — usd_cents is
  // currently NULL on every row, so `cost_tracked` is false and the client
  // shows event counts (not fabricated $). If per-call pricing is ever wired
  // into usd_cents, the same shape starts reporting real dollars automatically.
  // The subscriptions/bills half of the COST tab comes from GET /api/costs.
  if (urlPath === '/api/studio/costs' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const now = new Date();
      const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString();
      const { data, error } = await supabase.from('creator_billing')
        .select('tool_name, status, kind, usd_cents')
        .gte('created_at', monthStart);
      if (error) throw error;
      const rows = data || [];
      const byProvider = {};
      let billedCents = 0;
      for (const r of rows) {
        const k = r.tool_name || 'unknown';
        const p = byProvider[k] || (byProvider[k] = { tool_name: k, events: 0, ok: 0, failed: 0, usd_cents: 0, has_usd: false });
        p.events += 1;
        if (r.status === 'success') p.ok += 1;
        else if (r.status === 'failed') p.failed += 1;
        if (r.usd_cents != null) { p.usd_cents += r.usd_cents; p.has_usd = true; billedCents += r.usd_cents; }
      }
      const providers = Object.values(byProvider).sort((a, b) => b.events - a.events);
      json(res, {
        window: 'month-to-date',
        month: monthStart.slice(0, 7),
        providers,
        totals: {
          events: rows.length,
          billed_usd: billedCents / 100,
          cost_tracked: billedCents > 0,
        },
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // POST /api/agents/run-now — operator-triggered immediate agent run.
  // Tightly ALLOWLISTED (not an arbitrary command bus): today only
  // content-creator/generate_theme — the "generate today's content now"
  // action behind the Studio RUN NOW button. Inserts an agent_commands row
  // the agent claims on its next poll; output lands as a draft for the normal
  // approval flow (this does NOT post to public channels — that stays gated
  // behind /api/content-drafts/:id/approve). Refuses if the target is
  // operator-paused (on_leave), since the agent would skip a queued command.
  if (urlPath === '/api/agents/run-now' && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    readBody(req, async (body) => {
      try {
        const agent = (body.agent || 'content-creator').toString();
        const command = (body.command || 'generate_theme').toString();
        const ALLOWED = { 'content-creator': ['generate_theme'] };
        if (!ALLOWED[agent] || !ALLOWED[agent].includes(command)) {
          json(res, { error: `run-now not allowed for ${agent}/${command}` }, 400); return;
        }
        // Build a payload from known-safe fields only.
        const payload = {};
        if (command === 'generate_theme' && body.template_key) {
          payload.template_key = String(body.template_key);
        }
        // Refuse on operator pause — a queued command would just be skipped.
        const { data: regRows, error: regErr } = await supabase
          .from('agent_registry').select('meta').eq('agent_name', agent).limit(1);
        if (regErr) throw regErr;
        if (regRows?.[0]?.meta?.on_leave === true) {
          json(res, { error: `${agent} is paused (on_leave) — resume it on HQ before running`, on_leave: true }, 409);
          return;
        }
        const { data, error } = await supabase.from('agent_commands').insert({
          from_agent: 'naca-app',
          to_agent: agent,
          command,
          payload,
          priority: 8,
        }).select('id, to_agent, command, payload, status, created_at').single();
        if (error) throw error;
        json(res, { ok: true, command: data, note: 'queued — watch the JOBS tab' }, 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
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

  // GET /api/gam/users-quota?limit=N&domain=todak.com&org_unit=/path
  // Top N Workspace users by Drive storage used. Wraps `gam report users`
  // (Admin Reports API). Optional filters:
  //   domain    — restrict to one email domain (e.g. todak.com filters out
  //               @hyleen.my, @todak.id since the Workspace hosts multiple
  //               companies). Post-filter on email suffix, case-insensitive.
  //   org_unit  — passed through as `gam report users orgunitpath <path>`.
  //               More precise than domain (e.g. "/Todak Studios/Engineering")
  //               but caller must know the exact OU path.
  if (urlPath === '/api/gam/users-quota' && req.method === 'GET') {
    const meta = { from_agent: 'naca-app', requested_by: req.headers['x-requested-by'] || null };
    const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '10'), 1), 50);
    const domain = (url.searchParams.get('domain') || '').trim().toLowerCase().replace(/^@/, '');
    const orgUnit = (url.searchParams.get('org_unit') || '').trim();
    // GAM's per-user drive storage report: `gam all users print drivequota`
    // emits CSV with: User, Drive Used (GB), Drive Used (Bytes), Total quota, etc.
    // We scan all rows + sort by bytes desc.
    // Validate org_unit early
    if (orgUnit && /['";`$\\]/.test(orgUnit)) {
      json(res, { error: 'invalid characters in org_unit' }, 400); return;
    }
    // GAM's Admin Reports API doesn't support OU filtering server-side, so
    // when org_unit is set, fetch the user→OU map first via `print users` and
    // post-filter. When org_unit is empty, skip that query (faster).
    let ouByEmail = null;
    if (orgUnit) {
      const ouArgs = ['csv', '-', 'print', 'users', 'fields', 'primaryEmail,orgUnitPath'];
      const ouVal = gamValidate('redirect', ouArgs);
      if (!ouVal.ok) { json(res, { error: ouVal.reason }, 400); return; }
      const ouRun = await gamExec('redirect', ouArgs, meta);
      if (ouRun.exitCode !== 0) { json(res, { error: 'gam OU query failed: ' + ouRun.stderr.slice(0, 200), exitCode: ouRun.exitCode }, 502); return; }
      const ouRows = parseGamCSV(ouRun.stdout);
      ouByEmail = {};
      for (const u of ouRows) {
        const email = (u.primaryEmail || u.email || '').toLowerCase();
        const path = u.orgUnitPath || u.orgUnit || '';
        if (email) ouByEmail[email] = path;
      }
    }
    // Now the bulk quota report (no OU filter — that's done client-side)
    const args = ['csv', '-', 'report', 'users', 'parameters',
      'accounts:total_quota_in_mb,accounts:used_quota_in_mb,accounts:drive_used_quota_in_mb,accounts:gmail_used_quota_in_mb,accounts:gplus_photos_used_quota_in_mb'];
    const v = gamValidate('redirect', args);
    if (!v.ok) { json(res, { error: v.reason }, 400); return; }
    const r = await gamExec('redirect', args, meta);
    if (r.exitCode !== 0) { json(res, { error: r.stderr || 'gam failed', exitCode: r.exitCode }, 502); return; }
    const rows = parseGamCSV(r.stdout);
    // Headers vary by GAM version. Detect:
    //   email column   → "User", "Email", "primaryEmail"
    //   bytes column   → "usage.driveUsedInBytes", "Drive Used (Bytes)", "totalUsageBytes" etc.
    const sample = rows[0] || {};
    const emailKey = Object.keys(sample).find(k => /^(user|primaryemail|email)$/i.test(k)) || 'email';
    // Admin Reports API columns end in _in_mb / _in_kb / _in_bytes; pick the
    // most relevant Drive column and normalize units.
    const driveKey = Object.keys(sample).find(k => /drive.*used.*quota/i.test(k));
    const totalKey = Object.keys(sample).find(k => /^accounts:used_quota/i.test(k));
    const quotaKey = driveKey || totalKey;
    const unitMultiplier = quotaKey?.includes('_in_mb') ? 1024 * 1024
                         : quotaKey?.includes('_in_kb') ? 1024
                         : 1;
    let ranked = rows.map(row => {
      const raw = parseInt(row[quotaKey] || '0') || 0;
      const bytes = raw * unitMultiplier;
      const email = row[emailKey];
      return {
        email,
        bytes_used: bytes,
        gb_used: +(bytes / 1e9).toFixed(2),
        org_unit: ouByEmail ? (ouByEmail[email?.toLowerCase()] || null) : undefined,
      };
    }).filter(r => r.email && r.bytes_used > 0);
    if (domain) {
      ranked = ranked.filter(r => r.email.toLowerCase().endsWith('@' + domain));
    }
    if (orgUnit) {
      // Match exact path or any descendant ("/Todak Studios" matches "/Todak Studios/Engineering")
      const ouLc = orgUnit.toLowerCase();
      ranked = ranked.filter(r => {
        const u = (r.org_unit || '').toLowerCase();
        return u === ouLc || u.startsWith(ouLc + '/');
      });
    }
    ranked = ranked.sort((a, b) => b.bytes_used - a.bytes_used).slice(0, limit);
    json(res, {
      top_users: ranked,
      total_users_scanned: rows.length,
      filtered_by: { domain: domain || null, org_unit: orgUnit || null },
      email_field: emailKey, quota_field: quotaKey, unit_multiplier: unitMultiplier, ms: r.ms,
    });
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

  // GET /api/media?kind=&person_id=&since=&q=&limit= — browse/search media catalog
  // Migrated from Siti v1 /api/media (port 3800) which was killed when legacy siti
  // pm2 was stopped (memory feedback_naca_siti_no_assumptions). Replicates the same
  // response shape so lib/screens/memory_screen.dart doesn't need other field changes.
  //
  // Semantic-search (q param) is NOT yet supported here — embedding requires a
  // Gemini key that naca-backend doesn't have. For now `q` falls back to ILIKE on
  // transcript+caption (best-effort). Full semantic search will move with the rest
  // of the siti-v2 endpoint gap (see docs/spec/siti-v2-endpoint-gap.md).
  if (urlPath === '/api/media' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '50'), 1), 200);
      const kindParam = url.searchParams.get('kind');
      const kind = kindParam && ['image', 'audio', 'video'].includes(kindParam) ? kindParam : null;
      const personId = url.searchParams.get('person_id') || null;
      const since = url.searchParams.get('since') || null;
      const q = (url.searchParams.get('q') || '').trim();

      let query = supabase.from('media')
        .select('id, kind, mime_type, bytes, transcript, caption, storage_url, source, source_ref, subject_id, created_at')
        .order('created_at', { ascending: false })
        .limit(limit);
      if (kind) query = query.eq('kind', kind);
      if (personId) query = query.eq('subject_id', personId);
      if (since) query = query.gte('created_at', since);

      // Hide archived rows by default. Two independent archive flags both
      // honored here (treated equivalently — pass include_archived=1 to see both):
      //  1. metadata.archived=true  — set by manual cleanup (e.g. 2026-05-14
      //     when 1,184 Status broadcast rows were swept after broneotodak/
      //     neo-twin#1 plugged the @broadcast filter regression).
      //  2. metadata.from_archived_chat=true — set at capture time by
      //     twin-ingest (broneotodak/neo-twin#2) when the source chat is
      //     archived in Neo's WhatsApp UI. Bytes still flow to NAS-MinIO so
      //     unarchiving in WA is reversible; the flag just hides them by default.
      if (url.searchParams.get('include_archived') !== '1') {
        query = query
          .or('metadata->>archived.is.null,metadata->>archived.eq.false')
          .or('metadata->>from_archived_chat.is.null,metadata->>from_archived_chat.eq.false');
      }

      // Best-effort text fallback while semantic search lives on a dead endpoint.
      // Uses Postgres ILIKE — matches substrings in transcript or caption. Not
      // a replacement for embedding similarity, but better than zero results.
      if (q) {
        const pattern = `%${q.replace(/[%_]/g, '\\$&')}%`;
        query = query.or(`transcript.ilike.${pattern},caption.ilike.${pattern}`);
      }

      const { data: rows, error } = await query;
      if (error) throw error;

      // ── person_name resolution ──────────────────────────────────────────
      // The card shows the conversation partner. Two reasons we can't trust
      // the frozen source_ref.sender_name:
      //   1. outbound media has sender_name='Neo' (we want the recipient)
      //   2. sender_name is captured once — it goes stale after a rename
      // For DM media, source_ref.chat_jid IS the partner's full jid and the
      // suffix tells us the identifier type. We resolve LIVE against the
      // canonical resolve_person RPC (the same one @todak/memory's
      // resolvePerson uses — single source of truth, no drift), then read
      // the CURRENT people.display_name. Group media keeps the captured
      // per-message sender_name (resolving each participant isn't worth it).
      //
      // chat_jid suffix → resolve_person identifier type:
      //   ...@s.whatsapp.net → 'phone'   ...@lid → 'lid'   ...@g.us → group
      const jidToIdentifier = (jid) => {
        if (typeof jid !== 'string' || !jid.includes('@')) return null;
        const [value, suffix] = [jid.slice(0, jid.indexOf('@')), jid.slice(jid.indexOf('@') + 1)];
        if (!value) return null;
        if (suffix === 's.whatsapp.net') return { type: 'phone', value };
        if (suffix === 'lid') return { type: 'lid', value };
        return null; // @g.us groups + anything else → no DM-partner resolution
      };

      // Collect distinct DM-partner identifiers, resolve each once via RPC.
      const distinctKeys = new Map(); // "type:value" → {type,value}
      for (const r of (rows || [])) {
        const ident = jidToIdentifier(r.source_ref?.chat_jid);
        if (ident) distinctKeys.set(`${ident.type}:${ident.value}`, ident);
      }
      const nameByKey = {}; // "type:value" → current display_name
      await Promise.all([...distinctKeys.entries()].map(async ([key, ident]) => {
        try {
          const { data: pid } = await supabase.rpc('resolve_person', { p_type: ident.type, p_value: ident.value });
          if (!pid) return;
          const { data: person } = await supabase.from('people')
            .select('display_name, push_name').eq('id', pid).maybeSingle();
          const name = person?.display_name || person?.push_name;
          if (name) nameByKey[key] = name;
        } catch { /* best-effort — fall back to captured name below */ }
      }));

      // Match the v1 response shape so Dart code doesn't need changes beyond the URL.
      // signed_url is intentionally null — Dart uses /api/media/:id/blob for bytes.
      const enriched = (rows || []).map(r => {
        const ident = jidToIdentifier(r.source_ref?.chat_jid);
        const liveName = ident ? nameByKey[`${ident.type}:${ident.value}`] : null;
        return {
          id: r.id,
          kind: r.kind,
          mime_type: r.mime_type,
          bytes: r.bytes,
          transcript: r.transcript,
          caption: r.caption,
          created_at: r.created_at,
          storage_url: r.storage_url,
          signed_url: null,
          source: r.source,
          source_ref: r.source_ref,
          subject_id: r.subject_id,
          // Live-resolved partner name (DM) → captured sender_name → push_name.
          person_name: liveName
            || r.source_ref?.sender_name
            || r.source_ref?.push_name
            || null,
          similarity: null,
        };
      });
      json(res, {
        media: enriched,
        count: enriched.length,
        mode: q ? 'search-fallback-ilike' : 'browse',
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // =============================================
  // SITI TAB — Surface 4 Tier A read endpoints (2026-05-15)
  // Replace /api/siti/api/{contacts,messages,status} that went 502 when the
  // v1 monolith on port 3800 stopped. See docs/spec/surface-4-siti-tab-scope.md.
  // =============================================

  // GET /api/wa-messages?limit=&offset= — WhatsApp message history.
  // Reads neo-brain.wa_messages, maps the denormalised v2 columns to the
  // shape siti_screen.dart's message list renders (direction/contact_name/
  // body/is_group/handled). Archived rows excluded by default.
  if (urlPath === '/api/wa-messages' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const limit = Math.min(Math.max(parseInt(url.searchParams.get('limit') || '50'), 1), 200);
      const offset = Math.max(parseInt(url.searchParams.get('offset') || '0'), 0);
      let q = supabase.from('wa_messages')
        .select('id, created_at, content, chat_jid, sender_phone, push_name, is_group, is_from_self, handled:metadata->handled_by_neo_twin, wa_message_id, media_type, has_media')
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);
      // Hide archived / archived-chat rows (same treatment as /api/media).
      if (url.searchParams.get('include_archived') !== '1') {
        q = q.eq('archived', false).eq('archived_chat', false);
      }
      const { data, error } = await q;
      if (error) throw error;
      const messages = (data || []).map(r => ({
        id: r.id,
        direction: r.is_from_self ? 'out' : 'in',
        contact_name: r.push_name || r.sender_phone || '?',
        from_phone: r.sender_phone,
        body: r.content,
        is_group: r.is_group === true,
        handled: r.handled || '',
        chat_jid: r.chat_jid,
        has_media: r.has_media === true,
        media_type: r.media_type,
        created_at: r.created_at,
      }));
      json(res, { messages, count: messages.length });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/contacts — WhatsApp contact roster.
  // Reads neo-brain.contacts; columns already match what the SITI tab's
  // contact cards render (kind/name/phone/permission/auto_reply_enabled/
  // project_scope/id).
  //
  // Split query: groups returned without limit (typically <100), users
  // ordered by last_seen_at DESC NULLS LAST and capped at 500. The
  // previous single-query `LIMIT 500 ORDER BY last_seen_at DESC NULLS LAST`
  // could drop groups whose last_seen_at was NULL into the unordered
  // tail and clip them off — verified 2026-05-27 when 1 of 11 group
  // rows was invisible to the SITI/Contacts/Groups tab. Splitting also
  // means new operator-added groups always appear immediately.
  if (urlPath === '/api/contacts' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const cols = 'id, person_id, phone, jid, lid, name, push_name, kind, permission, persona_override, auto_reply_enabled, reply_mode, project_scope, notes, last_seen_at';
      const [{ data: groups, error: gErr }, { data: users, error: uErr }] = await Promise.all([
        supabase.from('contacts').select(cols).eq('kind', 'group').order('last_seen_at', { ascending: false, nullsFirst: false }),
        supabase.from('contacts').select(cols).eq('kind', 'user').order('last_seen_at', { ascending: false, nullsFirst: false }).limit(500),
      ]);
      if (gErr) throw gErr;
      if (uErr) throw uErr;
      const contacts = [...(groups || []), ...(users || [])];
      json(res, { contacts, count: contacts.length, group_count: (groups || []).length, user_count: (users || []).length });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // GET /api/people — person directory powering the MEM/People tab.
  // GET /api/facts — extracted facts powering the MEM/Facts list + people detail.
  // GET /api/personality — personality dimensions for people detail.
  //
  // Each table has RLS enabled with no anon-readable policy (migration
  // 20260516022625_harden_rls_close_anon_exposure on 2026-05-16 dropped
  // anon_read_{people,facts,personality} on the assumption no anon
  // consumer existed — the NACA app's MEM screen IS one, and the tab
  // went silently empty). The fix: proxy through the backend with the
  // service-role key (bypasses RLS) and gate on the existing app auth.
  // Matches the same pattern /api/contacts uses for the SITI tab.
  if (urlPath === '/api/people' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      // Calls people_search RPC for both list (?q empty) and search.
      // The RPC filters merged tombstones (~30% of people rows) and junk
      // rows by default, and searches across name fields + identifiers
      // JSONB + nicknames when q is set. Single source of truth — keeps
      // backend, audit tooling, and any future per-agent-JWT callers in
      // sync. Migration: 2026-05-28_people_search_rpc.sql.
      const u = new URL(req.url, 'http://x');
      const q = (u.searchParams.get('q') || '').trim();
      const includeMerged = u.searchParams.get('include_merged') === 'true';
      const limit = Math.max(1, Math.min(500, Number(u.searchParams.get('limit')) || (q ? 100 : 200)));
      const { data, error } = await supabase.rpc('people_search', {
        q: q || null,
        include_merged: includeMerged,
        limit_n: limit,
      });
      if (error) throw error;
      json(res, { people: data || [], count: (data || []).length, query: q || null });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }
  if (urlPath === '/api/facts' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const cols = 'id, subject_id, fact, category, confidence, created_at';
      const limit = Math.max(1, Math.min(500, Number((new URL(req.url, 'http://x')).searchParams.get('limit')) || 200));
      const q = (new URL(req.url, 'http://x')).searchParams.get('q') || '';
      let query = supabase.from('facts').select(cols).order('created_at', { ascending: false }).limit(limit);
      if (q.trim()) query = query.ilike('fact', `%${q.trim()}%`);
      const { data, error } = await query;
      if (error) throw error;
      json(res, { facts: data || [], count: (data || []).length });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }
  if (urlPath === '/api/personality' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const { data, error } = await supabase.from('personality')
        .select('id, subject_id, trait, dimension, value, sample_count, description, example_behaviors')
        .order('dimension');
      if (error) throw error;
      json(res, { personality: data || [], count: (data || []).length });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // Surface 4 Tier B (2026-05-18) — contact create/update/delete.
  // Replaces /api/siti/api/contacts* (502, dead v1 monolith). Service-role
  // writes to neo-brain.contacts. permission CHECK = owner|admin|developer|
  // chat|readonly|blocked; kind CHECK = user|group (NOT NULL, no default).
  const CONTACT_PERMISSIONS = ['owner', 'admin', 'developer', 'chat', 'readonly', 'blocked'];

  // POST /api/contacts — create. Body: {phone, name, permission?}.
  if (urlPath === '/api/contacts' && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    readBody(req, async (body) => {
      try {
        const phone = String(body?.phone || '').trim();
        if (!phone) { json(res, { error: 'phone required' }, 400); return; }
        const permission = body?.permission && CONTACT_PERMISSIONS.includes(body.permission)
          ? body.permission : 'readonly';
        // kind is NOT NULL with no DB default — a hand-added contact is a user.
        const row = {
          phone,
          name: String(body?.name || '').trim() || null,
          permission,
          kind: 'user',
        };
        const { data, error } = await supabase.from('contacts').insert(row).select().maybeSingle();
        if (error) { json(res, { error: error.message }, 500); return; }
        json(res, { ok: true, contact: data }, 201);
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  const contactById = urlPath.match(/^\/api\/contacts\/([0-9a-f-]{36})$/);

  // PATCH /api/contacts/:id — update name / permission / project_scope /
  // auto_reply_enabled / persona_override. Only provided fields are touched.
  if (contactById && req.method === 'PATCH') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = contactById[1];
    readBody(req, async (body) => {
      try {
        const patch = {};
        if (typeof body?.name === 'string') patch.name = body.name.trim() || null;
        if (typeof body?.persona_override === 'string') patch.persona_override = body.persona_override.trim() || null;
        if (typeof body?.auto_reply_enabled === 'boolean') patch.auto_reply_enabled = body.auto_reply_enabled;
        if (Array.isArray(body?.project_scope)) patch.project_scope = body.project_scope.map(s => String(s).trim()).filter(Boolean);
        if (body?.permission != null) {
          if (!CONTACT_PERMISSIONS.includes(body.permission)) { json(res, { error: `invalid permission '${body.permission}'` }, 400); return; }
          patch.permission = body.permission;
        }
        if (Object.keys(patch).length === 0) { json(res, { error: 'no fields to update' }, 400); return; }
        patch.updated_at = new Date().toISOString();
        const { data, error } = await supabase.from('contacts').update(patch).eq('id', id).select().maybeSingle();
        if (error) { json(res, { error: error.message }, 500); return; }
        if (!data) { json(res, { error: 'contact not found' }, 404); return; }
        json(res, { ok: true, contact: data });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // DELETE /api/contacts/:id — refuses owner-permission rows (deleting Neo's
  // own contact would strip Siti's owner policy). Otherwise hard-deletes.
  if (contactById && req.method === 'DELETE') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = contactById[1];
    try {
      const { data: existing, error: fErr } = await supabase.from('contacts')
        .select('id, permission, name').eq('id', id).maybeSingle();
      if (fErr) { json(res, { error: fErr.message }, 500); return; }
      if (!existing) { json(res, { error: 'contact not found' }, 404); return; }
      if (existing.permission === 'owner') { json(res, { error: 'refusing to delete an owner contact' }, 400); return; }
      const { error } = await supabase.from('contacts').delete().eq('id', id);
      if (error) { json(res, { error: error.message }, 500); return; }
      json(res, { ok: true, id, name: existing.name });
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

  // GET|HEAD /api/content-drafts/:id/media?idx=N — serve a content-draft's media.
  // content-creator writes daily videos to the Ugreen NAS filesystem
  // (/volume1/Todak Studios/naca/<path>), recorded in content_drafts.media_paths
  // as [{kind,path,store:'nas'}]. There's no `media` table row and no MinIO
  // object — so /api/media/:id/blob can't serve it. naca-backend stages the file
  // from the NAS to a local tempfile (stageNasFile), then serves it with HTTP
  // Range support — iOS video playback sends a Range probe and won't play a
  // body it can't size or seek. The SCHED tab's draft card opens this.
  // ?token= supported for the external player.
  const draftMedia = urlPath.match(/^\/api\/content-drafts\/([0-9a-f-]{36})\/media$/);
  if (draftMedia && (req.method === 'GET' || req.method === 'HEAD')) {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = draftMedia[1];
    try {
      const idx = Math.max(parseInt(url.searchParams.get('idx') || '0'), 0);
      const { data: draft, error } = await supabase.from('content_drafts')
        .select('media_paths').eq('id', id).maybeSingle();
      if (error) { json(res, { error: error.message }, 500); return; }
      if (!draft) { json(res, { error: 'draft not found' }, 404); return; }
      const item = Array.isArray(draft.media_paths) ? draft.media_paths[idx] : null;
      if (!item || !item.path) { json(res, { error: 'no media at idx ' + idx }, 404); return; }
      if (item.store && item.store !== 'nas') { json(res, { error: `unsupported store '${item.store}'` }, 400); return; }
      // Path safety — only content/ paths, no traversal, no shell metachars.
      const relPath = String(item.path);
      if (!/^content\/[\w./-]+\.(mp4|mov|jpg|jpeg|png|webp|m4a|mp3)$/i.test(relPath) || relPath.includes('..')) {
        json(res, { error: 'invalid media path' }, 400); return;
      }
      const ext = relPath.split('.').pop().toLowerCase();
      const ctype = ({ mp4: 'video/mp4', mov: 'video/quicktime', jpg: 'image/jpeg', jpeg: 'image/jpeg',
        png: 'image/png', webp: 'image/webp', m4a: 'audio/mp4', mp3: 'audio/mpeg' })[ext] || 'application/octet-stream';
      const remotePath = `/volume1/Todak Studios/naca/${relPath}`;
      const cacheFile = path.join(NACA_MEDIA_CACHE, `${id}-${idx}.${ext}`);
      // Stage from NAS (intercontinental SSH — slow first hit, instant after;
      // the external player tolerates the wait, iOS connection timeout >> this).
      try {
        await stageNasFile(remotePath, cacheFile);
      } catch (e) {
        json(res, { error: 'nas stage failed: ' + e.message }, 502); return;
      }
      const total = fs.statSync(cacheFile).size;
      const baseHeaders = { 'Content-Type': ctype, 'Accept-Ranges': 'bytes', 'Cache-Control': 'private, max-age=3600' };
      const rangeHeader = req.headers.range;
      const m = rangeHeader && /^bytes=(\d*)-(\d*)$/.exec(rangeHeader);
      if (m) {
        let start = m[1] ? parseInt(m[1], 10) : 0;
        let end = m[2] ? parseInt(m[2], 10) : total - 1;
        if (isNaN(start) || isNaN(end) || start > end || start >= total) {
          res.writeHead(416, { 'Content-Range': `bytes */${total}` }); res.end(); return;
        }
        end = Math.min(end, total - 1);
        res.writeHead(206, { ...baseHeaders, 'Content-Range': `bytes ${start}-${end}/${total}`, 'Content-Length': end - start + 1 });
        if (req.method === 'HEAD') { res.end(); return; }
        fs.createReadStream(cacheFile, { start, end }).pipe(res);
        return;
      }
      res.writeHead(200, { ...baseHeaders, 'Content-Length': total });
      if (req.method === 'HEAD') { res.end(); return; }
      fs.createReadStream(cacheFile).pipe(res);
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

        // 2. Insert a scheduled_action per channel — dispatched to poster-agent,
        // the NACA publisher chain: poster-agent (NAS Ugreen) fans each
        // post_content out to publisher-agent (API channels) or browser-agent
        // (UI channels), both on Slave MBP. One scheduled_action per channel so
        // partial success (LinkedIn ok, IG fails) is visible per row.
        // poster-agent's post_content contract takes the draft's media_paths
        // array as-is and resolves NAS-stored media itself.
        const insertedActions = [];
        for (const channel of cleanCh) {
          const desc = `${channel} post: ${(draft.caption || '').slice(0, 50)}`;
          const { data: act, error: aErr } = await supabase.from('scheduled_actions').insert({
            fire_at: fireAt.toISOString(),
            action_kind: 'agent_command',
            action_payload: {
              from_agent: 'naca-app',
              to_agent: 'poster-agent',
              command: 'post_content',
              payload: {
                caption: draft.caption,
                channel,
                media_paths: draft.media_paths,
                content_draft_id: draftId,
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

  // POST /api/content-drafts/:id/regenerate  body: { template_key }
  // Rejects the draft and dispatches a generate_theme command to
  // content-creator, which produces a fresh draft with the chosen theme.
  const draftRegen = urlPath.match(/^\/api\/content-drafts\/([0-9a-f-]{36})\/regenerate$/);
  if (draftRegen && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const draftId = draftRegen[1];
    readBody(req, async (body) => {
      try {
        const templateKey = (body.template_key || '').toString().trim();
        if (!templateKey) { json(res, { error: 'template_key required' }, 400); return; }
        // Confirm the theme exists.
        const { data: tpl, error: tErr } = await supabase.from('content_templates')
          .select('key').eq('key', templateKey).maybeSingle();
        if (tErr) throw tErr;
        if (!tpl) { json(res, { error: `no theme with key '${templateKey}'` }, 404); return; }
        // Reject the draft (only if still pending).
        const { error: rErr } = await supabase.from('content_drafts')
          .update({
            status: 'rejected',
            rejected_at: new Date().toISOString(),
            rejected_reason: `regenerate as ${templateKey}`,
          })
          .eq('id', draftId).eq('status', 'pending_approval')
          .select().single();
        if (rErr) {
          if (rErr.code === 'PGRST116') { json(res, { error: 'draft not pending (already approved/rejected or not found)' }, 409); return; }
          throw rErr;
        }
        // Dispatch the regeneration to content-creator.
        const { data: cmd, error: cErr } = await supabase.from('agent_commands').insert({
          from_agent: 'naca-app',
          to_agent: 'content-creator',
          command: 'generate_theme',
          payload: { template_key: templateKey },
          status: 'pending',
        }).select('id').single();
        if (cErr) throw cErr;
        json(res, { ok: true, rejected_draft: draftId, theme: templateKey, command_id: cmd.id });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // =============================================
  // CONTENT TEMPLATES — Studio tab: daily-content themes (neo-brain.content_templates)
  // The naca-content-creator daily-content trigger picks an active theme by
  // weighted day-of-year rotation. This lets the operator manage themes from
  // the app instead of editing the DB by hand.
  // =============================================

  // GET /api/content-templates — all themes (active + inactive)
  if (urlPath === '/api/content-templates' && req.method === 'GET') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    try {
      const { data, error } = await supabase.from('content_templates')
        .select('*')
        .order('active', { ascending: false })
        .order('key', { ascending: true });
      if (error) throw error;
      const templates = data || [];
      json(res, {
        templates,
        stats: { total: templates.length, active: templates.filter(t => t.active).length },
      });
    } catch (e) { json(res, { error: e.message }, 500); }
    return;
  }

  // PATCH /api/content-templates/:id — edit a theme
  const tplEdit = urlPath.match(/^\/api\/content-templates\/([0-9a-f-]{36})$/);
  if (tplEdit && req.method === 'PATCH') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    const id = tplEdit[1];
    readBody(req, async (body) => {
      try {
        const patch = {};
        if ('display_name' in body) patch.display_name = body.display_name?.toString() || '';
        if ('active' in body) patch.active = Boolean(body.active);
        if ('weight' in body) {
          const w = parseInt(body.weight, 10);
          if (!Number.isNaN(w)) patch.weight = Math.min(Math.max(w, 1), 100);
        }
        if ('concept_prompt' in body) patch.concept_prompt = body.concept_prompt?.toString() || '';
        if ('image_prompt_template' in body) patch.image_prompt_template = body.image_prompt_template?.toString() || null;
        if ('action_suffix' in body) patch.action_suffix = body.action_suffix?.toString() || null;
        if ('kind' in body && ['video', 'image'].includes(body.kind)) patch.kind = body.kind;
        if ('mode' in body && ['character', 'generative'].includes(body.mode)) patch.mode = body.mode;
        if ('music' in body) patch.music = Boolean(body.music);
        if ('narration_language' in body && ['en', 'ms', 'id'].includes(body.narration_language)) patch.narration_language = body.narration_language;
        if ('tool_hint' in body) patch.tool_hint = body.tool_hint?.toString() || null;
        if ('notes' in body) patch.notes = body.notes?.toString() || null;
        if ('categories' in body && Array.isArray(body.categories)) patch.categories = body.categories;
        if ('output' in body && body.output && typeof body.output === 'object') patch.output = body.output;
        if (!Object.keys(patch).length) { json(res, { error: 'no editable fields in body' }, 400); return; }
        patch.updated_at = new Date().toISOString();
        const { data, error } = await supabase.from('content_templates')
          .update(patch).eq('id', id).select().single();
        if (error) {
          if (error.code === 'PGRST116') { json(res, { error: 'template not found' }, 404); return; }
          throw error;
        }
        json(res, { ok: true, template: data });
      } catch (e) { json(res, { error: e.message }, 500); }
    });
    return;
  }

  // POST /api/content-templates — create a new theme (defaults to inactive)
  if (urlPath === '/api/content-templates' && req.method === 'POST') {
    if (!supabase) { json(res, { error: 'neo-brain not configured' }, 503); return; }
    readBody(req, async (body) => {
      try {
        const key = (body.key || '').toString().trim().toLowerCase().replace(/[^a-z0-9_]/g, '_');
        const displayName = (body.display_name || '').toString().trim();
        const conceptPrompt = (body.concept_prompt || '').toString().trim();
        if (!key) { json(res, { error: 'key required (slug)' }, 400); return; }
        if (!displayName) { json(res, { error: 'display_name required' }, 400); return; }
        if (!conceptPrompt) { json(res, { error: 'concept_prompt required' }, 400); return; }
        const row = {
          key,
          display_name: displayName,
          concept_prompt: conceptPrompt,
          active: body.active === undefined ? false : Boolean(body.active),
          weight: Math.min(Math.max(parseInt(body.weight, 10) || 1, 1), 100),
          kind: ['video', 'image'].includes(body.kind) ? body.kind : 'video',
          mode: ['character', 'generative'].includes(body.mode) ? body.mode : 'generative',
          categories: Array.isArray(body.categories) ? body.categories : [],
          image_prompt_template: body.image_prompt_template?.toString() || null,
          action_suffix: body.action_suffix?.toString() || null,
          output: (body.output && typeof body.output === 'object') ? body.output : {},
          music: body.music === undefined ? true : Boolean(body.music),
          narration_language: ['en', 'ms', 'id'].includes(body.narration_language) ? body.narration_language : 'en',
          tool_hint: body.tool_hint?.toString() || null,
          notes: body.notes?.toString() || null,
          created_by: 'naca:operator',
        };
        const { data, error } = await supabase.from('content_templates')
          .insert(row).select().single();
        if (error) {
          if (error.code === '23505') { json(res, { error: `template key '${key}' already exists` }, 409); return; }
          throw error;
        }
        json(res, { ok: true, template: data }, 201);
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
      const commands = []; // routes to agent_commands (only for direct, known-command targets)
      const intents  = []; // routes to agent_intents (planner decomposes into known commands)

      // ── event mappings ─────────────────────────────────────────────────
      // Routing rule:
      //   Direct → commands: only when we KNOW the receiving agent + command
      //     (currently just reviewer/review_pr for opened PRs).
      //   Indirect → intents: anything where the right agent + sub-command
      //     should be decided by the planner. This avoids the "stuck command"
      //     class of bug where webhooks queued commands no agent accepts.
      //
      switch (event) {
        case 'push': {
          // Intentionally NO intent for push-to-main. Every push that lands a
          // PR also fires a `pull_request closed merged` event (handled below)
          // and CI/CD posts its own deploy notification — the planner-routed
          // push intent was pure duplication. Worse, its open-ended prompt
          // ("investigate if commit indicates a fix that needs verification")
          // pushed planner to dispatch redundant review_pr audits and
          // multi-paragraph dev-agent tasks that broke on shell-quoted commit
          // messages. Removing the intent eliminates an entire class of spam
          // without losing signal — the merged-event path still notifies.
          break;
        }
        case 'pull_request': {
          // Opened / synchronized → reviewer (DIRECT — known agent + command).
          // Contract: to_agent='reviewer', command='review_pr', payload needs { project, repo, branch }.
          //
          // Fleet-origin skip (2026-05-28): PRs created by the fleet itself
          // (operator-mbp / slave-mbp / VPS dev-agent — all push as broneotodak)
          // are handled end-to-end by the fleet session that created them
          // (Lane B self-merge, deploy, save shared_infra_change). Reviewing them
          // posts a "PR awaiting your call" brief Neo has been ignoring by design,
          // and the daily-checkup digest then re-pages him about the orphan rows.
          // Detection: author=broneotodak AND PR body carries the Claude Code
          // marker (auto-appended by `gh pr create` from CC sessions). Manual
          // PRs Neo opens via the GitHub web UI lack the marker and still get
          // reviewed normally.
          const prObj = payload.pull_request;
          const isFleetOriginPr = prObj?.user?.login === 'broneotodak' &&
            /(?:🤖\s*)?Generated with \[?Claude Code\]?|Co-Authored-By:\s*Claude/i.test(prObj?.body || '');
          if (['opened', 'synchronize', 'reopened', 'ready_for_review'].includes(payload.action)) {
            if (isFleetOriginPr) {
              console.log(`[github-webhook] fleet-origin PR — skipping review_pr dispatch: ${prObj.html_url} (action=${payload.action})`);
            } else {
              const project = repo.split('/').pop() || repo;
              const branch = prObj?.head?.ref;
              commands.push({
                from_agent: 'github-actions',
                to_agent: 'reviewer',
                command: 'review_pr',
                payload: {
                  project,
                  repo,
                  branch,
                  pr_number: prObj?.number,
                  pr_title: prObj?.title,
                  pr_url: prObj?.html_url,
                  head_sha: prObj?.head?.sha,
                  base: prObj?.base?.ref,
                  action: payload.action,
                  reporter: prObj?.user?.login,
                },
                priority: 3,
              });
            }
          }
          // Closed/merged → INTENT (planner decides: deploy notify? cleanup? no-op?).
          // Prompt explicitly forbids review/audit follow-ups: the reviewer
          // already ran on PR open, and re-reviewing a merged PR posts a
          // "PR awaiting your call" brief for a decision the operator just
          // made — that's where the spam loop came from.
          if (payload.action === 'closed' && payload.pull_request?.merged) {
            const pr = payload.pull_request;
            intents.push({
              source: 'github_webhook',
              reporter: pr.merged_by?.login || 'github-actions',
              raw_text: `[github] PR merged on ${repo}: #${pr.number} "${pr.title}" by @${pr.merged_by?.login || 'unknown'}. At most one short send_whatsapp_notification to siti summarising the merge — DO NOT dispatch review_pr (already reviewed when opened; re-reviewing a merged PR spams the operator with a redundant approval brief), DO NOT dispatch dev-agent commands (no investigation requested), DO NOT compose multi-paragraph commit-message-style task bodies. If the merge is routine, decompose to no actions at all.`,
              source_ref: JSON.stringify({ event: 'pull_request', action: 'merged', repo, pr_number: pr.number, pr_url: pr.html_url, merged_by: pr.merged_by?.login }),
            });
          }
          break;
        }
        case 'check_suite': {
          // CI check_suite failure → INTENT (planner decomposes into investigate_bug or no-op).
          if (payload.action === 'completed' && payload.check_suite?.conclusion === 'failure') {
            const cs = payload.check_suite;
            intents.push({
              source: 'github_webhook',
              reporter: 'github-actions',
              raw_text: `[github] CI check_suite failed on ${repo}@${cs.head_branch} (${(cs.head_sha || '').slice(0, 8)}). Failing app: ${cs.app?.slug || 'unknown'}. Investigate which check failed (likely build, lint, or test) and propose a fix if it's a real regression. Skip if the failing workflow is known-flaky or unsupported (e.g. Build Windows on a non-Windows project).`,
              source_ref: JSON.stringify({ event: 'check_suite', repo, head_sha: cs.head_sha, branch: cs.head_branch, app: cs.app?.slug, conclusion: cs.conclusion }),
            });
          }
          break;
        }
        case 'issue_comment': {
          // Comments mentioning an agent → INTENT (planner reads the body and decides what to do).
          const body = payload.comment?.body || '';
          const mentionable = await getMentionableAgents();
          const mentioned = mentionable.filter(t => body.includes('@' + t));
          if (mentioned.length) {
            intents.push({
              source: 'github_webhook',
              reporter: payload.comment?.user?.login || 'github-actions',
              raw_text: `[github] mention on ${repo} issue/PR #${payload.issue?.number}: "${body.slice(0, 400)}". Mentioned: ${mentioned.join(', ')}. Decide which agent should respond and how.`,
              source_ref: JSON.stringify({ event: 'issue_comment', repo, issue_number: payload.issue?.number, comment_url: payload.comment?.html_url, mentioned, author: payload.comment?.user?.login }),
            });
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

      // Insert queued commands + intents in two shots via Supabase REST.
      // Commands route to known-handler agents (reviewer for review_pr).
      // Intents route to planner for decomposition (everything else from webhooks).
      let insertedCommands = 0;
      let insertedIntents  = 0;
      if (commands.length && supabase) {
        const { data, error } = await supabase.from('agent_commands').insert(commands).select('id');
        if (error) {
          console.error('[github-webhook] commands insert failed:', error.message);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: error.message }));
          return;
        }
        insertedCommands = data?.length || 0;
      }
      if (intents.length && supabase) {
        const { data, error } = await supabase.from('agent_intents').insert(intents).select('id');
        if (error) {
          console.error('[github-webhook] intents insert failed:', error.message);
          // Don't 500 if commands succeeded — partial success is still useful.
        } else {
          insertedIntents = data?.length || 0;
        }
      }

      console.log(`[github-webhook] ${event}/${payload.action || '-'} from ${repo} → ${insertedCommands} command(s), ${insertedIntents} intent(s)`);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, event, action: payload.action || null, repo, commands: insertedCommands, intents: insertedIntents, delivery: deliveryId }));
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
