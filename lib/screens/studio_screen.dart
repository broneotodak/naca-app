import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../theme.dart';

/// STUDIO — operator console for the NACA fleet.
///
/// 4-segment shell: TEMPLATES (default — daily-content theme editor),
/// AGENTS (read-only per-runner explainer — what each fleet runner does),
/// JOBS (live + recent agent_commands and upcoming scheduled_actions),
/// COST (subscriptions/bills + month-to-date provider activity).
///
/// Pause/resume of individual agents lives on the HQ tab, where the agent
/// listing already is — see dashboard_screen.dart `_buildAgentCard`. The
/// AGENTS segment here is read-only (it explains what each runner does and
/// its live status); it deliberately does NOT duplicate that control.
///
/// Backend endpoints used here:
///   - `GET   /api/content-templates`          — templates list
///   - `PATCH /api/content-templates/{id}`     — toggle / edit
///   - `POST  /api/content-templates`          — create
///   - `GET   /api/studio/agents`              — AGENTS view (registry + heartbeat + classification)
///   - `GET   /api/studio/jobs`                — JOBS view (running/recent/upcoming)
///   - `GET   /api/costs`                      — COST view: subscriptions/bills
///   - `GET   /api/studio/costs`               — COST view: MTD provider activity
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

enum _Segment { templates, agents, jobs, cost }

class _StudioScreenState extends State<StudioScreen> {
  _Segment _segment = _Segment.templates;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          _buildSegmentBar(),
          Expanded(child: _buildSegmentBody()),
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
        Text('studio', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
      ]),
    );
  }

  Widget _buildSegmentBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: HackerTheme.bgPanel,
        border: Border(bottom: BorderSide(color: HackerTheme.borderDim)),
      ),
      child: Row(children: [
        _segmentButton('TEMPLATES', _Segment.templates),
        const SizedBox(width: 6),
        _segmentButton('AGENTS', _Segment.agents),
        const SizedBox(width: 6),
        _segmentButton('JOBS', _Segment.jobs),
        const SizedBox(width: 6),
        _segmentButton('COST', _Segment.cost),
      ]),
    );
  }

  Widget _segmentButton(String label, _Segment seg) {
    final sel = _segment == seg;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _segment = seg),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: sel ? HackerTheme.green : HackerTheme.borderDim),
            color: sel ? HackerTheme.greenDim : Colors.transparent,
          ),
          child: Text(label,
              style: HackerTheme.mono(
                  size: 10,
                  color: sel ? HackerTheme.green : HackerTheme.grey)),
        ),
      ),
    );
  }

  Widget _buildSegmentBody() {
    switch (_segment) {
      case _Segment.templates:
        return const _TemplatesView();
      case _Segment.agents:
        return const _AgentsView();
      case _Segment.jobs:
        return const _JobsView();
      case _Segment.cost:
        return const _CostView();
    }
  }
}


// =============================================================================
// JOBS view — fleet work at a glance: in-flight + recently-finished
// agent_commands and upcoming scheduled_actions. Read-only; consumes
// GET /api/studio/jobs. Polls every 15s.
// =============================================================================

class _JobsView extends StatefulWidget {
  const _JobsView();
  @override
  State<_JobsView> createState() => _JobsViewState();
}

class _JobsViewState extends State<_JobsView> {
  List<Map<String, dynamic>> _running = [];
  List<Map<String, dynamic>> _recent = [];
  List<Map<String, dynamic>> _upcoming = [];
  Map<String, int> _stats = {};
  bool _loading = true;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/studio/jobs?limit=25'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        if (mounted) setState(() { _loading = false; _error = 'HTTP ${res.statusCode}'; });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _running = List<Map<String, dynamic>>.from(body['running'] ?? const []);
          _recent = List<Map<String, dynamic>>.from(body['recent'] ?? const []);
          _upcoming = List<Map<String, dynamic>>.from(body['upcoming'] ?? const []);
          _stats = Map<String, int>.from(
              (body['stats'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toInt())) ?? {});
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // ---- helpers ----

