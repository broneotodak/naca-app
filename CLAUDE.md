# CLAUDE.md — NACA App (Neo Agentic Centre Application)

## Overview
Forked from Lan's CCC (github.com/BroLanTodak/ccc). Extends the Claude Code terminal interface with NACA agent panels: agent dashboard, PR approvals, health monitoring, Siti WhatsApp bridge, memory viewer.

## Original (CCC)
- Flutter cross-platform app (iOS/Android/macOS/Web)
- Node.js backend spawning Claude Code CLI sessions
- WebSocket streaming for real-time terminal output
- Session management via SQLite

## NACA Additions (planned)
- Agent status dashboard (reads agent_heartbeats from neo-brain)
- Command queue viewer (agent_commands)
- PR approval interface (GitHub API)
- Health report viewer
- Siti WhatsApp message bridge
- Memory/person viewer
- Project switcher

## Tech Stack
- **Frontend**: Flutter (Dart 3.11+), xterm.dart, web_socket_channel, supabase_flutter
- **Backend**: Node.js, @anthropic-ai/claude-code, ws, better-sqlite3
- **Data**: Supabase (neo-brain xsunmervpyrplzarebva) for agent state
- **Auth**: Bearer token (CCC pattern)

## Structure
```
backend/         — Node.js server (584 lines)
  server.js      — HTTP REST + WebSocket endpoints
  session-manager.js — Claude Code session lifecycle
  db.js          — SQLite persistence
lib/             — Flutter app (1665 lines)
  main.dart      — Entry point
  screens/       — home_screen.dart (main UI, 1103 lines)
  services/      — api_service.dart, ws_service.dart
  widgets/       — terminal_card, blinking_cursor, scanline_overlay
  theme.dart     — Green hacker terminal theme
```

## Commands
```bash
# Backend
cd backend && npm install && node server.js

# Flutter
flutter pub get
flutter run -d chrome  # web
flutter run -d macos   # desktop
flutter build ios      # iOS
flutter build apk      # Android
```

## Rules
- Keep Lan's terminal functionality intact — don't break existing features
- Add NACA panels as new tabs/screens, not by modifying home_screen
- Use Supabase Realtime for live agent data (not polling)
- Follow the green hacker terminal theme
- Test on mobile before shipping
