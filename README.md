# CCC - Claude Command Center

A multi-platform app for managing remote [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions from anywhere. Run Claude Code on a VPS, interact with it from your phone, tablet, or desktop.

```
 ██████╗  ██████╗  ██████╗
██╔════╝ ██╔════╝ ██╔════╝
██║      ██║      ██║
██║      ██║      ██║
╚██████╗ ╚██████╗ ╚██████╗
 ╚═════╝  ╚═════╝  ╚═════╝
 CLAUDE COMMAND CENTER
```

## What is this?

CCC gives you a **terminal-style UI** to control Claude Code running on a remote server. Think of it as a remote control for your AI coding assistant.

- **Multi-session** — Run multiple Claude Code sessions simultaneously
- **Real-time streaming** — See Claude's responses as they come in via WebSocket
- **Tool visibility** — See every tool call (Read, Edit, Bash, Grep) Claude makes
- **Image attach** — Paste screenshots or pick images to send to Claude for analysis
- **Cross-platform** — Same app on iOS, Android, macOS, web
- **Hacker terminal aesthetic** — Green-on-black theme with scanlines and glow effects

## Architecture

```
┌─────────────────────────────────────────┐
│  Flutter App (iOS/Android/macOS/Web)    │
│  ├── REST API (sessions CRUD)           │
│  └── WebSocket (real-time streaming)    │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  Node.js Backend (on VPS)               │
│  ├── Session Manager                    │
│  ├── Claude Code CLI spawner            │
│  ├── SQLite (sessions, messages, tools) │
│  └── Image upload handler               │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│  Claude Code CLI                        │
│  └── --output-format stream-json        │
│  └── --resume (multi-turn)              │
│  └── --dangerously-skip-permissions     │
└─────────────────────────────────────────┘
```

## Features

### Multi-Session Management
Create, start, stop, rename, and delete Claude Code sessions. Each session maintains its own conversation history and can be resumed.

### Split View (Desktop)
Run 2 or 4 sessions side-by-side on desktop for parallel workflows.

### Image Attachments
- **Cmd+V / Ctrl+V** — Paste screenshots directly from clipboard
- **Camera** — Take photos on mobile
- **Gallery** — Pick images from photo library
- Images are uploaded to the server and Claude reads them via its Read tool

### Session Tabs (Mobile)
Horizontal scrollable tabs for quick session switching on phones/tablets.

### Conversation Length Indicator
See how many turns each session has at a glance.

## Setup

### Prerequisites
- A VPS/server with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- Node.js 18+ on the server
- Flutter SDK on your dev machine (for building the app)

### 1. Backend Setup

```bash
# On your VPS
cd backend/
cp .env.example .env
# Edit .env — set your AUTH_TOKEN
npm install
node server.js
# Or use pm2:
pm2 start server.js --name ccc
```

### 2. Frontend Setup

```bash
# On your dev machine
cp lib/config.dart.example lib/config.dart
# Edit config.dart — set your server IP and auth token
```

### 3. Build & Run

```bash
# Web
flutter build web --release

# macOS
flutter build macos --release

# iOS (device connected via USB)
flutter run -d <device-id> --release

# Android
flutter build apk --release

# Or run in debug mode
flutter run
```

### 4. Deploy Web

```bash
# Copy web build to your server's web root
scp -r build/web/* user@server:/var/www/ccc/
```

## Configuration

### `lib/config.dart`
```dart
class AppConfig {
  static const apiBaseUrl = 'http://YOUR_SERVER_IP:3100';
  static const wsUrl = 'ws://YOUR_SERVER_IP:3100';
  static const authToken = 'YOUR_AUTH_TOKEN_HERE';
}
```

### `backend/.env`
```
PORT=3100
AUTH_TOKEN=your_secret_token_here
```

## Security Notes

- `lib/config.dart` and `backend/.env` are gitignored — they contain secrets
- The backend uses Bearer token auth for both REST and WebSocket
- For production, put the backend behind Nginx with HTTPS
- Claude Code runs with `--dangerously-skip-permissions` — only use on trusted servers

## Tech Stack

| Component | Tech |
|-----------|------|
| Frontend | Flutter (Dart) |
| Backend | Node.js (vanilla HTTP + ws) |
| Database | SQLite (better-sqlite3) |
| AI | Claude Code CLI |
| Streaming | WebSocket |
| Process | Child process spawning with stream-json parsing |

## License

MIT