  /// Compact relative time. Past → "3m ago"; future → "in 2h".
  String _rel(String? iso) {
    if (iso == null) return '';
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final diff = DateTime.now().difference(t);
    final future = diff.isNegative;
    final s = diff.abs();
    String mag;
    if (s.inSeconds < 60) {
      mag = '${s.inSeconds}s';
    } else if (s.inMinutes < 60) {
      mag = '${s.inMinutes}m';
    } else if (s.inHours < 24) {
      mag = '${s.inHours}h';
    } else {
      mag = '${s.inDays}d';
    }
    return future ? 'in $mag' : '$mag ago';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'done':
        return HackerTheme.green;
      case 'failed':
        return HackerTheme.red;
      case 'cancelled':
        return HackerTheme.grey;
      case 'scheduled':
        return HackerTheme.amber;
      default: // pending / claimed / running / in-flight
        return HackerTheme.cyan;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('// load error', style: HackerTheme.mono(size: 12, color: HackerTheme.red)),
          const SizedBox(height: 6),
          Text(_error!, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _load,
            child: Text('RETRY', style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
          ),
        ]),
      );
    }
    if (_running.isEmpty && _recent.isEmpty && _upcoming.isEmpty) {
      return Center(
          child: Text('// no jobs — queue is idle',
              style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)));
    }
    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgPanel,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
        children: [
          _section('RUNNING', _running.length, HackerTheme.cyan),
          if (_running.isEmpty) _empty('nothing in flight'),
          ..._running.map(_commandCard),
          const SizedBox(height: 10),
          _section('UPCOMING', _upcoming.length, HackerTheme.amber),
          if (_upcoming.isEmpty) _empty('nothing scheduled'),
          ..._upcoming.map(_scheduledCard),
          const SizedBox(height: 10),
          _section('RECENT',
              (_stats['recent_done'] ?? 0) + (_stats['recent_failed'] ?? 0),
              HackerTheme.green),
          if (_recent.isEmpty) _empty('no recent finishes'),
          ..._recent.map(_commandCard),
        ],
      ),
    );
  }

  Widget _section(String label, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(children: [
        Text('// $label', style: HackerTheme.mono(size: 11, color: color)),
        const SizedBox(width: 8),
        Text('[$count]', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
        const Expanded(child: Divider(color: HackerTheme.borderDim, indent: 10)),
      ]),
    );
  }

  Widget _empty(String msg) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 4),
        child: Text('  $msg', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
      );

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
        child: Text(text, style: HackerTheme.monoNoGlow(size: 8, color: color)),
      );

  /// agent_commands row → card (used for both RUNNING and RECENT).
  Widget _commandCard(Map<String, dynamic> c) {
    final status = (c['status'] ?? 'pending').toString();
    final color = _statusColor(status);
    final from = (c['from_agent'] ?? '?').toString();
    final to = (c['to_agent'] ?? '?').toString();
    final cmd = (c['command'] ?? '?').toString();
    final done = c['completed_at'] != null;
    final when = _rel((done ? c['completed_at'] : c['created_at'])?.toString());
    final retries = (c['retry_count'] ?? 0) as num;
    final failed = status == 'failed';
    final result = c['result']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: HackerTheme.terminalBox(),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(cmd, style: HackerTheme.mono(size: 12, color: HackerTheme.green),
                  overflow: TextOverflow.ellipsis),
            ),
            _tag(status.toUpperCase(), color),
          ]),
          const SizedBox(height: 5),
          Text('$from → $to',
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
          const SizedBox(height: 4),
          Row(children: [
            Text(when, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
            if (retries > 0) ...[
              const SizedBox(width: 8),
              Text('↺ $retries', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.amber)),
            ],
          ]),
          if (failed && result != null && result.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              result.length > 160 ? '${result.substring(0, 160)}…' : result,
              style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ]),
      ),
    );
  }

  /// scheduled_actions row → card (UPCOMING).
  Widget _scheduledCard(Map<String, dynamic> s) {
    final kind = (s['action_kind'] ?? '?').toString();
    final desc = (s['description'] ?? '').toString();
    final fire = _rel(s['fire_at']?.toString());
    final recurring = s['recurrence'] != null;
    final attempts = (s['attempts'] ?? 0) as num;
    final maxAttempts = (s['max_attempts'] ?? 0) as num;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: HackerTheme.terminalBox(),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(kind, style: HackerTheme.mono(size: 12, color: HackerTheme.amber),
                  overflow: TextOverflow.ellipsis),
            ),
            if (recurring) _tag('RECUR', HackerTheme.cyan),
            if (recurring) const SizedBox(width: 4),
            _tag(fire.toUpperCase(), HackerTheme.amber),
          ]),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(desc,
                style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (attempts > 0) ...[
            const SizedBox(height: 4),
            Text('attempts $attempts/$maxAttempts',
                style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
          ],
        ]),
      ),
    );
  }
}

