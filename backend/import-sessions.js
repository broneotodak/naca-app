#!/usr/bin/env node
/**
 * Import Claude Code JSONL transcripts into NACA's ccc.db
 *
 * Reads ~/.claude/projects/<project>/*.jsonl files and creates
 * read-only session entries in ccc.db so they appear in the NACA terminal tab.
 *
 * Usage: node import-sessions.js [path-to-jsonl-dir]
 * Default: ~/.claude/projects/-home-openclaw/
 */

const fs = require('fs');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const db = require('./db');

const DEFAULT_DIR = path.join(process.env.HOME || '/home/openclaw', '.claude/projects/-home-openclaw');
const jsonlDir = process.argv[2] || DEFAULT_DIR;

if (!fs.existsSync(jsonlDir)) {
  console.error(`Directory not found: ${jsonlDir}`);
  process.exit(1);
}

// Get existing sessions to avoid duplicates
const existingSessions = new Set(
  db.prepare('SELECT name FROM sessions').all().map(r => r.name)
);

const files = fs.readdirSync(jsonlDir).filter(f => f.endsWith('.jsonl'));
console.log(`Found ${files.length} JSONL files in ${jsonlDir}`);

let imported = 0;
let skipped = 0;

for (const file of files) {
  const sessionName = `imported:${file.replace('.jsonl', '')}`;

  if (existingSessions.has(sessionName)) {
    console.log(`  SKIP ${file} (already imported)`);
    skipped++;
    continue;
  }

  const filePath = path.join(jsonlDir, file);
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n').filter(l => l.trim());

  if (lines.length === 0) {
    console.log(`  SKIP ${file} (empty)`);
    skipped++;
    continue;
  }

  // Parse events
  const messages = [];
  const toolCalls = [];
  let firstTimestamp = null;

  for (const line of lines) {
    try {
      const event = JSON.parse(line);

      // Extract timestamp
      if (!firstTimestamp && event.timestamp) {
        firstTimestamp = event.timestamp;
      }

      // User messages
      if (event.type === 'human' || event.role === 'human' || event.role === 'user') {
        const text = typeof event.message === 'string'
          ? event.message
          : event.message?.content?.[0]?.text || event.content || JSON.stringify(event.message || '');
        if (text && text !== '{}') {
          messages.push({ role: 'user', content: text.substring(0, 10000) });
        }
      }

      // Assistant messages
      if (event.type === 'assistant' || event.role === 'assistant') {
        const content = event.message?.content || event.content || [];
        const blocks = Array.isArray(content) ? content : [content];

        for (const block of blocks) {
          if (block.type === 'text' && block.text) {
            messages.push({ role: 'assistant', content: block.text.substring(0, 10000) });
          } else if (block.type === 'tool_use') {
            toolCalls.push({
              name: block.name,
              input: JSON.stringify(block.input || {}).substring(0, 5000),
              status: 'done',
            });
          } else if (typeof block === 'string') {
            messages.push({ role: 'assistant', content: block.substring(0, 10000) });
          }
        }
      }

      // Tool results
      if (event.type === 'tool_result' || event.type === 'tool') {
        // Skip - tool results are verbose
      }
    } catch {
      // Skip unparseable lines
    }
  }

  if (messages.length === 0) {
    console.log(`  SKIP ${file} (no messages parsed)`);
    skipped++;
    continue;
  }

  // Create session
  const id = uuidv4();
  const createdAt = firstTimestamp
    ? new Date(firstTimestamp).toISOString().replace('T', ' ').substring(0, 19)
    : new Date().toISOString().replace('T', ' ').substring(0, 19);

  db.prepare('INSERT INTO sessions (id, name, project_dir, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(id, sessionName, '/home/openclaw', 'idle', createdAt, createdAt);

  // Insert messages
  const insertMsg = db.prepare('INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)');
  for (const msg of messages) {
    insertMsg.run(id, msg.role, msg.content);
  }

  // Insert tool calls
  const insertTool = db.prepare('INSERT INTO tool_calls (session_id, tool_name, tool_input, status) VALUES (?, ?, ?, ?)');
  for (const tc of toolCalls) {
    insertTool.run(id, tc.name, tc.input, tc.status);
  }

  console.log(`  OK ${file}: ${messages.length} messages, ${toolCalls.length} tool calls → session ${id.substring(0, 8)}`);
  imported++;
}

console.log(`\nDone: ${imported} imported, ${skipped} skipped`);
