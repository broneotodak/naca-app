import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../config.dart';
import '../services/realtime_service.dart';

/// NACA HQ Dashboard — unified overview of all systems
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Agent data
  List<Map<String, dynamic>> _agents = [];
  Map<String, int> _queue = {'pending': 0, 'running': 0, 'failed': 0};
  List<Map<String, dynamic>> _locks = [];
  List<Map<String, dynamic>> _recentCmds = [];

  // Cost data
  List<Map<String, dynamic>> _costServices = [];
  double _totalCost = 0;

  // Service health
  Map<String, _ServiceStatus> _services = {};

  bool _loading = true;
  String? _error;
  Timer? _timer;
  DateTime? _lastRefresh;
  StreamSubscription? _heartbeatSub;
  StreamSubscription? _commandSub;

  SupabaseClient get _sb => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadAll();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _loadAll());

    // Realtime: refresh on agent data changes
    _heartbeatSub = RealtimeService.instance.heartbeats.listen((_) => _loadAll());
    _commandSub = RealtimeService.instance.commands.listen((_) => _loadAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heartbeatSub?.cancel();
    _commandSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      // Parallel: agent data + service health + costs
      await Future.wait([_loadAgentData(), _checkServices(), _loadCosts()]);
      if (mounted) setState(() { _loading = false; _error = null; _lastRefresh = DateTime.now(); });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadAgentData() async {
    final agents = await _sb.from('agent_heartbeats').select().order('reported_at', ascending: false);
    final commands = await _sb.from('agent_commands').select().order('created_at', ascending: false).limit(5);
    final locks = await _sb.from('agent_locks').select();
    final pendingRes = await _sb.from('agent_commands').select('id').eq('status', 'pending').count(CountOption.exact);
    final runningRes = await _sb.from('agent_commands').select('id').eq('status', 'running').count(CountOption.exact);
    final failedRes = await _sb.from('agent_commands').select('id').inFilter('status', ['failed', 'dead_letter', 'needs_review']).count(CountOption.exact);

    if (mounted) {
      _agents = List<Map<String, dynamic>>.from(agents);
      _recentCmds = List<Map<String, dynamic>>.from(commands);
      _locks = List<Map<String, dynamic>>.from(locks);
      _queue = {
        'pending': pendingRes.count,
        'running': runningRes.count,
        'failed': failedRes.count,
      };
    }

    // Also check Siti live status via proxy
    try {
      final sitiHealth = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/siti/api/status'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 5));
      if (sitiHealth.statusCode < 400) {
        final sitiData = jsonDecode(sitiHealth.body);
        // Find or add Siti in agents list
        final sitiIdx = _agents.indexWhere((a) => a['agent_name'] == 'siti' || a['agent_name'] == 'nclaw-dashboard');
        final sitiEntry = {
          'agent_name': 'siti',
          'status': sitiData['status'] == 'connected' ? 'ok' : 'degraded',
          'reported_at': DateTime.now().toUtc().toIso8601String(),
          'meta': {
            'wa_status': sitiData['status'],
            'contacts': sitiData['contacts'],
            'instance': sitiData['instance_slug'] ?? 'vps-hetzner',
          },
        };
        if (sitiIdx >= 0) {
          _agents[sitiIdx] = sitiEntry;
        } else {
          _agents.insert(0, sitiEntry);
        }
      }
    } catch (_) {}
  }

  Future<void> _checkServices() async {
    final results = <String, _ServiceStatus>{};

    // VPS Backend — needs auth token + Content-Type for CORS preflight
    try {
      results['VPS Backend'] = await _pingHttp('${AppConfig.apiBaseUrl}/api/health', headers: {
        'Authorization': 'Bearer ${AppConfig.authToken}',
        'Content-Type': 'application/json',
      });
    } catch (_) {
      results['VPS Backend'] = const _ServiceStatus(false, 'timeout');
    }

    // Supabase — use the SDK directly (no raw REST)
    try {
      final sw = Stopwatch()..start();
      await _sb.from('agent_heartbeats').select('agent_name').limit(1);
      sw.stop();
      results['Supabase'] = _ServiceStatus(true, '${sw.elapsedMilliseconds}ms');
    } catch (_) {
      results['Supabase'] = const _ServiceStatus(false, 'error');
    }

    // Siti — proxy through VPS backend on web, direct on mobile
    try {
      final sitiUrl = kIsWeb
          ? '${AppConfig.apiBaseUrl}/api/siti/api/health'
          : 'http://178.156.241.204:3800/api/health';
      final sitiHeaders = kIsWeb
          ? {'Authorization': 'Bearer ${AppConfig.authToken}'}
          : <String, String>{};
      results['Siti (nclaw)'] = await _pingHttp(sitiUrl, headers: sitiHeaders);
    } catch (_) {
      results['Siti (nclaw)'] = const _ServiceStatus(false, 'offline');
    }

    if (mounted) _services = results;
  }

  Future<void> _loadCosts() async {
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/costs'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode < 400 && mounted) {
        final data = jsonDecode(res.body);
        _costServices = List<Map<String, dynamic>>.from(data['services'] ?? []);
        _totalCost = (data['totalEstimate'] as num?)?.toDouble() ?? 0;
      }
    } catch (_) {
      // Non-critical — cost data just won't show
    }
  }

  Future<_ServiceStatus> _pingHttp(String url, {Map<String, String>? headers}) async {
    try {
      final sw = Stopwatch()..start();
      final res = await http.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 5));
      sw.stop();
      return _ServiceStatus(res.statusCode < 400, '${sw.elapsedMilliseconds}ms');
    } catch (e) {
      return _ServiceStatus(false, 'error');
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
                : _error != null
                    ? Center(child: Text('ERROR: $_error', style: HackerTheme.mono(color: HackerTheme.red, size: 11)))
                    : RefreshIndicator(
                        color: HackerTheme.green,
                        backgroundColor: HackerTheme.bgCard,
                        onRefresh: _loadAll,
                        child: _buildBody(),
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
      child: Row(
        children: [
          Text('NACA://', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
          Text('headquarters', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
          const Spacer(),
          if (_lastRefresh != null)
            Text(_timeAgo(_lastRefresh!), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () { setState(() => _loading = true); _loadAll(); },
            child: const Icon(Icons.refresh, size: 16, color: HackerTheme.dimText),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // Service health row
        _section('SYSTEM STATUS'),
        _buildServiceGrid(),
        const SizedBox(height: 16),

        // Cost monitor
        if (_costServices.isNotEmpty) ...[
          _section('COST MONITOR'),
          _buildCostPanel(),
          const SizedBox(height: 16),
        ],

        // Agent fleet
        _section('AGENT FLEET'),
        ..._agents.map(_buildAgentCard),
        if (_agents.isEmpty) _emptyState('No agents reporting'),
        const SizedBox(height: 16),

        // Command queue
        _section('COMMAND QUEUE'),
        _buildQueueBar(),
        const SizedBox(height: 16),

        // Active locks
        if (_locks.isNotEmpty) ...[
          _section('ACTIVE LOCKS'),
          ..._locks.map(_buildLockRow),
          const SizedBox(height: 16),
        ],

        // Recent activity
        _section('RECENT COMMANDS'),
        ..._recentCmds.map(_buildCmdRow),
        if (_recentCmds.isEmpty) _emptyState('No recent commands'),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text('// $text', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
  );

  Widget _emptyState(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: HackerTheme.terminalBox(),
    child: Center(child: Text(text, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText))),
  );

  Widget _buildServiceGrid() {
    final items = _services.entries.toList();
    if (items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: HackerTheme.terminalBox(),
        child: const Center(child: Text('Checking...', style: TextStyle(color: HackerTheme.dimText, fontSize: 11))),
      );
    }
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: items.map((e) {
        final ok = e.value.ok;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: HackerTheme.bgCard,
            border: Border.all(color: ok ? HackerTheme.green : HackerTheme.red, width: 1),
            boxShadow: ok ? [const BoxShadow(color: HackerTheme.greenDim, blurRadius: 6)] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                color: ok ? HackerTheme.green : HackerTheme.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.key, style: HackerTheme.monoNoGlow(size: 10, color: ok ? HackerTheme.green : HackerTheme.red)),
              Text(e.value.detail, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
            ]),
          ]),
        );
      }).toList(),
    );
  }

  Widget _buildAgentCard(Map<String, dynamic> agent) {
    final name = agent['agent_name'] ?? '?';
    final status = agent['status'] ?? 'unknown';
    final meta = agent['meta'] as Map<String, dynamic>? ?? {};
    final reportedAt = agent['reported_at'] as String?;

    final isOk = status == 'ok';
    final isDeg = status == 'degraded';
    final statusColor = isOk ? HackerTheme.green : isDeg ? HackerTheme.amber : HackerTheme.red;
    final ago = reportedAt != null ? _timeAgo(DateTime.parse(reportedAt)) : 'never';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(active: isOk),
      child: Row(
        children: [
          // Status indicator
          Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.5), blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 10),
          // Name + meta
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 12, color: statusColor)),
                Wrap(spacing: 10, children: [
                  if (meta['version'] != null) Text('v${meta['version']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                  if (meta['memory_mb'] != null) Text('${meta['memory_mb']}MB', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                  if (meta['wa_status'] != null) Text('wa:${meta['wa_status']}', style: HackerTheme.monoNoGlow(size: 8, color: meta['wa_status'] == 'connected' ? HackerTheme.green : HackerTheme.amber)),
                  if (meta['model'] != null) Text(meta['model'].toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
                ]),
              ],
            ),
          ),
          Text(ago, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
        ],
      ),
    );
  }

  Widget _buildQueueBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: HackerTheme.terminalBox(),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _queueStat('PENDING', _queue['pending']!, HackerTheme.amber),
          Container(width: 1, height: 30, color: HackerTheme.borderDim),
          _queueStat('RUNNING', _queue['running']!, HackerTheme.cyan),
          Container(width: 1, height: 30, color: HackerTheme.borderDim),
          _queueStat('FAILED', _queue['failed']!, HackerTheme.red),
        ],
      ),
    );
  }

  Widget _queueStat(String label, int count, Color color) {
    return Column(children: [
      Text('$count', style: HackerTheme.mono(size: 22, color: count > 0 ? color : HackerTheme.dimText)),
      Text(label, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
    ]);
  }

  Widget _buildLockRow(Map<String, dynamic> lock) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: const Border(left: BorderSide(color: HackerTheme.amber, width: 2)),
      ),
      child: Row(children: [
        Text('LOCK ', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.amber)),
        Text('${lock['project']}', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
        const Spacer(),
        Text('by ${lock['agent_name']}', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
      ]),
    );
  }

  Widget _buildCmdRow(Map<String, dynamic> cmd) {
    final status = cmd['status'] ?? '?';
    final command = cmd['command'] ?? '?';
    final from = cmd['from_agent'] ?? '?';
    final to = cmd['to_agent'] ?? '?';
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
      child: Row(children: [
        SizedBox(
          width: 50,
          child: Text(status.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 8, color: statusColor)),
        ),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(command.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
            Text('$from → $to', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
          ],
        )),
        if (createdAt != null) Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
      ]),
    );
  }

  Widget _buildCostPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: HackerTheme.terminalBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Total
          Row(
            children: [
              Text('MONTHLY TOTAL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
              const Spacer(),
              Text(
                '\$${_totalCost.toStringAsFixed(0)}/mo',
                style: HackerTheme.mono(size: 16, color: _totalCost > 150 ? HackerTheme.amber : HackerTheme.green),
              ),
            ],
          ),
          const Divider(color: HackerTheme.borderDim, height: 16),
          // Per-service breakdown
          ..._costServices.map((s) {
            final name = s['name'] ?? '?';
            final cost = (s['cost'] as num?)?.toDouble() ?? 0;
            final currency = (s['currency'] ?? 'usd').toString().toUpperCase();
            final usage = s['usage'] ?? '';
            final usagePct = (s['usagePct'] as num?)?.toInt();
            final status = s['status'] ?? '';
            final note = s['note'];

            final isEstimate = status == 'estimated';
            final costColor = cost == 0 ? HackerTheme.dimText : cost > 50 ? HackerTheme.amber : HackerTheme.green;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(name.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
                      ),
                      Text(
                        cost == 0 ? 'FREE' : '${isEstimate ? '~' : ''}\$$cost $currency',
                        style: HackerTheme.monoNoGlow(size: 10, color: costColor),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      if (usage.toString().isNotEmpty)
                        Expanded(child: Text(usage.toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey))),
                      if (usagePct != null) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 60,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: usagePct / 100,
                              backgroundColor: HackerTheme.bgPanel,
                              color: usagePct > 80 ? HackerTheme.red : usagePct > 50 ? HackerTheme.amber : HackerTheme.green,
                              minHeight: 4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text('$usagePct%', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                      ],
                    ],
                  ),
                  if (note != null)
                    Text(note.toString(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _ServiceStatus {
  final bool ok;
  final String detail;
  const _ServiceStatus(this.ok, this.detail);
}
