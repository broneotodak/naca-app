import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../config.dart';
import '../services/realtime_service.dart';
import '../services/sound_service.dart';

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

  // Intents
  List<Map<String, dynamic>> _intents = [];

  // Service health
  Map<String, _ServiceStatus> _services = {};

  // Expanded command IDs (for detail view)
  final Set<String> _expandedCmds = {};

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
      await Future.wait([_loadAgentData(), _checkServices(), _loadCosts(), _loadIntents()]);
      if (mounted) setState(() { _loading = false; _error = null; _lastRefresh = DateTime.now(); });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadAgentData() async {
    final agents = await _sb.from('agent_heartbeats').select().order('reported_at', ascending: false);
    final commands = await _sb.from('agent_commands').select().order('created_at', ascending: false).limit(20);
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

    try {
      results['VPS Backend'] = await _pingHttp('${AppConfig.apiBaseUrl}/api/health', headers: {
        'Authorization': 'Bearer ${AppConfig.authToken}',
        'Content-Type': 'application/json',
      });
    } catch (_) {
      results['VPS Backend'] = const _ServiceStatus(false, 'timeout');
    }

    try {
      final sw = Stopwatch()..start();
      await _sb.from('agent_heartbeats').select('agent_name').limit(1);
      sw.stop();
      results['Supabase'] = _ServiceStatus(true, '${sw.elapsedMilliseconds}ms');
    } catch (_) {
      results['Supabase'] = const _ServiceStatus(false, 'error');
    }

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
    } catch (_) {}
  }

  Future<void> _loadIntents() async {
    try {
      final data = await _sb.from('agent_intents')
          .select()
          .order('created_at', ascending: false)
          .limit(10);
      if (mounted) _intents = List<Map<String, dynamic>>.from(data);
    } catch (_) {}
  }

  Future<void> _submitIntent(String text, {String source = 'naca-dashboard'}) async {
    try {
      await _sb.from('agent_intents').insert({
        'source': source,
        'raw_text': text,
        'reporter': 'Neo (NACA)',
        'status': 'pending',
      });
      SoundService.instance.playAcknowledged();
      _showSnack('Intent submitted → planner-agent');
      _loadAll();
    } catch (e) {
      SoundService.instance.playError();
      _showSnack('Failed: $e', error: true);
    }
  }

  void _showIntentDialog() {
    final textCtrl = TextEditingController();
    String source = 'naca-dashboard';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: HackerTheme.bgPanel,
          shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.green)),
          title: Row(
            children: [
              const Icon(Icons.bolt, color: HackerTheme.green, size: 20),
              const SizedBox(width: 8),
              Text('NEW INTENT', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Describe what you want done. Planner-agent will decompose it into commands for the right agents.',
                  style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                const SizedBox(height: 12),
                TextField(
                  controller: textCtrl,
                  style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
                  decoration: InputDecoration(
                    hintText: 'e.g. "Fix the login bug on academy"\n"Deploy hotfix to forex dashboard"\n"Send status report to Neo on WhatsApp"',
                    hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                    enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                    focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                  ),
                  maxLines: 5,
                  minLines: 3,
                  autofocus: true,
                ),
                const SizedBox(height: 12),
                // Source selector
                Row(
                  children: [
                    Text('SOURCE: ', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                    ...<String>['naca-dashboard', 'manual', 'whatsapp'].map((s) {
                      final active = source == s;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => setDialogState(() => source = s),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: active ? HackerTheme.green.withValues(alpha: 0.15) : Colors.transparent,
                              border: Border.all(color: active ? HackerTheme.green : HackerTheme.borderDim),
                            ),
                            child: Text(s, style: HackerTheme.monoNoGlow(size: 8, color: active ? HackerTheme.green : HackerTheme.dimText)),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
            ),
            TextButton(
              onPressed: () {
                if (textCtrl.text.trim().isEmpty) return;
                Navigator.of(ctx).pop();
                _submitIntent(textCtrl.text.trim(), source: source);
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bolt, size: 14, color: HackerTheme.green),
                  const SizedBox(width: 4),
                  Text('SUBMIT', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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

  // ── ACTIONS ──

  Future<void> _cancelCommand(String id) async {
    try {
      await _sb.from('agent_commands').update({
        'status': 'cancelled',
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        'result': {'cancelled_by': 'naca-app', 'reason': 'manual cancel from dashboard'},
      }).eq('id', id);
      SoundService.instance.playAcknowledged();
      _showSnack('Command cancelled');
      _loadAll();
    } catch (e) {
      _showSnack('Failed: $e', error: true);
    }
  }

  Future<void> _retryCommand(Map<String, dynamic> cmd) async {
    try {
      await _sb.from('agent_commands').insert({
        'from_agent': cmd['from_agent'] ?? 'naca-app',
        'to_agent': cmd['to_agent'],
        'command': cmd['command'],
        'payload': cmd['payload'] ?? {},
        'priority': cmd['priority'] ?? 5,
      });
      SoundService.instance.playAcknowledged();
      _showSnack('Command re-queued');
      _loadAll();
    } catch (e) {
      _showSnack('Failed: $e', error: true);
    }
  }

  Future<void> _pingAgent(String agentName) async {
    try {
      await _sb.from('agent_commands').insert({
        'from_agent': 'naca-app',
        'to_agent': agentName,
        'command': 'ping',
        'payload': {'from': 'naca-dashboard', 'ts': DateTime.now().toUtc().toIso8601String()},
        'priority': 1,
      });
      SoundService.instance.playSent();
      _showSnack('Ping sent to $agentName');
    } catch (e) {
      _showSnack('Failed: $e', error: true);
    }
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: HackerTheme.monoNoGlow(size: 10, color: error ? HackerTheme.red : HackerTheme.green)),
      backgroundColor: HackerTheme.bgCard,
      duration: const Duration(seconds: 2),
    ));
  }

  // ── BUILD ──

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
        // Intent submission button
        _buildIntentButton(),
        const SizedBox(height: 16),

        // System status
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

        // Command queue with filter
        _section('COMMAND QUEUE'),
        _buildQueueBar(),
        const SizedBox(height: 8),

        // Active locks
        if (_locks.isNotEmpty) ...[
          _section('ACTIVE LOCKS'),
          ..._locks.map(_buildLockRow),
          const SizedBox(height: 16),
        ],

        // Intent feed
        if (_intents.isNotEmpty) ...[
          _section('RECENT INTENTS'),
          ..._intents.map(_buildIntentCard),
          const SizedBox(height: 16),
        ],

        // Interactive command list
        _buildCommandList(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text('// $text', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
  );

  // ── INTENT BUTTON ──

  Widget _buildIntentButton() {
    return GestureDetector(
      onTap: _showIntentDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border.all(color: HackerTheme.green, width: 1),
          boxShadow: [const BoxShadow(color: HackerTheme.greenDim, blurRadius: 12)],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                border: Border.all(color: HackerTheme.green.withValues(alpha: 0.5)),
              ),
              child: const Icon(Icons.bolt, size: 18, color: HackerTheme.green),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DISPATCH INTENT', style: HackerTheme.mono(size: 12, color: HackerTheme.green)),
                  Text('Tell the agents what to do — planner decomposes it', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward, size: 16, color: HackerTheme.green),
          ],
        ),
      ),
    );
  }

  // ── INTENT CARDS ──

  Widget _buildIntentCard(Map<String, dynamic> intent) {
    final id = intent['id']?.toString() ?? '';
    final rawText = intent['raw_text'] ?? '';
    final status = intent['status'] ?? 'pending';
    final source = intent['source'] ?? '';
    final reporter = intent['reporter'] ?? '';
    final plan = intent['plan'];
    final error = intent['error'];
    final createdAt = intent['created_at'] as String?;
    final dispatchedIds = intent['dispatched_command_ids'] as List?;
    final isExpanded = _expandedCmds.contains('intent:$id');

    final statusColor = switch (status.toString()) {
      'pending' => HackerTheme.amber,
      'decomposing' => HackerTheme.cyan,
      'decomposed' => HackerTheme.green,
      'failed' => HackerTheme.red,
      'cancelled' => HackerTheme.grey,
      _ => HackerTheme.dimText,
    };

    final statusIcon = switch (status.toString()) {
      'pending' => Icons.hourglass_empty,
      'decomposing' => Icons.psychology,
      'decomposed' => Icons.check_circle_outline,
      'failed' => Icons.error_outline,
      'cancelled' => Icons.cancel_outlined,
      _ => Icons.help_outline,
    };

    return GestureDetector(
      onTap: () => setState(() {
        final key = 'intent:$id';
        if (isExpanded) { _expandedCmds.remove(key); } else { _expandedCmds.add(key); }
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: statusColor, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(children: [
              Icon(statusIcon, size: 14, color: statusColor),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: statusColor.withValues(alpha: 0.4))),
                child: Text(status.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: statusColor)),
              ),
              const SizedBox(width: 6),
              if (source.toString().isNotEmpty)
                Text(source.toString(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
              const Spacer(),
              if (createdAt != null) Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
              const SizedBox(width: 4),
              Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 14, color: HackerTheme.dimText),
            ]),
            const SizedBox(height: 4),
            // Intent text
            Text(
              rawText.toString(),
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              maxLines: isExpanded ? 10 : 2,
              overflow: TextOverflow.ellipsis,
            ),
            // Expanded details
            if (isExpanded) ...[
              const Divider(color: HackerTheme.borderDim, height: 12),
              if (reporter.toString().isNotEmpty)
                Text('Reporter: $reporter', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              if (plan is Map && plan.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('PLAN:', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
                if (plan['reasoning'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(plan['reasoning'].toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey), maxLines: 5, overflow: TextOverflow.ellipsis),
                  ),
                if (plan['commands'] is List)
                  ...((plan['commands'] as List).map((cmd) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(children: [
                      Text('→ ', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                      Text('${cmd['to_agent'] ?? '?'}: ', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                      Expanded(child: Text(cmd['command']?.toString() ?? '?', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.white))),
                    ]),
                  ))),
              ],
              if (error != null) ...[
                const SizedBox(height: 4),
                Text('ERROR: $error', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red)),
              ],
              if (dispatchedIds != null && dispatchedIds.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('Dispatched ${dispatchedIds.length} command(s)', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.green)),
              ],
              // Cancel button for pending intents
              if (status == 'pending') ...[
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  GestureDetector(
                    onTap: () async {
                      await _sb.from('agent_intents').update({'status': 'cancelled'}).eq('id', id);
                      SoundService.instance.playAcknowledged();
                      _showSnack('Intent cancelled');
                      _loadAll();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(border: Border.all(color: HackerTheme.red)),
                      child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red)),
                    ),
                  ),
                ]),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: HackerTheme.terminalBox(),
    child: Center(child: Text(text, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText))),
  );

  // ── SERVICE GRID ──

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
              decoration: BoxDecoration(color: ok ? HackerTheme.green : HackerTheme.red, shape: BoxShape.circle),
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

  // ── AGENT FLEET ──

  Widget _buildAgentCard(Map<String, dynamic> agent) {
    final name = agent['agent_name'] ?? '?';
    final status = agent['status'] ?? 'unknown';
    final meta = agent['meta'] as Map<String, dynamic>? ?? {};
    final reportedAt = agent['reported_at'] as String?;

    final isOk = status == 'ok';
    final isDeg = status == 'degraded';
    final isOffline = status == 'offline';
    final statusColor = isOk ? HackerTheme.green : isDeg ? HackerTheme.amber : HackerTheme.red;
    final ago = reportedAt != null ? _timeAgo(DateTime.parse(reportedAt)) : 'never';

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(active: isOk),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Status indicator with pulse effect
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.5), blurRadius: 6)],
                ),
              ),
              const SizedBox(width: 10),
              // Name
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(name.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 12, color: statusColor)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(border: Border.all(color: statusColor.withValues(alpha: 0.4))),
                          child: Text(status.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: statusColor)),
                        ),
                      ],
                    ),
                    // Meta row
                    Wrap(spacing: 10, children: [
                      if (meta['version'] != null) Text('v${meta['version']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                      if (meta['memory_mb'] != null) Text('${meta['memory_mb']}MB', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                      if (meta['port'] != null) Text(':${meta['port']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                      if (meta['sessions'] != null) Text('${meta['sessions']} sess', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                      if (meta['wa_status'] != null) Text('wa:${meta['wa_status']}', style: HackerTheme.monoNoGlow(size: 8, color: meta['wa_status'] == 'connected' ? HackerTheme.green : HackerTheme.amber)),
                      if (meta['model'] != null) Text(meta['model'].toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
                      if (meta['uptime_s'] != null) Text('up ${_formatUptime(meta['uptime_s'])}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                    ]),
                  ],
                ),
              ),
              // Actions
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(ago, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _agentAction(Icons.wifi_tethering, 'PING', HackerTheme.cyan, () => _pingAgent(name.toString())),
                      const SizedBox(width: 4),
                      if (!isOffline) _agentAction(Icons.restart_alt, 'CMD', HackerTheme.amber, () => _showCommandDialog(name.toString())),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _agentAction(IconData icon, String tooltip, Color color, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(border: Border.all(color: color.withValues(alpha: 0.3))),
          child: Icon(icon, size: 12, color: color),
        ),
      ),
    );
  }

  void _showCommandDialog(String agentName) {
    final cmdCtrl = TextEditingController();
    final payloadCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.cyan)),
        title: Text('COMMAND → ${agentName.toUpperCase()}', style: HackerTheme.mono(size: 13, color: HackerTheme.cyan)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cmdCtrl,
              style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
              decoration: InputDecoration(
                labelText: 'Command',
                labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                hintText: 'e.g. status_report, restart, investigate_bug',
                hintStyle: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText),
                enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.cyan)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: payloadCtrl,
              style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
              decoration: InputDecoration(
                labelText: 'Payload (JSON, optional)',
                labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.cyan)),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
          ),
          TextButton(
            onPressed: () async {
              if (cmdCtrl.text.trim().isEmpty) return;
              Map<String, dynamic> payload = {};
              if (payloadCtrl.text.trim().isNotEmpty) {
                try { payload = Map<String, dynamic>.from(jsonDecode(payloadCtrl.text.trim()) as Map); }
                catch (_) { _showSnack('Invalid JSON', error: true); return; }
              }
              Navigator.of(ctx).pop();
              try {
                await _sb.from('agent_commands').insert({
                  'from_agent': 'naca-app',
                  'to_agent': agentName,
                  'command': cmdCtrl.text.trim(),
                  'payload': payload,
                  'priority': 5,
                });
                SoundService.instance.playAcknowledged();
                _showSnack('Sent "${cmdCtrl.text.trim()}" → $agentName');
                _loadAll();
              } catch (e) {
                _showSnack('Failed: $e', error: true);
              }
            },
            child: Text('DISPATCH', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
          ),
        ],
      ),
    );
  }

  // ── COMMAND QUEUE ──

  Widget _buildQueueBar() {
    return GestureDetector(
      onTap: _showFullCommandQueue,
      child: Container(
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
            Container(width: 1, height: 30, color: HackerTheme.borderDim),
            Column(children: [
              const Icon(Icons.open_in_full, size: 16, color: HackerTheme.dimText),
              Text('VIEW ALL', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _queueStat(String label, int count, Color color) {
    return Column(children: [
      Text('$count', style: HackerTheme.mono(size: 22, color: count > 0 ? color : HackerTheme.dimText)),
      Text(label, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
    ]);
  }

  void _showFullCommandQueue() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: HackerTheme.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
        side: BorderSide(color: HackerTheme.borderDim),
      ),
      builder: (ctx) => _CommandQueueSheet(sb: _sb, onAction: _loadAll),
    );
  }

  // ── INTERACTIVE COMMAND LIST (recent, inline) ──

  Widget _buildCommandList() {
    if (_recentCmds.isEmpty) return _emptyState('No commands');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('// RECENT COMMANDS', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
            const Spacer(),
            GestureDetector(
              onTap: _showFullCommandQueue,
              child: Text('VIEW ALL →', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ..._recentCmds.take(8).map((cmd) => _buildInteractiveCmdRow(cmd)),
      ],
    );
  }

  Widget _buildInteractiveCmdRow(Map<String, dynamic> cmd) {
    final id = cmd['id']?.toString() ?? '';
    final status = cmd['status'] ?? '?';
    final command = cmd['command'] ?? '?';
    final from = cmd['from_agent'] ?? '?';
    final to = cmd['to_agent'] ?? '?';
    final createdAt = cmd['created_at'] as String?;
    final payload = cmd['payload'];
    final result = cmd['result'];
    final isExpanded = _expandedCmds.contains(id);

    final statusColor = _cmdStatusColor(status.toString());
    final canCancel = status == 'pending' || status == 'running' || status == 'claimed';
    final canRetry = status == 'failed' || status == 'dead_letter' || status == 'cancelled';

    return GestureDetector(
      onTap: () => setState(() {
        if (isExpanded) { _expandedCmds.remove(id); } else { _expandedCmds.add(id); }
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: statusColor, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: statusColor.withValues(alpha: 0.4))),
                child: Text(status.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: statusColor)),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(command.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white))),
              if (createdAt != null) Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
              const SizedBox(width: 4),
              Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 14, color: HackerTheme.dimText),
            ]),
            // Route
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('$from → $to', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            ),
            // Expanded details
            if (isExpanded) ...[
              const Divider(color: HackerTheme.borderDim, height: 12),
              if (payload is Map && payload.isNotEmpty) ...[
                Text('PAYLOAD:', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                Container(
                  margin: const EdgeInsets.only(top: 2, bottom: 6),
                  padding: const EdgeInsets.all(6),
                  color: HackerTheme.bgPanel,
                  child: Text(
                    const JsonEncoder.withIndent('  ').convert(payload),
                    style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey),
                    maxLines: 10,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (result is Map && result.isNotEmpty) ...[
                Text('RESULT:', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                Container(
                  margin: const EdgeInsets.only(top: 2, bottom: 6),
                  padding: const EdgeInsets.all(6),
                  color: HackerTheme.bgPanel,
                  child: Text(
                    const JsonEncoder.withIndent('  ').convert(result),
                    style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey),
                    maxLines: 15,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (cmd['claimed_at'] != null)
                Text('Claimed: ${cmd['claimed_at']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              if (cmd['completed_at'] != null)
                Text('Completed: ${cmd['completed_at']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              if (cmd['retry_count'] != null && (cmd['retry_count'] as num) > 0)
                Text('Retries: ${cmd['retry_count']}/${cmd['max_retries'] ?? 3}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.amber)),
              const SizedBox(height: 6),
              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (canCancel) _cmdActionBtn('CANCEL', HackerTheme.red, () => _cancelCommand(id)),
                  if (canRetry) ...[
                    const SizedBox(width: 8),
                    _cmdActionBtn('RETRY', HackerTheme.amber, () => _retryCommand(cmd)),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _cmdActionBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: color)),
        child: Text(label, style: HackerTheme.monoNoGlow(size: 9, color: color)),
      ),
    );
  }

  Color _cmdStatusColor(String status) {
    return switch (status) {
      'done' => HackerTheme.green,
      'running' || 'claimed' => HackerTheme.cyan,
      'pending' => HackerTheme.amber,
      'needs_review' => HackerTheme.amber,
      'cancelled' => HackerTheme.grey,
      _ => HackerTheme.red,
    };
  }

  // ── LOCKS ──

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

  // ── COST PANEL ──

  Widget _buildCostPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: HackerTheme.terminalBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          ..._costServices.map((s) {
            final name = s['name'] ?? '?';
            final cost = (s['cost'] as num?)?.toDouble() ?? 0;
            final currency = (s['currency'] ?? 'usd').toString().toUpperCase();
            final usage = s['usage'] ?? '';
            final usagePct = (s['usagePct'] as num?)?.toInt();
            final status = s['status'] ?? '';
            final note = s['note'];
            final tier = s['tier'];

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
                        child: Row(children: [
                          Text(name.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
                          if (tier != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(border: Border.all(color: HackerTheme.cyan.withValues(alpha: 0.3))),
                              child: Text(tier.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.cyan)),
                            ),
                          ],
                        ]),
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

  // ── HELPERS ──

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  String _formatUptime(dynamic seconds) {
    if (seconds is! num) return '?';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h${m}m';
    return '${m}m';
  }
}

// ══════════════════════════════════════════════════
// FULL COMMAND QUEUE — Bottom Sheet with filters
// ══════════════════════════════════════════════════

class _CommandQueueSheet extends StatefulWidget {
  final SupabaseClient sb;
  final VoidCallback onAction;
  const _CommandQueueSheet({required this.sb, required this.onAction});

  @override
  State<_CommandQueueSheet> createState() => _CommandQueueSheetState();
}

class _CommandQueueSheetState extends State<_CommandQueueSheet> {
  String _filter = 'all';
  List<Map<String, dynamic>> _commands = [];
  bool _loading = true;
  final Set<String> _expanded = {};

  static const _filters = ['all', 'pending', 'running', 'failed', 'done', 'cancelled'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      var q = widget.sb.from('agent_commands').select().order('created_at', ascending: false).limit(50);
      if (_filter == 'failed') {
        q = widget.sb.from('agent_commands').select()
            .inFilter('status', ['failed', 'dead_letter', 'needs_review'])
            .order('created_at', ascending: false).limit(50);
      } else if (_filter != 'all') {
        q = widget.sb.from('agent_commands').select()
            .eq('status', _filter)
            .order('created_at', ascending: false).limit(50);
      }
      final data = await q;
      if (mounted) setState(() { _commands = List<Map<String, dynamic>>.from(data); _loading = false; });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cancel(String id) async {
    try {
      await widget.sb.from('agent_commands').update({
        'status': 'cancelled',
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        'result': {'cancelled_by': 'naca-app'},
      }).eq('id', id);
      SoundService.instance.playAcknowledged();
      widget.onAction();
      _load();
    } catch (_) {}
  }

  Future<void> _retry(Map<String, dynamic> cmd) async {
    try {
      await widget.sb.from('agent_commands').insert({
        'from_agent': cmd['from_agent'] ?? 'naca-app',
        'to_agent': cmd['to_agent'],
        'command': cmd['command'],
        'payload': cmd['payload'] ?? {},
        'priority': cmd['priority'] ?? 5,
      });
      SoundService.instance.playAcknowledged();
      widget.onAction();
      _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: HackerTheme.bgPanel,
              border: Border(bottom: BorderSide(color: HackerTheme.borderDim)),
            ),
            child: Row(
              children: [
                Text('COMMAND QUEUE', style: HackerTheme.mono(size: 13, color: HackerTheme.green)),
                const Spacer(),
                Text('${_commands.length}', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.grey)),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(),
                  child: const Icon(Icons.close, size: 18, color: HackerTheme.dimText),
                ),
              ],
            ),
          ),
          // Filter chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: HackerTheme.bgCard,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _filters.map((f) {
                  final active = _filter == f;
                  final c = switch (f) {
                    'pending' => HackerTheme.amber,
                    'running' => HackerTheme.cyan,
                    'failed' => HackerTheme.red,
                    'done' => HackerTheme.green,
                    'cancelled' => HackerTheme.grey,
                    _ => HackerTheme.white,
                  };
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onTap: () { setState(() => _filter = f); _load(); },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: active ? c.withValues(alpha: 0.15) : Colors.transparent,
                          border: Border.all(color: active ? c : HackerTheme.borderDim),
                        ),
                        child: Text(f.toUpperCase(), style: HackerTheme.monoNoGlow(size: 9, color: active ? c : HackerTheme.dimText)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          // Command list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: HackerTheme.green))
                : _commands.isEmpty
                    ? Center(child: Text('No commands', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)))
                    : ListView.builder(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.all(12),
                        itemCount: _commands.length,
                        itemBuilder: (ctx, i) => _buildRow(_commands[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> cmd) {
    final id = cmd['id']?.toString() ?? '';
    final status = cmd['status'] ?? '?';
    final command = cmd['command'] ?? '?';
    final from = cmd['from_agent'] ?? '?';
    final to = cmd['to_agent'] ?? '?';
    final createdAt = cmd['created_at'] as String?;
    final payload = cmd['payload'];
    final result = cmd['result'];
    final isOpen = _expanded.contains(id);

    final sc = switch (status.toString()) {
      'done' => HackerTheme.green,
      'running' || 'claimed' => HackerTheme.cyan,
      'pending' => HackerTheme.amber,
      'needs_review' => HackerTheme.amber,
      'cancelled' => HackerTheme.grey,
      _ => HackerTheme.red,
    };

    final canCancel = status == 'pending' || status == 'running' || status == 'claimed';
    final canRetry = status == 'failed' || status == 'dead_letter' || status == 'cancelled';

    return GestureDetector(
      onTap: () => setState(() { if (isOpen) _expanded.remove(id); else _expanded.add(id); }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: sc, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: sc.withValues(alpha: 0.4))),
                child: Text(status.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: sc)),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(command.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white))),
              if (createdAt != null) Text(_fmtTime(createdAt), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
              Icon(isOpen ? Icons.expand_less : Icons.expand_more, size: 14, color: HackerTheme.dimText),
            ]),
            Text('$from → $to', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            if (isOpen) ...[
              const Divider(color: HackerTheme.borderDim, height: 10),
              if (payload is Map && payload.isNotEmpty)
                _jsonBlock('PAYLOAD', payload),
              if (result is Map && result.isNotEmpty)
                _jsonBlock('RESULT', result),
              if (cmd['retry_count'] != null && (cmd['retry_count'] as num) > 0)
                Text('Retries: ${cmd['retry_count']}/${cmd['max_retries'] ?? 3}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.amber)),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                if (canCancel) _actionBtn('CANCEL', HackerTheme.red, () => _cancel(id)),
                if (canRetry) ...[
                  const SizedBox(width: 8),
                  _actionBtn('RETRY', HackerTheme.amber, () => _retry(cmd)),
                ],
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _jsonBlock(String label, dynamic data) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$label:', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
      Container(
        margin: const EdgeInsets.only(top: 2, bottom: 6),
        padding: const EdgeInsets.all(6),
        color: HackerTheme.bgPanel,
        child: Text(
          const JsonEncoder.withIndent('  ').convert(data),
          style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey),
          maxLines: 12,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }

  Widget _actionBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: color)),
        child: Text(label, style: HackerTheme.monoNoGlow(size: 9, color: color)),
      ),
    );
  }

  String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso);
      final diff = DateTime.now().toUtc().difference(dt.toUtc());
      if (diff.inSeconds < 60) return '${diff.inSeconds}s';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m';
      if (diff.inHours < 24) return '${diff.inHours}h';
      return '${diff.inDays}d';
    } catch (_) {
      return '';
    }
  }
}

class _ServiceStatus {
  final bool ok;
  final String detail;
  const _ServiceStatus(this.ok, this.detail);
}
