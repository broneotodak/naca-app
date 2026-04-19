require('dotenv').config();
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { WebSocketServer } = require('ws');
const SessionManager = require('./session-manager');

const UPLOAD_DIR = '/tmp/ccc-uploads';
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const PORT = parseInt(process.env.PORT || '3100');
const AUTH_TOKEN = process.env.AUTH_TOKEN;
const sm = new SessionManager();

const server = http.createServer((req, res) => {
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
