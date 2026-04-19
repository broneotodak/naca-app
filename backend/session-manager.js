const { spawn } = require('child_process');
const { v4: uuidv4 } = require('uuid');
const db = require('./db');
const EventEmitter = require('events');

class SessionManager extends EventEmitter {
  constructor() {
    super();
    this.sessions = new Map();
  }

  list() {
    const rows = db.prepare('SELECT * FROM sessions ORDER BY created_at DESC').all();
    const turnCounts = db.prepare("SELECT session_id, COUNT(*) as turns FROM messages WHERE role = 'user' GROUP BY session_id").all();
    const turnMap = Object.fromEntries(turnCounts.map(t => [t.session_id, t.turns]));
    return rows.map(r => {
      const live = this.sessions.get(r.id);
      return { ...r, status: live?.status || r.status, turns: turnMap[r.id] || 0 };
    });
  }

  get(id) {
    const row = db.prepare('SELECT * FROM sessions WHERE id = ?').get(id);
    const live = this.sessions.get(id);
    return { ...row, isLive: !!live, status: live?.status || row?.status || 'idle' };
  }

  create(name, projectDir) {
    const id = uuidv4();
    db.prepare('INSERT INTO sessions (id, name, project_dir, status) VALUES (?, ?, ?, ?)')
      .run(id, name, projectDir || '/home/lanccc', 'idle');
    return { id, name, projectDir };
  }

  async startSession(id) {
    const session = db.prepare('SELECT * FROM sessions WHERE id = ?').get(id);
    if (!session) throw new Error('Session not found');

    const sessionState = {
      claudeSessionId: null,
      status: 'active',
      buffer: [],
      activeProcess: null,
      projectDir: session.project_dir || '/home/lanccc',
      promptCount: 0,
      lastActivity: Date.now()
    };

    this.sessions.set(id, sessionState);
    db.prepare("UPDATE sessions SET status = 'active', updated_at = datetime('now') WHERE id = ?").run(id);
    this._emitEvent(id, { type: 'system', content: 'Session initialized. Ready for commands.' });

    return { id, status: 'active' };
  }

