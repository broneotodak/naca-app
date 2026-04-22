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

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

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

  json(res, { error: 'not found' }, 404);
});

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
          if (buffer.length > 0) ws.send(JSON.stringify({ type: 'replay', events: buffer }));
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