// =============================================================================
// COST view — two honest halves:
//   SUBSCRIPTIONS  — recurring SaaS/infra bills (GET /api/costs)
//   PROVIDER ACT.  — month-to-date generation events per provider
//                    (GET /api/studio/costs). creator_billing logs usage,
//                    not dollars (usd_cents is NULL today), so when
//                    cost_tracked is false we show event counts, not $.
// Polls every 60s (cost data changes slowly).
// =============================================================================

class _CostView extends StatefulWidget {
  const _CostView();
  @override
  State<_CostView> createState() => _CostViewState();
}

class _CostViewState extends State<_CostView> {
  List<Map<String, dynamic>> _subs = [];
  double _subTotalUsd = 0;
  List<Map<String, dynamic>> _providers = [];
  bool _costTracked = false;
  int _providerEvents = 0;
  double _billedUsd = 0;
  String _month = '';
  bool _loading = true;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final headers = {'Authorization': 'Bearer ${AppConfig.authToken}'};
      final results = await Future.wait([
        http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/costs'), headers: headers).timeout(const Duration(seconds: 20)),
        http.get(Uri.parse('${AppConfig.apiBaseUrl}/api/studio/costs'), headers: headers).timeout(const Duration(seconds: 15)),
      ]);
      final subsRes = results[0];
      final provRes = results[1];
      if (subsRes.statusCode >= 400 && provRes.statusCode >= 400) {
        if (mounted) setState(() { _loading = false; _error = 'HTTP ${subsRes.statusCode}/${provRes.statusCode}'; });
        return;
      }
      final subsBody = subsRes.statusCode < 400 ? jsonDecode(subsRes.body) as Map<String, dynamic> : const {};
      final provBody = provRes.statusCode < 400 ? jsonDecode(provRes.body) as Map<String, dynamic> : const {};
      if (mounted) {
        setState(() {
          _subs = List<Map<String, dynamic>>.from(subsBody['services'] ?? const []);
          _subTotalUsd = (subsBody['totalEstimate'] as num?)?.toDouble() ?? 0;
          _providers = List<Map<String, dynamic>>.from(provBody['providers'] ?? const []);
          final totals = (provBody['totals'] as Map?) ?? const {};
          _costTracked = totals['cost_tracked'] == true;
          _providerEvents = (totals['events'] as num?)?.toInt() ?? 0;
          _billedUsd = (totals['billed_usd'] as num?)?.toDouble() ?? 0;
          _month = (provBody['month'] ?? '').toString();
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  String _money(num v, String cur) {
    final sym = cur == 'usd' ? '\$' : (cur == 'eur' ? '€' : (cur == 'myr' ? 'RM' : ''));
    final n = v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    return '$sym$n${sym.isEmpty ? ' ${cur.toUpperCase()}' : ''}';
  }

  Color _subStatusColor(String s) {
    switch (s) {
      case 'active':
        return HackerTheme.green;
      case 'estimated':
        return HackerTheme.amber;
      case 'unknown':
        return HackerTheme.red;
      default:
        return HackerTheme.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('// load error', style: HackerTheme.mono(size: 12, color: HackerTheme.red)),
          const SizedBox(height: 6),
          Text(_error!, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _load,
            child: Text('RETRY', style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgPanel,
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
        children: [
          _sectionHeader('SUBSCRIPTIONS', '~${_money(_subTotalUsd, 'usd')}/mo', HackerTheme.green),
          if (_subs.isEmpty) _empty('no subscription data'),
          ..._subs.map(_subCard),
          const SizedBox(height: 14),
          _sectionHeader('PROVIDER ACTIVITY · ${_month.isEmpty ? 'MTD' : _month}',
              _costTracked ? _money(_billedUsd, 'usd') : '$_providerEvents events', HackerTheme.cyan),
          if (!_costTracked)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 2, right: 2),
              child: Text(
                '// usage events — per-call \$ not tracked yet (creator_billing.usd_cents unset)',
                style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText),
              ),
            ),
          if (_providers.isEmpty) _empty('no provider activity this month'),
          ..._providers.map(_providerCard),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label, String trailing, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(children: [
        Text('// $label', style: HackerTheme.mono(size: 11, color: color)),
        const Spacer(),
        Text(trailing, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
      ]),
    );
  }

  Widget _empty(String msg) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 4),
        child: Text('  $msg', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
      );

  Widget _subCard(Map<String, dynamic> s) {
    final name = (s['name'] ?? '?').toString();
    final cost = (s['cost'] ?? 0) as num;
    final cur = (s['currency'] ?? 'usd').toString();
    final usage = (s['usage'] ?? '').toString();
    final status = (s['status'] ?? '').toString();
    final tier = s['tier']?.toString();
    final note = s['note']?.toString();
    final color = _subStatusColor(status);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: HackerTheme.terminalBox(),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(name, style: HackerTheme.mono(size: 12, color: HackerTheme.green),
                  overflow: TextOverflow.ellipsis),
            ),
            Text(_money(cost, cur), style: HackerTheme.mono(size: 12, color: HackerTheme.white)),
          ]),
          if (usage.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(usage, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 6),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
              child: Text(status.isEmpty ? '?' : status.toUpperCase(),
                  style: HackerTheme.monoNoGlow(size: 8, color: color)),
            ),
            if (tier != null) ...[
              const SizedBox(width: 6),
              Text(tier.toUpperCase(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
            ],
            if (note != null && note.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(note, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ]),
        ]),
      ),
    );
  }

  Widget _providerCard(Map<String, dynamic> p) {
    final name = (p['tool_name'] ?? '?').toString();
    final events = (p['events'] ?? 0) as num;
    final ok = (p['ok'] ?? 0) as num;
    final failed = (p['failed'] ?? 0) as num;
    final hasUsd = p['has_usd'] == true;
    final usd = ((p['usd_cents'] ?? 0) as num) / 100.0;
    final okFrac = events > 0 ? ok / events : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: HackerTheme.terminalBox(),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(name, style: HackerTheme.mono(size: 12, color: HackerTheme.cyan),
                  overflow: TextOverflow.ellipsis),
            ),
            Text(hasUsd ? _money(usd, 'usd') : '$events',
                style: HackerTheme.mono(size: 12, color: HackerTheme.white)),
          ]),
          const SizedBox(height: 6),
          // success/fail bar
          ClipRect(
            child: Row(children: [
              Expanded(
                flex: (okFrac * 100).round().clamp(0, 100),
                child: Container(height: 4, color: HackerTheme.green),
              ),
              Expanded(
                flex: (100 - (okFrac * 100).round()).clamp(0, 100),
                child: Container(height: 4, color: failed > 0 ? HackerTheme.red : HackerTheme.borderDim),
              ),
            ]),
          ),
          const SizedBox(height: 5),
          Row(children: [
            Text('$events events', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
            const SizedBox(width: 10),
            Text('$ok ok', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.green)),
            if (failed > 0) ...[
              const SizedBox(width: 8),
              Text('$failed fail', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red)),
            ],
          ]),
        ]),
      ),
    );
  }
}

