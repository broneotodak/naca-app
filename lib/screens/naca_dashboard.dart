import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

/// NACA Agent Dashboard — reads directly from neo-brain Supabase
/// No backend proxy needed — Supabase handles CORS natively
class NacaDashboard extends StatefulWidget {
  const NacaDashboard({super.key});

  @override
  State<NacaDashboard> createState() => _NacaDashboardState();
}

class _NacaDashboardState extends State<NacaDashboard> {
  List<dynamic> _agents = [];
  List<dynamic> _commands = [];
  List<dynamic> _locks = [];
  Map<String, int> _queue = {'pending': 0, 'running': 0, 'failed': 0};
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final agents = await _sb.from('agent_heartbeats').select().order('reported_at', ascending: false);
      final commands = await _sb.from('agent_commands').select().order('created_at', ascending: false).limit(10);
      final locks = await _sb.from('agent_locks').select();
      // Count queries
      final pendingRes = await _sb.from('agent_commands').select('id').eq('status', 'pending').count(CountOption.exact);
      final runningRes = await _sb.from('agent_commands').select('id').eq('status', 'running').count(CountOption.exact);
      final failedRes = await _sb.from('agent_commands').select('id').inFilter('status', ['failed', 'dead_letter', 'needs_review']).count(CountOption.exact);

      if (mounted) {
        setState(() {
          _agents = agents;
          _commands = commands;
          _locks = locks;
          _queue = {
            'pending': pendingRes.count,
            'running': runningRes.count,
            'failed': failedRes.count,
          };
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
          Text('NACA://agent-dashboard', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)),
          const SizedBox(height: 8),
          Text('AGENT FLEET', style: HackerTheme.mono(size: 16)),
          const SizedBox(height: 12),

          if (_loading) const Center(child: CircularProgressIndicator(color: HackerTheme.green)),
          if (_error != null) _errorCard(_error!),
          if (!_loading && _error == null) ...[
            _sectionTitle('AGENTS'),
            ..._agents.map((a) => _agentCard(a as Map<String, dynamic>)),

            const SizedBox(height: 16),
            _sectionTitle('COMMAND QUEUE'),
            _queueStats(),

            if (_locks.isNotEmpty) ...[
              const SizedBox(height: 16),
              _sectionTitle('ACTIVE LOCKS'),
              ..._locks.map((l) => _lockCard(l as Map<String, dynamic>)),
            ],

            const SizedBox(height: 16),
            _sectionTitle('RECENT COMMANDS'),
            ..._commands.map((c) => _commandCard(c as Map<String, dynamic>)),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text('// $text', style: HackerTheme.mono(size: 10, color: HackerTheme.dimText)),
  );

  Widget _agentCard(Map<String, dynamic> agent) {
    final name = agent['agent_name'] ?? '?';
    final status = agent['status'] ?? 'unknown';
    final meta = agent['meta'] as Map<String, dynamic>? ?? {};
    final reportedAt = agent['reported_at'] as String?;

    final statusColor = status == 'ok' ? HackerTheme.green : status == 'degraded' ? HackerTheme.amber : HackerTheme.red;
    final statusIcon = status == 'ok' ? '●' : status == 'degraded' ? '◐' : '○';
    final ago = reportedAt != null ? _timeAgo(DateTime.parse(reportedAt)) : 'never';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(active: status == 'ok'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(statusIcon, style: TextStyle(color: statusColor, fontSize: 14)),
            const SizedBox(width: 8),
            Text(name.toString().toUpperCase(), style: HackerTheme.mono(size: 13, color: statusColor)),
            const Spacer(),
            Text(ago, style: HackerTheme.mono(size: 10, color: HackerTheme.grey)),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 12, children: [
            if (meta['version'] != null) Text('v:${meta['version']}', style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
            if (meta['memory_mb'] != null) Text('mem:${meta['memory_mb']}MB', style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
            if (meta['wa_status'] != null) Text('wa:${meta['wa_status']}', style: HackerTheme.mono(size: 9, color: meta['wa_status'] == 'connected' ? HackerTheme.green : HackerTheme.amber)),
            if (meta['model'] != null) Text('model:${meta['model']}', style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
          ]),
        ],
      ),
    );
  }

  Widget _queueStats() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _statBadge('PENDING', _queue['pending']!, HackerTheme.amber),
        _statBadge('RUNNING', _queue['running']!, HackerTheme.cyan),
        _statBadge('FAILED', _queue['failed']!, HackerTheme.red),
      ]),
    );
  }

  Widget _statBadge(String label, int count, Color color) => Column(children: [
    Text('$count', style: HackerTheme.mono(size: 20, color: count > 0 ? color : HackerTheme.grey)),
    Text(label, style: HackerTheme.mono(size: 9, color: HackerTheme.dimText)),
  ]);

  Widget _lockCard(Map<String, dynamic> lock) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.all(8),
    decoration: HackerTheme.terminalBox(),
    child: Row(children: [
      const Text('🔒 ', style: TextStyle(fontSize: 12)),
      Text('${lock['project']}', style: HackerTheme.mono(size: 11, color: HackerTheme.amber)),
      const Spacer(),
      Text('by ${lock['agent_name']}', style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
    ]),
  );

  Widget _commandCard(Map<String, dynamic> cmd) {
    final status = cmd['status'] ?? '?';
    final command = cmd['command'] ?? '?';
    final fromAgent = cmd['from_agent'] ?? '?';
    final toAgent = cmd['to_agent'] ?? '?';
    final payload = cmd['payload'] as Map<String, dynamic>? ?? {};
    final createdAt = cmd['created_at'] as String?;

    final statusColor = switch (status) {
      'done' => HackerTheme.green,
      'running' => HackerTheme.cyan,
      'pending' || 'needs_review' => HackerTheme.amber,
      _ => HackerTheme.red,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: statusColor, width: 2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(status.toString().toUpperCase(), style: HackerTheme.mono(size: 9, color: statusColor)),
          const SizedBox(width: 8),
          Expanded(child: Text(command.toString(), style: HackerTheme.mono(size: 11))),
          if (createdAt != null) Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.mono(size: 9, color: HackerTheme.grey)),
        ]),
        Text('$fromAgent → $toAgent', style: HackerTheme.mono(size: 9, color: HackerTheme.dimText)),
        if (payload['description'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              (payload['description'] as String).length > 80 ? '${(payload['description'] as String).substring(0, 80)}...' : payload['description'],
              style: HackerTheme.mono(size: 9, color: HackerTheme.grey),
            ),
          ),
      ]),
    );
  }

  Widget _errorCard(String error) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.red)),
    child: Text('ERROR: $error', style: HackerTheme.mono(size: 11, color: HackerTheme.red)),
  );

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
