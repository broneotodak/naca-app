import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/api_service.dart';

class NacaDashboard extends StatefulWidget {
  const NacaDashboard({super.key});

  @override
  State<NacaDashboard> createState() => _NacaDashboardState();
}

class _NacaDashboardState extends State<NacaDashboard> {
  Map<String, dynamic>? _summary;
  List<dynamic> _commands = [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = ApiService();
      final summary = await api.get('/api/agents/summary');
      final cmds = await api.get('/api/agents/commands?limit=10');
      if (mounted) {
        setState(() {
          _summary = summary;
          _commands = cmds['commands'] ?? [];
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text('NACA://agent-dashboard', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)),
          const SizedBox(height: 8),
          Text('AGENT FLEET', style: HackerTheme.mono(size: 16)),
          const SizedBox(height: 12),

          if (_loading) const Center(child: CircularProgressIndicator(color: HackerTheme.green)),
          if (_error != null) _errorCard(_error!),
          if (_summary != null) ...[
            // Agent cards
            _sectionTitle('AGENTS'),
            ...(_summary!['agents'] as List? ?? []).map((a) => _agentCard(a)),

            const SizedBox(height: 16),

            // Queue stats
            _sectionTitle('COMMAND QUEUE'),
            _queueStats(_summary!['queue'] ?? {}),

            const SizedBox(height: 16),

            // Active locks
            if ((_summary!['locks'] as List?)?.isNotEmpty ?? false) ...[
              _sectionTitle('ACTIVE LOCKS'),
              ...(_summary!['locks'] as List).map((l) => _lockCard(l)),
              const SizedBox(height: 16),
            ],

            // Recent commands
            _sectionTitle('RECENT COMMANDS'),
            ..._commands.map((c) => _commandCard(c)),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text('// $text', style: HackerTheme.mono(size: 10, color: HackerTheme.dimText)),
    );
  }

  Widget _agentCard(Map<String, dynamic> agent) {
    final name = agent['agent_name'] ?? '?';
    final status = agent['status'] ?? 'unknown';
    final meta = agent['meta'] as Map<String, dynamic>? ?? {};
    final reportedAt = agent['reported_at'] as String?;

    Color statusColor;
    String statusIcon;
    switch (status) {
      case 'ok':
        statusColor = HackerTheme.green;
        statusIcon = '●';
        break;
      case 'degraded':
        statusColor = HackerTheme.amber;
        statusIcon = '◐';
        break;
      default:
        statusColor = HackerTheme.red;
        statusIcon = '○';
    }

    final ago = reportedAt != null
        ? _timeAgo(DateTime.parse(reportedAt))
        : 'never';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(active: status == 'ok'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(statusIcon, style: TextStyle(color: statusColor, fontSize: 14)),
              const SizedBox(width: 8),
              Text(name.toUpperCase(), style: HackerTheme.mono(size: 13, color: statusColor)),
              const Spacer(),
              Text(ago, style: HackerTheme.mono(size: 10, color: HackerTheme.grey)),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            children: [
              if (meta['version'] != null)
                Text('v:${meta['version']}', style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
              if (meta['memory_mb'] != null)
                Text('mem:${meta['memory_mb']}MB', style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
              if (meta['wa_status'] != null)
                Text('wa:${meta['wa_status']}', style: HackerTheme.mono(size: 9, color: meta['wa_status'] == 'connected' ? HackerTheme.green : HackerTheme.amber)),
              if (meta['model'] != null)
                Text('model:${meta['model']}', style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _queueStats(Map<String, dynamic> queue) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _statBadge('PENDING', queue['pending'] ?? 0, HackerTheme.amber),
          _statBadge('RUNNING', queue['running'] ?? 0, HackerTheme.cyan),
          _statBadge('FAILED', queue['failed'] ?? 0, HackerTheme.red),
        ],
      ),
    );
  }

  Widget _statBadge(String label, int count, Color color) {
    return Column(
      children: [
        Text('$count', style: HackerTheme.mono(size: 20, color: count > 0 ? color : HackerTheme.grey)),
        Text(label, style: HackerTheme.mono(size: 9, color: HackerTheme.dimText)),
      ],
    );
  }

  Widget _lockCard(Map<String, dynamic> lock) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: HackerTheme.terminalBox(),
      child: Row(
        children: [
          Text('🔒 ', style: const TextStyle(fontSize: 12)),
          Text('${lock['project']}', style: HackerTheme.mono(size: 11, color: HackerTheme.amber)),
          const Spacer(),
          Text('by ${lock['agent_name']}', style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
        ],
      ),
    );
  }

  Widget _commandCard(Map<String, dynamic> cmd) {
    final status = cmd['status'] ?? '?';
    final command = cmd['command'] ?? '?';
    final fromAgent = cmd['from_agent'] ?? '?';
    final toAgent = cmd['to_agent'] ?? '?';
    final payload = cmd['payload'] as Map<String, dynamic>? ?? {};
    final createdAt = cmd['created_at'] as String?;

    Color statusColor;
    switch (status) {
      case 'done': statusColor = HackerTheme.green; break;
      case 'running': statusColor = HackerTheme.cyan; break;
      case 'pending': statusColor = HackerTheme.amber; break;
      case 'needs_review': statusColor = HackerTheme.amber; break;
      default: statusColor = HackerTheme.red;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: statusColor, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(status.toUpperCase(), style: HackerTheme.mono(size: 9, color: statusColor)),
              const SizedBox(width: 8),
              Expanded(child: Text(command, style: HackerTheme.mono(size: 11))),
              if (createdAt != null)
                Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
            ],
          ),
          Text('$fromAgent → $toAgent', style: HackerTheme.mono(size: 9, color: HackerTheme.dimText)),
          if (payload['description'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                (payload['description'] as String).length > 80
                    ? '${(payload['description'] as String).substring(0, 80)}...'
                    : payload['description'],
                style: HackerTheme.mono(size: 9, color: HackerTheme.grey),
              ),
            ),
          if (cmd['result'] != null && (cmd['result'] as Map?)?.containsKey('pr_url') == true)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('PR: ${cmd['result']['pr_url']}', style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
            ),
        ],
      ),
    );
  }

  Widget _errorCard(String error) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.red)),
      child: Text('ERROR: $error', style: HackerTheme.mono(size: 11, color: HackerTheme.red)),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