// =============================================================================
// Daily-content templates editor — the default Studio segment.
// Logic preserved from the original single-purpose Studio tab.
// =============================================================================

class _TemplatesView extends StatefulWidget {
  const _TemplatesView();
  @override
  State<_TemplatesView> createState() => _TemplatesViewState();
}

class _TemplatesViewState extends State<_TemplatesView> {
  List<Map<String, dynamic>> _templates = [];
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/content-templates'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        if (mounted) setState(() { _loading = false; _error = 'HTTP ${res.statusCode}'; });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) setState(() {
        _templates = List<Map<String, dynamic>>.from(body['templates'] ?? const []);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _snack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: color));
  }

  Future<void> _patch(String id, Map<String, dynamic> patch) async {
    setState(() => _busy.add(id));
    try {
      final res = await http.patch(
        Uri.parse('${AppConfig.apiBaseUrl}/api/content-templates/$id'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(patch),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        _snack('Save failed: ${_errOf(res)}', HackerTheme.red);
      } else {
        await _load(silent: true);
      }
    } catch (e) {
      _snack('Save error: $e', HackerTheme.red);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _create(Map<String, dynamic> fields) async {
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/content-templates'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(fields),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        _snack('Create failed: ${_errOf(res)}', HackerTheme.red);
      } else {
        _snack('Theme created (inactive — turn it on when ready)', HackerTheme.green);
        await _load(silent: true);
      }
    } catch (e) {
      _snack('Create error: $e', HackerTheme.red);
    }
  }

  String _errOf(http.Response res) {
    try {
      final j = jsonDecode(res.body);
      if (j is Map && j['error'] != null) return j['error'].toString();
    } catch (_) {}
    return 'HTTP ${res.statusCode}';
  }

  Future<void> _openEditor({Map<String, dynamic>? template}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _TemplateDialog(template: template),
    );
    if (result == null) return;
    if (template == null) {
      await _create(result);
    } else {
      await _patch(template['id'].toString(), result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      _buildBody(),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton.extended(
          heroTag: 'studio-new-theme',
          onPressed: () => _openEditor(),
          backgroundColor: HackerTheme.bgPanel,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
            side: BorderSide(color: HackerTheme.green),
          ),
          icon: const Icon(Icons.add, color: HackerTheme.green, size: 16),
          label: Text('NEW THEME',
              style: HackerTheme.mono(size: 10, color: HackerTheme.green)),
        ),
      ),
    ]);
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('// load error', style: HackerTheme.mono(size: 12, color: HackerTheme.red)),
          const SizedBox(height: 6),
          Text(_error!, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _load,
            child: Text('RETRY', style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
          ),
        ]),
      );
    }
    if (_templates.isEmpty) {
      return Center(
          child: Text('// no themes — tap NEW THEME',
              style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)));
    }
    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgPanel,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        itemCount: _templates.length,
        itemBuilder: (_, i) => _buildCard(_templates[i]),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> t) {
    final id = t['id'].toString();
    final active = t['active'] == true;
    final mode = (t['mode'] ?? 'character').toString();
    final kind = (t['kind'] ?? 'video').toString();
    final weight = (t['weight'] ?? 1).toString();
    final cats = (t['categories'] is List) ? (t['categories'] as List).length : 0;
    final modeColor = mode == 'character' ? HackerTheme.green : HackerTheme.cyan;
    final busy = _busy.contains(id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: HackerTheme.terminalBox(active: active),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : () => _openEditor(template: t),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: active ? HackerTheme.green : HackerTheme.dimText,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(t['key']?.toString() ?? '?',
                      style: HackerTheme.mono(size: 13, color: HackerTheme.green)),
                ),
                _tag(mode.toUpperCase(), modeColor),
              ]),
              const SizedBox(height: 6),
              Text(t['display_name']?.toString() ?? '',
                  style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
              const SizedBox(height: 4),
              Text('$kind · weight $weight · $cats categories',
                  style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
              const SizedBox(height: 10),
              Row(children: [
                _activeToggle(id, active, busy),
                const Spacer(),
                _runButton(t),
                const SizedBox(width: 8),
                Text('EDIT',
                    style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: color, width: 1)),
        child: Text(text, style: HackerTheme.monoNoGlow(size: 8, color: color)),
      );

  Widget _activeToggle(String id, bool active, bool busy) {
    return GestureDetector(
      onTap: busy ? null : () => _patch(id, {'active': !active}),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: active ? HackerTheme.green : HackerTheme.dimText, width: 1),
          color: active ? HackerTheme.greenDim : Colors.transparent,
        ),
        child: Text(
          busy ? '...' : (active ? 'ACTIVE' : 'INACTIVE'),
          style: HackerTheme.mono(
              size: 9, color: active ? HackerTheme.green : HackerTheme.dimText),
        ),
      ),
    );
  }

  // RUN NOW — fire an immediate content-creator generate of this theme. Lands
  // as a draft for the normal approval flow (does NOT auto-post). Spends
  // generation credits, so it always confirms first.
  Widget _runButton(Map<String, dynamic> t) {
    final key = t['key']?.toString() ?? '';
    final label = (t['display_name']?.toString().isNotEmpty ?? false)
        ? t['display_name'].toString()
        : key;
    final running = _busy.contains('run:$key');
    return GestureDetector(
      onTap: (running || key.isEmpty) ? null : () => _runNow(key, label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(border: Border.all(color: HackerTheme.cyan, width: 1)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.play_arrow, size: 12, color: HackerTheme.cyan),
          const SizedBox(width: 3),
          Text(running ? '...' : 'RUN NOW',
              style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
        ]),
      ),
    );
  }

  Future<void> _runNow(String templateKey, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: HackerTheme.cyan),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('// run now', style: HackerTheme.mono(size: 13, color: HackerTheme.cyan)),
              const SizedBox(height: 10),
              Text('Generate "$label" immediately?',
                  style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
              const SizedBox(height: 8),
              Text(
                'Queues content-creator now instead of waiting for cron. Spends generation credits and lands as a draft for approval — it does NOT auto-post.',
                style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey),
              ),
              const SizedBox(height: 16),
              Row(children: [
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text('CANCEL', style: HackerTheme.mono(size: 11, color: HackerTheme.grey)),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(true),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: HackerTheme.cyan),
                      color: HackerTheme.greenDim,
                    ),
                    child: Text('RUN NOW', style: HackerTheme.mono(size: 11, color: HackerTheme.cyan)),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _busy.add('run:$templateKey'));
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/agents/run-now'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'agent': 'content-creator',
          'command': 'generate_theme',
          'template_key': templateKey,
        }),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        _snack('Run failed: ${_errOf(res)}', HackerTheme.red);
      } else {
        _snack('Queued "$label" — watch the JOBS tab', HackerTheme.green);
      }
    } catch (e) {
      _snack('Run error: $e', HackerTheme.red);
    } finally {
      if (mounted) setState(() => _busy.remove('run:$templateKey'));
    }
  }
}

