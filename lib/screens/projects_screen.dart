import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

/// Projects — view active projects, their agents, recent PRs
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  SupabaseClient get _sb => Supabase.instance.client;

  // All Neo's projects
  final List<_Project> _projects = [
    // Active / Priority
    _Project('todak-academy', 'Todak Academy', 'Education portal — 17 pages built', 'academy.todak.com', HackerTheme.cyan),
    _Project('thr', 'THR / ATLAS', 'HR + Asset management', 'thr.todak.com', HackerTheme.green),
    _Project('clauden', 'ClaudeN Dashboard', 'Digital twin + AI chat', 'clauden.neotodak.com', HackerTheme.amber),
    _Project('siti', 'Siti (NClaw)', 'WhatsApp AI bot + person graph', 'VPS :3800', HackerTheme.green),
    _Project('dev-agent', 'Dev Agent', 'Auto bug-fix from WhatsApp', 'VPS PM2', HackerTheme.cyan),
    _Project('naca-app', 'NACA App', 'This app — Agentic Centre', 'mobile/web', HackerTheme.green),
    // Infrastructure
    _Project('neo-brain', 'Neo-Brain', 'Unified memory (Supabase)', 'xsunmervpyrplzarebva', HackerTheme.amber),
    _Project('claude-tools-kit', 'Claude Tools Kit', '@todak/memory SDK + tools', 'npm package', HackerTheme.cyan),
    _Project('openclaw', 'OpenClaw Fleet', 'Gateway, router, reminder', 'CLAW 100.93.159.1', HackerTheme.green),
    // Websites
    _Project('presentation', 'Presentation Hub', 'Demos, crypto dashboard, AI SaaS', 'presentation.neotodak.com', HackerTheme.grey),
    _Project('broneotodak', 'broneotodak.com', 'Public twin chat', 'broneotodak.com', HackerTheme.grey),
    _Project('todak-studios', 'Todak Studios 2026', 'Company website', 'todak.com', HackerTheme.grey),
    // Parked
    _Project('askmylegal', 'AskMyLegal', 'Legal AI platform (planning)', 'PARKED', HackerTheme.dimText),
    _Project('iammuslim', 'iammuslim.com', 'Islamic content + hadith', 'PARKED', HackerTheme.dimText),
    _Project('musclehub', 'MuscleHub', 'Gym management (archived)', 'ARCHIVED', HackerTheme.dimText),
  ];

  List<Map<String, dynamic>> _commands = [];
  List<Map<String, dynamic>> _locks = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cmds = await _sb.from('agent_commands').select().order('created_at', ascending: false).limit(50);
      final locks = await _sb.from('agent_locks').select();
      if (mounted) setState(() {
        _commands = List<Map<String, dynamic>>.from(cmds);
        _locks = List<Map<String, dynamic>>.from(locks);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: HackerTheme.green))
                : ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      _section('ACTIVE PROJECTS'),
                      ..._projects.map(_buildProjectCard),
                      const SizedBox(height: 16),
                      _section('PROJECT ACTIVITY'),
                      ..._buildProjectActivity(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: HackerTheme.bgPanel,
        border: Border(bottom: BorderSide(color: HackerTheme.borderDim)),
      ),
      child: Row(children: [
        Text('NACA://', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
        Text('projects', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
      ]),
    );
  }

  Widget _buildProjectCard(_Project p) {
    final lock = _locks.where((l) => l['project'] == p.id).toList();
    final cmdCount = _commands.where((c) {
      final payload = c['payload'] as Map<String, dynamic>? ?? {};
      return payload['project'] == p.id || c['to_agent'] == p.id;
    }).length;
    final isLocked = lock.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: p.color, width: 3)),
        boxShadow: isLocked ? [BoxShadow(color: HackerTheme.amber.withValues(alpha: 0.15), blurRadius: 8)] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(p.name, style: HackerTheme.monoNoGlow(size: 12, color: p.color))),
            if (isLocked) Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: HackerTheme.amber)),
              child: Text('LOCKED by ${lock.first['agent_name']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.amber)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(p.desc, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
          const SizedBox(height: 4),
          Row(children: [
            Text(p.host, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
            const Spacer(),
            if (cmdCount > 0) Text('$cmdCount cmds', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
          ]),
        ],
      ),
    );
  }

  List<Widget> _buildProjectActivity() {
    if (_commands.isEmpty) {
      return [Container(
        padding: const EdgeInsets.all(16),
        decoration: HackerTheme.terminalBox(),
        child: Center(child: Text('No recent activity', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText))),
      )];
    }

    return _commands.take(10).map((cmd) {
      final status = cmd['status'] ?? '?';
      final command = cmd['command'] ?? '?';
      final to = cmd['to_agent'] ?? '?';
      final createdAt = cmd['created_at'] as String?;
      final statusColor = switch (status) {
        'done' => HackerTheme.green,
        'running' => HackerTheme.cyan,
        'pending' => HackerTheme.amber,
        _ => HackerTheme.red,
      };

      return Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: statusColor, width: 2)),
        ),
        child: Row(children: [
          SizedBox(width: 50, child: Text(status.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 8, color: statusColor))),
          Expanded(child: Text('$command → $to', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white))),
          if (createdAt != null) Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
        ]),
      );
    }).toList();
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text('// $text', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
  );

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _Project {
  final String id, name, desc, host;
  final Color color;
  const _Project(this.id, this.name, this.desc, this.host, this.color);
}