  sendPrompt(id, prompt) {
    const session = this.sessions.get(id);
    if (!session) throw new Error('Session not started. Click play first.');

    if (session.activeProcess) {
      throw new Error('Claude is still processing. Please wait.');
    }

    console.log(`[PROMPT] Session ${id.substring(0, 8)}: "${prompt.substring(0, 60)}"`);

    const msgResult = db.prepare('INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)')
      .run(id, 'user', prompt);
    this._emitEvent(id, { type: 'user_message', content: prompt, messageId: msgResult.lastInsertRowid });
    this._emitEvent(id, { type: 'status', content: 'processing' });

    session.promptCount++;
    // Track seen blocks by tool_use ID to avoid duplicates
    session.seenToolUseIds = new Set();
    session.seenTextHashes = new Set();
    session.emittedResult = false;

    const escapedPrompt = prompt.replace(/'/g, "'\\''");
    let claudeCmd = `cd '${session.projectDir}' && claude -p '${escapedPrompt}' --output-format stream-json --verbose --dangerously-skip-permissions`;

    if (session.claudeSessionId) {
      claudeCmd += ` --resume '${session.claudeSessionId}'`;
    }

    console.log(`[CLAUDE] Starting process for ${id.substring(0, 8)}, resume: ${session.claudeSessionId ? 'yes' : 'no'}`);

    const proc = spawn('su', ['-', 'lanccc', '-c', claudeCmd], {
      env: { ...process.env, HOME: '/home/lanccc' },
      stdio: ['pipe', 'pipe', 'pipe']
    });

    session.activeProcess = proc;
    session.status = 'processing';

    let outputBuffer = '';

    proc.stdout.on('data', (chunk) => {
      outputBuffer += chunk.toString();
      const lines = outputBuffer.split('\n');
      outputBuffer = lines.pop() || '';

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);
          if (event.type === 'system' && event.subtype === 'init' && event.session_id) {
            session.claudeSessionId = event.session_id;
            console.log(`[CLAUDE] Session ID: ${event.session_id.substring(0, 8)}`);
          }
          this._handleEvent(id, event);
        } catch {
          if (line.trim()) {
            this._emitEvent(id, { type: 'raw', content: line });
          }
        }
      }
      session.lastActivity = Date.now();
    });

    proc.stderr.on('data', (chunk) => {
      const text = chunk.toString().trim();
      if (text && !text.includes('Warning: no stdin')) {
        console.log(`[CLAUDE:STDERR] ${id.substring(0, 8)}: ${text.substring(0, 200)}`);
        this._emitEvent(id, { type: 'stderr', content: text });
      }
    });

    proc.on('close', (code) => {
      console.log(`[CLAUDE] Process closed for ${id.substring(0, 8)}, code: ${code}`);

      if (outputBuffer.trim()) {
        try {
          const event = JSON.parse(outputBuffer);
          if (event.type === 'system' && event.subtype === 'init' && event.session_id) {
            session.claudeSessionId = event.session_id;
          }
          this._handleEvent(id, event);
        } catch {
          if (outputBuffer.trim()) {
            this._emitEvent(id, { type: 'raw', content: outputBuffer });
          }
        }
      }

      session.activeProcess = null;
      session.status = 'active';
      db.prepare("UPDATE sessions SET status = 'active', updated_at = datetime('now') WHERE id = ?").run(id);
      this._emitEvent(id, { type: 'status', content: 'ready' });
    });

    proc.on('error', (err) => {
      console.error(`[CLAUDE] Process error for ${id.substring(0, 8)}: ${err.message}`);
      session.activeProcess = null;
      session.status = 'error';
      db.prepare("UPDATE sessions SET status = 'error', updated_at = datetime('now') WHERE id = ?").run(id);
      this._emitEvent(id, { type: 'error', content: err.message });
    });
  }

  stopSession(id) {
    const session = this.sessions.get(id);
    if (session) {
      if (session.activeProcess) {
        session.activeProcess.kill('SIGTERM');
        setTimeout(() => {
          if (session.activeProcess && !session.activeProcess.killed) {
            session.activeProcess.kill('SIGKILL');
          }
        }, 5000);
      }
    }
    this.sessions.delete(id);
    db.prepare("UPDATE sessions SET status = 'idle', updated_at = datetime('now') WHERE id = ?").run(id);
  }

  renameSession(id, name) {
    if (!name) throw new Error("name required");
    db.prepare("UPDATE sessions SET name = ?, updated_at = datetime('now') WHERE id = ?").run(name, id);
  }

  deleteSession(id) {
    this.stopSession(id);
    db.prepare('DELETE FROM tool_calls WHERE session_id = ?').run(id);
    db.prepare('DELETE FROM messages WHERE session_id = ?').run(id);
    db.prepare('DELETE FROM sessions WHERE id = ?').run(id);
  }

  _handleEvent(id, event) {
    // Skip system events (hooks, init)
    if (event.type === 'system') return;
    // Skip rate limit events
    if (event.type === 'rate_limit_event') return;

    const session = this.sessions.get(id);

    if (event.type === 'assistant' && event.message) {
      const content = event.message.content || [];

      for (const block of content) {
        // Skip thinking blocks
        if (block.type === 'thinking') continue;

        if (block.type === 'text' && block.text) {
          // Deduplicate text blocks by hash
          const hash = this._hash(block.text);
          if (session?.seenTextHashes?.has(hash)) continue;
          if (session) session.seenTextHashes.add(hash);

          console.log(`[EVENT] assistant_text for ${id.substring(0, 8)}: "${block.text.substring(0, 80)}..."`);
          db.prepare('INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)')
            .run(id, 'assistant', block.text);
          this._emitEvent(id, { type: 'assistant_text', content: block.text });
          if (session) session.emittedResult = true;
        } else if (block.type === 'tool_use') {
          // Deduplicate tool calls by ID
          if (session?.seenToolUseIds?.has(block.id)) continue;
          if (session) session.seenToolUseIds.add(block.id);

          console.log(`[EVENT] tool_call for ${id.substring(0, 8)}: ${block.name}`);
          const tcResult = db.prepare('INSERT INTO tool_calls (session_id, tool_name, tool_input, status) VALUES (?, ?, ?, ?)')
            .run(id, block.name, JSON.stringify(block.input), 'running');
          this._emitEvent(id, {
            type: 'tool_call',
            toolCallId: tcResult.lastInsertRowid,
            name: block.name,
            input: block.input,
            status: 'running'
          });
        }
      }
    } else if (event.type === 'tool_result' || event.type === 'tool') {
      const lastTc = db.prepare('SELECT id FROM tool_calls WHERE session_id = ? ORDER BY id DESC LIMIT 1').get(id);
      if (lastTc) {
        db.prepare("UPDATE tool_calls SET status = 'done', tool_result = ? WHERE id = ?")
          .run(JSON.stringify(event.content || event.result || ''), lastTc.id);
      }
      const resultContent = JSON.stringify(event.content || event.result || '');
      this._emitEvent(id, {
        type: 'tool_result',
        content: resultContent.length > 3000 ? resultContent.substring(0, 3000) + '... (truncated)' : resultContent
      });
    } else if (event.type === 'result') {
      // Fallback: if no assistant_text was emitted, use result text
      if (session && !session.emittedResult && event.result && !event.is_error) {
        console.log(`[EVENT] result-fallback for ${id.substring(0, 8)}: "${event.result.substring(0, 80)}..."`);
        db.prepare('INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)')
          .run(id, 'assistant', event.result);
        this._emitEvent(id, { type: 'assistant_text', content: event.result });
      }
      // Log errors from result events
      if (event.is_error && event.errors) {
        console.error(`[CLAUDE:ERROR] ${id.substring(0, 8)}: ${event.errors.join('; ').substring(0, 200)}`);
        this._emitEvent(id, { type: 'system', content: `Error: ${event.errors.join('; ')}` });
      }
    }
  }

  _hash(str) {
    // Simple fast hash for dedup
    let h = 0;
    for (let i = 0; i < str.length; i++) {
      h = ((h << 5) - h + str.charCodeAt(i)) | 0;
    }
    return h;
  }

  _emitEvent(id, event) {
    const payload = { sessionId: id, timestamp: Date.now(), ...event };
    this.emit('event', payload);
    const session = this.sessions.get(id);
    if (session) {
      session.buffer.push(payload);
      if (session.buffer.length > 500) session.buffer.shift();
    }
  }

  getBuffer(id) {
    const session = this.sessions.get(id);
    if (session?.buffer?.length > 0) return session.buffer;
    // Fallback: reconstruct from SQLite
    return this._reconstructFromDb(id);
  }

  _reconstructFromDb(id) {
    const messages = db.prepare(
      'SELECT role, content, created_at FROM messages WHERE session_id = ? ORDER BY created_at ASC LIMIT 200'
    ).all(id);
    const tools = db.prepare(
      'SELECT tool_name, tool_input, tool_result, status, created_at FROM tool_calls WHERE session_id = ? ORDER BY created_at ASC LIMIT 400'
    ).all(id);

    // Merge messages and tools by timestamp into event stream
    const events = [];
    let mi = 0, ti = 0;
    while (mi < messages.length || ti < tools.length) {
      const msg = messages[mi];
      const tool = tools[ti];
      if (msg && (!tool || msg.created_at <= tool.created_at)) {
        const type = msg.role === 'user' ? 'user_message' : 'assistant_text';
        events.push({ sessionId: id, type, content: msg.content, timestamp: new Date(msg.created_at + 'Z').getTime() });
        mi++;
      } else if (tool) {
        let input = {};
        try { input = JSON.parse(tool.tool_input); } catch {}
        events.push({ sessionId: id, type: 'tool_call', name: tool.tool_name, input, timestamp: new Date(tool.created_at + 'Z').getTime() });
        if (tool.tool_result) {
          events.push({ sessionId: id, type: 'tool_result', content: tool.tool_result, timestamp: new Date(tool.created_at + 'Z').getTime() });
        }
        ti++;
      }
    }
    return events;
  }

  getHistory(id, limit = 50) {
    const messages = db.prepare('SELECT * FROM messages WHERE session_id = ? ORDER BY created_at DESC LIMIT ?').all(id, limit).reverse();
    const tools = db.prepare('SELECT * FROM tool_calls WHERE session_id = ? ORDER BY created_at DESC LIMIT ?').all(id, limit * 2).reverse();
    return { messages, tools };
  }
}

module.exports = SessionManager;