/// Edit / create dialog for a content template. `template` null → create mode.
class _TemplateDialog extends StatefulWidget {
  final Map<String, dynamic>? template;
  const _TemplateDialog({this.template});

  @override
  State<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends State<_TemplateDialog> {
  late final TextEditingController _key;
  late final TextEditingController _displayName;
  late final TextEditingController _weight;
  late final TextEditingController _concept;
  late final TextEditingController _imageTpl;
  late final TextEditingController _actionSuffix;
  late bool _active;
  late bool _music;
  late String _mode;
  late String _kind;
  late String _narrationLang;

  bool get _isCreate => widget.template == null;

  @override
  void initState() {
    super.initState();
    final t = widget.template ?? const {};
    _key = TextEditingController(text: t['key']?.toString() ?? '');
    _displayName = TextEditingController(text: t['display_name']?.toString() ?? '');
    _weight = TextEditingController(text: (t['weight'] ?? 1).toString());
    _concept = TextEditingController(text: t['concept_prompt']?.toString() ?? '');
    _imageTpl = TextEditingController(text: t['image_prompt_template']?.toString() ?? '');
    _actionSuffix = TextEditingController(text: t['action_suffix']?.toString() ?? '');
    _active = t['active'] == true;
    _music = t['music'] == null ? true : t['music'] == true;
    _mode = (t['mode'] ?? 'character').toString();
    _kind = (t['kind'] ?? 'video').toString();
    _narrationLang = (t['narration_language'] ?? 'en').toString();
  }

  @override
  void dispose() {
    _key.dispose();
    _displayName.dispose();
    _weight.dispose();
    _concept.dispose();
    _imageTpl.dispose();
    _actionSuffix.dispose();
    super.dispose();
  }

  void _submit() {
    final fields = <String, dynamic>{
      'display_name': _displayName.text.trim(),
      'weight': int.tryParse(_weight.text.trim()) ?? 1,
      'concept_prompt': _concept.text.trim(),
      'image_prompt_template': _imageTpl.text.trim(),
      'action_suffix': _actionSuffix.text.trim(),
      'active': _active,
      'music': _music,
      'mode': _mode,
      'kind': _kind,
      'narration_language': _narrationLang,
    };
    if (_isCreate) {
      if (_key.text.trim().isEmpty || _displayName.text.trim().isEmpty || _concept.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('key, display name and concept prompt are required'),
              backgroundColor: HackerTheme.red),
        );
        return;
      }
      fields['key'] = _key.text.trim();
    }
    Navigator.of(context).pop(fields);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: HackerTheme.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: HackerTheme.green),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: HackerTheme.borderDim)),
            ),
            child: Row(children: [
              Text(_isCreate ? '// new theme' : '// edit theme',
                  style: HackerTheme.mono(size: 13, color: HackerTheme.green)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: const Icon(Icons.close, color: HackerTheme.grey, size: 18),
              ),
            ]),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_isCreate) ...[
                  _field('key (slug)', _key, hint: 'e.g. motivational_quotes'),
                  const SizedBox(height: 12),
                ],
                _field('display name', _displayName),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _segmented('mode', _mode, const ['character', 'generative'], (v) => setState(() => _mode = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _segmented('kind', _kind, const ['video', 'image'], (v) => setState(() => _kind = v))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  SizedBox(width: 110, child: _field('weight', _weight, number: true)),
                  const SizedBox(width: 16),
                  _checkbox('active', _active, (v) => setState(() => _active = v)),
                  const SizedBox(width: 16),
                  _checkbox('music', _music, (v) => setState(() => _music = v)),
                ]),
                const SizedBox(height: 12),
                _segmented('narration voice language', _narrationLang, const ['en', 'ms', 'id'],
                    (v) => setState(() => _narrationLang = v)),
                const SizedBox(height: 12),
                _field('concept prompt (Gemini brief — {category} is filled per day)', _concept, lines: 8),
                const SizedBox(height: 12),
                _field('image prompt template ({scene} placeholder)', _imageTpl, lines: 3),
                const SizedBox(height: 12),
                _field('action suffix (appended to motion)', _actionSuffix, lines: 2),
              ]),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: HackerTheme.borderDim)),
            ),
            child: Row(children: [
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('CANCEL', style: HackerTheme.mono(size: 11, color: HackerTheme.grey)),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _submit,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: HackerTheme.green),
                    color: HackerTheme.greenDim,
                  ),
                  child: Text(_isCreate ? 'CREATE' : 'SAVE',
                      style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl,
      {int lines = 1, bool number = false, String? hint}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        maxLines: lines,
        keyboardType: number
            ? TextInputType.number
            : (lines > 1 ? TextInputType.multiline : TextInputType.text),
        style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: HackerTheme.borderDim),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(color: HackerTheme.green),
          ),
        ),
      ),
    ]);
  }

  Widget _segmented(String label, String value, List<String> options, ValueChanged<String> onChange) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
      const SizedBox(height: 4),
      Row(
          children: options.map((o) {
        final sel = o == value;
        return Expanded(
          child: GestureDetector(
            onTap: () => onChange(o),
            child: Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(vertical: 7),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: sel ? HackerTheme.green : HackerTheme.borderDim),
                color: sel ? HackerTheme.greenDim : Colors.transparent,
              ),
              child: Text(o,
                  style: HackerTheme.monoNoGlow(
                      size: 9, color: sel ? HackerTheme.green : HackerTheme.grey)),
            ),
          ),
        );
      }).toList()),
    ]);
  }

  Widget _checkbox(String label, bool value, ValueChanged<bool> onChange) {
    return GestureDetector(
      onTap: () => onChange(!value),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 16, height: 16,
          decoration: BoxDecoration(
            border: Border.all(color: value ? HackerTheme.green : HackerTheme.dimText),
            color: value ? HackerTheme.greenDim : Colors.transparent,
          ),
          child: value ? const Icon(Icons.check, size: 12, color: HackerTheme.green) : null,
        ),
        const SizedBox(width: 6),
        Text(label, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
      ]),
    );
  }
}

