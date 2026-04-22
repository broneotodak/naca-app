const Database = require('better-sqlite3');
const path = require('path');

const DB_PATH = path.join(__dirname, 'ccc.db');
const db = new Database(DB_PATH);

// WAL mode for better concurrent reads
db.pragma('journal_mode = WAL');

db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    project_dir TEXT,
    status TEXT DEFAULT 'idle' CHECK(status IN ('idle','active','error','stopped')),
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    role TEXT NOT NULL CHECK(role IN ('user','assistant','system')),
    content TEXT,
    created_at TEXT DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS tool_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    message_id INTEGER REFERENCES messages(id),
    tool_name TEXT NOT NULL,
    tool_input TEXT,
    tool_result TEXT,
    status TEXT DEFAULT 'running' CHECK(status IN ('running','done','error')),
    created_at TEXT DEFAULT (datetime('now'))
  );

  CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, created_at);
  CREATE INDEX IF NOT EXISTS idx_tool_calls_session ON tool_calls(session_id, created_at);
`);

// Migration: add source + agent columns if missing
try {
  db.exec(`ALTER TABLE sessions ADD COLUMN source TEXT DEFAULT 'naca'`);
} catch (_) {} // Column already exists
try {
  db.exec(`ALTER TABLE sessions ADD COLUMN agent TEXT DEFAULT NULL`);
} catch (_) {}

module.exports = db;

// Reset zombie sessions on startup (backend restart clears in-memory state)
db.prepare("UPDATE sessions SET status = 'idle' WHERE status = 'active'").run();