// =============================================================================
// AGENTS view — read-only per-runner explainer. One card per fleet runner in
// agent_registry: what it does (role_description), where it runs, and its live
// classification (live/stale/down/on_leave/suppressed/retired). Consumes
// GET /api/studio/agents (registry + heartbeats + server-side classifier),
// polls every 30s. Pause/resume is NOT here — it lives on the HQ tab.
// =============================================================================

class _AgentsView extends StatefulWidget {
  const _AgentsView();
  @override
  State<_AgentsView> createState() => _AgentsViewState();
}

class _AgentsViewState extends State<_AgentsView> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/studio/agents'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        if (mounted) setState(() { _loading = false; _error = 'HTTP ${res.statusCode}'; });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _rows = List<Map<String, dynamic>>.from(body['rows'] ?? const []);
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('// load error', style: HackerTheme.mono(size: 12, color: HackerTheme.red)),
          const SizedBox(height: 6),
          Text(_error!, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => _load(),
            child: Text('RETRY', style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
          ),
        ]),
      );
    }
    if (_rows.isEmpty) {
      return Center(
        child: Text('// no agents in registry',
            style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)),
      );
    }
    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgPanel,
      onRefresh: () => _load(),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _rows.length + 2,
        itemBuilder: (_, i) {
          if (i == 0) {
            return _summary();
          }
          if (i == _rows.length + 1) {
            return _footerHint();
          }
          return _agentCard(_rows[i - 1]);
        },
      ),
    );
  }

  Widget _summary() {
    final counts = <String, int>{};
    for (final r in _rows) {
      final c = (r['classification'] ?? 'unknown').toString();
      counts[c] = (counts[c] ?? 0) + 1;
    }
    Widget chip(String label, int n, Color color) => Container(
          margin: const EdgeInsets.only(right: 6, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(border: Border.all(color: color)),
          child: Text('$label $n', style: HackerTheme.monoNoGlow(size: 9, color: color)),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(children: [
        if ((counts['down'] ?? 0) > 0) chip('DOWN', counts['down']!, HackerTheme.red),
        if ((counts['stale'] ?? 0) > 0) chip('STALE', counts['stale']!, HackerTheme.amber),
        if ((counts['on_leave'] ?? 0) > 0) chip('ON LEAVE', counts['on_leave']!, HackerTheme.cyan),
        if ((counts['suppressed'] ?? 0) > 0) chip('SUPPRESSED', counts['suppressed']!, HackerTheme.grey),
        if ((counts['live'] ?? 0) > 0) chip('LIVE', counts['live']!, HackerTheme.green),
        if ((counts['unknown'] ?? 0) > 0) chip('UNKNOWN', counts['unknown']!, HackerTheme.grey),
        if ((counts['retired'] ?? 0) > 0) chip('RETIRED', counts['retired']!, HackerTheme.dimText),
      ]),
    );
  }

  Widget _footerHint() => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 12),
        child: Text('// read-only — pause/resume lives on the HQ tab',
            textAlign: TextAlign.center,
            style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
      );

  Widget _agentCard(Map<String, dynamic> row) {
    final agent = row['agent_name'].toString();
    final emoji = (row['emoji'] ?? '').toString();
    final displayName = (row['display_name'] ?? agent).toString();
    final role = (row['role_description'] ?? '').toString();
    final host = (row['host'] ?? '?').toString();
    final agentType = (row['agent_type'] ?? '').toString();
    final classification = (row['classification'] ?? 'unknown').toString();
    final ageS = row['heartbeat_age_s'];
    final cls = _classMeta(classification);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: HackerTheme.terminalBox(active: classification == 'live'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: cls.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            if (emoji.isNotEmpty) ...[
              Text(emoji, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(agent,
                  style: HackerTheme.mono(size: 13, color: HackerTheme.green)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: cls.color)),
              child: Text(cls.label,
                  style: HackerTheme.monoNoGlow(size: 8, color: cls.color)),
            ),
          ]),
          if (displayName.isNotEmpty && displayName != agent) ...[
            const SizedBox(height: 4),
            Text(displayName,
                style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
          ],
          if (role.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(role,
                style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
          ],
          const SizedBox(height: 6),
          Text(
            [
              host,
              if (agentType.isNotEmpty) agentType,
              if (ageS is num) 'seen ${_fmtAge(ageS.toInt())} ago' else 'no heartbeat',
            ].join(' · '),
            style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText),
          ),
        ]),
      ),
    );
  }

  _ClassMeta _classMeta(String c) {
    switch (c) {
      case 'live': return _ClassMeta('LIVE', HackerTheme.green);
      case 'down': return _ClassMeta('DOWN', HackerTheme.red);
      case 'stale': return _ClassMeta('STALE', HackerTheme.amber);
      case 'on_leave': return _ClassMeta('ON LEAVE', HackerTheme.cyan);
      case 'suppressed': return _ClassMeta('SUPPRESSED', HackerTheme.grey);
      case 'retired': return _ClassMeta('RETIRED', HackerTheme.dimText);
      default: return _ClassMeta('UNKNOWN', HackerTheme.grey);
    }
  }

  String _fmtAge(int s) {
    if (s < 60) {
      return '${s}s';
    }
    if (s < 3600) {
      return '${s ~/ 60}m';
    }
    if (s < 86400) {
      return '${s ~/ 3600}h';
    }
    return '${s ~/ 86400}d';
  }
}

class _ClassMeta {
  final String label;
  final Color color;
  const _ClassMeta(this.label, this.color);
}
