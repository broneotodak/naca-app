import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme.dart';
import '../config.dart';
import '../services/sound_service.dart';

/// Siti Dashboard — WhatsApp bot status, messages, contacts, persons, config
class SitiScreen extends StatefulWidget {
  const SitiScreen({super.key});

  @override
  State<SitiScreen> createState() => _SitiScreenState();
}

class _SitiScreenState extends State<SitiScreen> with SingleTickerProviderStateMixin {
  String get _sitiBase => kIsWeb
      ? '${AppConfig.apiBaseUrl}/api/siti'
      : 'http://178.156.241.204:3800';

  Map<String, dynamic>? _health;
  List<Map<String, dynamic>> _recentMessages = [];
  List<Map<String, dynamic>> _contacts = [];
  Map<String, dynamic> _settings = {};
  // Live Siti tools — fetched from /api/tools (dynamic since siti#19, derived
  // from GEMINI_TOOLS at runtime). Replaces the hardcoded "17 TOOLS" list
  // that drifted as new tools landed.
  List<Map<String, dynamic>> _tools = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  late TabController _tabCtrl;

  // Pagination for messages
  int _messageOffset = 0;
  bool _loadingMoreMessages = false;
  bool _hasMoreMessages = true;

  bool get _isSitiOnline => _health != null && _health!.isNotEmpty && (_health!['status'] == 'connected' || _health!['hostname'] != null);

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _loadAll();
    _applyPollInterval();
  }

  // Poll faster while waiting for QR scan (QR codes expire in ~60s).
  void _applyPollInterval() {
    final wa = _health?['status'];
    final fast = wa == 'waiting_scan' || wa == 'starting';
    final interval = Duration(seconds: fast ? 3 : 20);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _loadAll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      final health = await _fetchJson('/api/health');
      final status = await _fetchJson('/api/status');
      // people list moved to MEM → PEOPLE tab (direct neo-brain); no longer fetched here
      final contactsData = await _fetchJson('/api/contacts');
      final settingsData = await _fetchJson('/api/settings');
      final toolsData = await _fetchJson('/api/tools');

      if (mounted) {
        final merged = <String, dynamic>{
          ...?health,
          ...?status,
        };
        setState(() {
          _health = merged.isNotEmpty ? merged : null;
          _recentMessages = _extractMessages(status);
          _messageOffset = _recentMessages.length;
          _hasMoreMessages = _recentMessages.length >= 50;
          _contacts = _safeList(contactsData, 'contacts');
          _tools = _safeList(toolsData, 'tools');
          if (settingsData != null && settingsData['settings'] is Map) {
            _settings = Map<String, dynamic>.from(settingsData['settings'] as Map);
          }
          _loading = false;
          _error = (health == null && status == null) ? 'Cannot reach Siti' : null;
        });
        _applyPollInterval();
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  List<Map<String, dynamic>> _safeList(Map<String, dynamic>? data, String key) {
    if (data == null || data[key] == null) return [];
    return List<Map<String, dynamic>>.from(data[key] as List);
  }

  List<Map<String, dynamic>> _extractMessages(Map<String, dynamic>? status) {
    if (status == null || status['messages'] == null) return [];
    return List<Map<String, dynamic>>.from(status['messages'] as List);
  }

  Future<Map<String, dynamic>?> _fetchJson(String path) async {
    try {
      final headers = kIsWeb ? {'Authorization': 'Bearer ${AppConfig.authToken}'} : <String, String>{};
      final res = await http.get(Uri.parse('$_sitiBase$path'), headers: headers).timeout(const Duration(seconds: 20));
      if (res.statusCode < 400) return jsonDecode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _postJson(String path, Map<String, dynamic> body, {String method = 'POST'}) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (kIsWeb) 'Authorization': 'Bearer ${AppConfig.authToken}',
      };
      final uri = Uri.parse('$_sitiBase$path');
      final encodedBody = jsonEncode(body);
      http.Response res;
      switch (method) {
        case 'PATCH':
          res = await http.patch(uri, headers: headers, body: encodedBody).timeout(const Duration(seconds: 10));
          break;
        case 'DELETE':
          res = await http.delete(uri, headers: headers, body: encodedBody).timeout(const Duration(seconds: 10));
          break;
        default:
          res = await http.post(uri, headers: headers, body: encodedBody).timeout(const Duration(seconds: 10));
      }
      if (res.statusCode < 400) {
        try { return jsonDecode(res.body); } catch (_) { return {}; }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _deleteJson(String path) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (kIsWeb) 'Authorization': 'Bearer ${AppConfig.authToken}',
      };
      final res = await http.delete(Uri.parse('$_sitiBase$path'), headers: headers).timeout(const Duration(seconds: 10));
      return res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  void _showSnack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: HackerTheme.monoNoGlow(size: 10, color: error ? HackerTheme.red : HackerTheme.green)),
      backgroundColor: HackerTheme.bgCard,
    ));
  }

  // ── BUILD ──

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          if (!_loading && _error == null && _isSitiOnline) _buildHealthBar(),
          TabBar(
            controller: _tabCtrl,
            indicatorColor: HackerTheme.green,
            labelColor: HackerTheme.green,
            unselectedLabelColor: HackerTheme.dimText,
            labelStyle: HackerTheme.monoNoGlow(size: 10),
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: const [
              Tab(text: 'STATUS'),
              Tab(text: 'MESSAGES'),
              Tab(text: 'CONTACTS'),
              Tab(text: 'CONFIG'),
            ],
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: HackerTheme.green))
                : _error != null
                    ? _buildError()
                    : Stack(
                        children: [
                          TabBarView(
                            controller: _tabCtrl,
                            children: [
                              _buildStatus(),
                              _buildMessages(),
                              _buildContacts(),
                              _buildConfig(),
                            ],
                          ),
                          // FAB only on Messages tab
                          ListenableBuilder(
                            listenable: _tabCtrl,
                            builder: (context, child) {
                              if (_tabCtrl.index != 1) return const SizedBox.shrink();
                              return Positioned(
                                right: 16,
                                bottom: 16,
                                child: FloatingActionButton(
                                  backgroundColor: HackerTheme.green,
                                  onPressed: _showComposeDialog,
                                  child: const Icon(Icons.send, color: HackerTheme.bgPanel),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  // ── HEADER + HEALTH BAR ──

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
          Text('siti', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: _isSitiOnline ? HackerTheme.green : HackerTheme.red),
            ),
            child: Text(
              _isSitiOnline ? 'ONLINE' : 'OFFLINE',
              style: HackerTheme.monoNoGlow(size: 9, color: _isSitiOnline ? HackerTheme.green : HackerTheme.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHealthBar() {
    final wa = _health?['status'] ?? 'unknown';
    final connectedAs = _health?['connectedAs'] ?? '';
    final contacts = _health?['contacts'] ?? 0;
    final uptime = _health?['process_uptime_sec'];
    final waOk = wa == 'connected';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: HackerTheme.bgCard,
      child: Row(
        children: [
          _healthChip('WA', waOk ? 'connected' : wa.toString(), waOk ? HackerTheme.green : HackerTheme.red),
          const SizedBox(width: 12),
          if (connectedAs.toString().isNotEmpty) _healthChip('NUM', connectedAs.toString(), HackerTheme.cyan),
          const SizedBox(width: 12),
          _healthChip('PPL', '$contacts', HackerTheme.amber),
          const SizedBox(width: 12),
          if (uptime != null) _healthChip('UP', _formatUptime(uptime), HackerTheme.grey),
        ],
      ),
    );
  }

  Widget _healthChip(String label, String value, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label:', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
      const SizedBox(width: 4),
      Text(value, style: HackerTheme.monoNoGlow(size: 9, color: color)),
    ]);
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, size: 48, color: HackerTheme.red),
            const SizedBox(height: 16),
            Text('Cannot reach Siti', style: HackerTheme.mono(size: 14, color: HackerTheme.red)),
            const SizedBox(height: 8),
            Text('VPS 178.156.241.204:3800', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
            const SizedBox(height: 4),
            Text(_error ?? '', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () { setState(() => _loading = true); _loadAll(); },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
                child: Text('RETRY', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.green)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // TAB 1: STATUS (was OVERVIEW)
  // ══════════════════════════════════════════════════

  Widget _buildStatus() {
    final stats = _health ?? {};
    final msgCount = _recentMessages.length;
    final waStatus = stats['status'] ?? 'unknown';
    final connAs = stats['connectedAs'] ?? '';
    final contacts = stats['contacts'] ?? 0;
    final memInfo = stats['mem'];
    final diskInfo = stats['disk'];

    final qrDataUrl = (stats['qrDataUrl'] as String?) ?? '';
    final isScanWaiting = waStatus.toString() == 'waiting_scan' && qrDataUrl.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (isScanWaiting) ...[
          _buildQrCard(qrDataUrl),
          const SizedBox(height: 16),
        ],
        _section('WHATSAPP CONTROLS'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _waControlButton('START WA', Icons.play_arrow, HackerTheme.green, '/api/whatsapp/start'),
            _waControlButton('STOP WA', Icons.stop, HackerTheme.red, '/api/whatsapp/stop'),
            _waRelinkButton(),
            _waControlButton('SYNC CONTACTS', Icons.sync, HackerTheme.cyan, '/api/whatsapp/sync'),
          ],
        ),
        const SizedBox(height: 16),

        _section('SITI STATUS'),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(active: waStatus == 'connected'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SITI — WhatsApp AI Agent', style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.green)),
              const SizedBox(height: 8),
              _statRow('WhatsApp', waStatus.toString()),
              _statRow('Phone', connAs.toString().isNotEmpty ? '+$connAs' : '+60126714634'),
              _statRow('Contacts', '$contacts'),
              _statRow('Recent messages', '$msgCount'),
              if (memInfo is Map) _statRow('Memory', '${((memInfo['total'] as num) / 1e9).toStringAsFixed(1)}GB (${memInfo['pct_used']}% used)'),
              if (diskInfo is Map) _statRow('Disk', '${((diskInfo['total'] as num) / 1e9).toStringAsFixed(0)}GB (${diskInfo['pct_used']}% used)'),
              _statRow('Instance', stats['instance_slug']?.toString() ?? 'vps-hetzner'),
              _statRow('Host', stats['hostname']?.toString() ?? 'nclaw'),
            ],
          ),
        ),
        const SizedBox(height: 16),

        _section('LLM PIPELINE'),
        _capCard('Gemini 2.5 Flash', 'Primary LLM + tool calling (thinkingBudget 1024)', HackerTheme.cyan),
        _capCard('OpenAI GPT-4o', 'Fallback LLM with tools', HackerTheme.amber),
        _capCard('Whisper STT', 'Voice note transcription (lang: ms)', HackerTheme.green),
        _capCard('Gemini/OpenAI Vision', 'Image analysis with fallback', HackerTheme.green),
        _capCard('ElevenLabs AFIFAH', 'TTS voice (eleven_flash_v2_5) + Interactive AI calls', HackerTheme.cyan),
        _capCard('Telnyx + Twilio', 'Outbound calls (MY +60360431442, US +17072160581)', HackerTheme.cyan),
        _capCard('DALL-E 3', 'Image generation', HackerTheme.amber),
        const SizedBox(height: 16),

        ..._buildToolsSection(),
      ],
    );
  }

  // ── Dynamic TOOLS section ──
  // Sources from Siti's /api/tools (since siti#19 — derives from GEMINI_TOOLS
  // at runtime so this list never drifts again). Groups by category, colors
  // each card by category, shows total count + counts per group.
  static const Map<String, Color> _toolCategoryColor = {
    'memory': HackerTheme.green,
    'identity': HackerTheme.cyan,
    'contacts': HackerTheme.cyan,
    'messaging': HackerTheme.amber,
    'groups': HackerTheme.amber,
    'agents': HackerTheme.green,
    'workspace': HackerTheme.cyan,
    'system': HackerTheme.grey,
    'other': HackerTheme.grey,
  };
  static const List<String> _toolCategoryOrder = [
    'memory', 'identity', 'contacts', 'agents',
    'messaging', 'groups', 'workspace', 'system', 'other',
  ];

  List<Widget> _buildToolsSection() {
    if (_tools.isEmpty) {
      return [
        _section('TOOLS'),
        _capCard('(loading…)', 'Fetching live tool list from Siti', HackerTheme.grey),
      ];
    }
    // Group by category
    final byCategory = <String, List<Map<String, dynamic>>>{};
    for (final t in _tools) {
      final c = (t['category'] ?? 'other').toString();
      byCategory.putIfAbsent(c, () => []).add(t);
    }
    final widgets = <Widget>[
      _section('${_tools.length} TOOLS · live from Siti'),
    ];
    // Render in canonical order, then any unknown categories at the end
    final seen = <String>{};
    for (final cat in _toolCategoryOrder) {
      final list = byCategory[cat];
      if (list == null || list.isEmpty) continue;
      seen.add(cat);
      widgets.add(_toolCategoryHeader(cat, list.length));
      for (final t in list) widgets.add(_toolCard(t));
    }
    for (final entry in byCategory.entries) {
      if (seen.contains(entry.key)) continue;
      widgets.add(_toolCategoryHeader(entry.key, entry.value.length));
      for (final t in entry.value) widgets.add(_toolCard(t));
    }
    return widgets;
  }

  Widget _toolCategoryHeader(String category, int count) {
    final color = _toolCategoryColor[category] ?? HackerTheme.grey;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4, left: 4),
      child: Row(children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(category.toUpperCase(), style: HackerTheme.monoNoGlow(size: 9, color: color)),
        const SizedBox(width: 6),
        Text('($count)', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
      ]),
    );
  }

  Widget _toolCard(Map<String, dynamic> tool) {
    final id = (tool['id'] ?? '?').toString();
    final desc = (tool['desc'] ?? '').toString();
    final category = (tool['category'] ?? 'other').toString();
    final enabled = tool['enabled'] != false;
    final color = enabled
        ? (_toolCategoryColor[category] ?? HackerTheme.grey)
        : HackerTheme.dimText;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: color, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text(id, style: HackerTheme.monoNoGlow(size: 11, color: color))),
            if (!enabled) Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: HackerTheme.red)),
              child: Text('DISABLED', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.red)),
            ),
          ]),
          if (desc.isNotEmpty) Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(desc, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
          ),
        ],
      ),
    );
  }

  Widget _waControlButton(String label, IconData icon, Color color, String endpoint) {
    return GestureDetector(
      onTap: () async {
        final result = await _postJson(endpoint, {});
        if (result != null) {
          SoundService.instance.playAcknowledged();
          _showSnack('$label: OK');
          _loadAll();
        } else {
          SoundService.instance.playWarning();
          _showSnack('$label: FAILED', error: true);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(label, style: HackerTheme.monoNoGlow(size: 9, color: color)),
          ],
        ),
      ),
    );
  }

  // "Re-link" destroys the current session, so confirm first.
  Widget _waRelinkButton() {
    return GestureDetector(
      onTap: _confirmRelink,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border.all(color: HackerTheme.amber.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.qr_code_2, size: 14, color: HackerTheme.amber),
            const SizedBox(width: 6),
            Text('RE-LINK (NEW QR)', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.amber)),
          ],
        ),
      ),
    );
  }

  void _confirmRelink() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.amber)),
        title: Text('RE-LINK WHATSAPP?', style: HackerTheme.mono(size: 14, color: HackerTheme.amber)),
        content: Text(
          'This will wipe the current Siti session and generate a new QR code. You will need to scan it from WhatsApp → Linked Devices.',
          style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final result = await _postJson('/api/whatsapp/fresh', {});
              if (result != null) {
                SoundService.instance.playAcknowledged();
                _showSnack('Re-link started — QR will appear shortly');
                _loadAll();
              } else {
                SoundService.instance.playWarning();
                _showSnack('RE-LINK: FAILED', error: true);
              }
            },
            child: Text('RE-LINK', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.amber)),
          ),
        ],
      ),
    );
  }

  Widget _buildQrCard(String qrDataUrl) {
    // qrDataUrl looks like "data:image/png;base64,iVBORw0K..."
    final commaIdx = qrDataUrl.indexOf(',');
    if (commaIdx < 0) return const SizedBox.shrink();
    final bytes = base64Decode(qrDataUrl.substring(commaIdx + 1));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: HackerTheme.terminalBox(active: true),
      child: Column(
        children: [
          Text('AWAITING QR SCAN', style: HackerTheme.mono(size: 13, color: HackerTheme.amber)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.white,
            child: Image.memory(bytes, width: 240, height: 240, gaplessPlayback: true),
          ),
          const SizedBox(height: 10),
          Text(
            'WhatsApp → Settings → Linked Devices → Link a Device',
            style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.amber),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Code refreshes every few seconds until scanned.',
            style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // TAB 2: MESSAGES (existing + pagination)
  // ══════════════════════════════════════════════════

  Widget _buildMessages() {
    if (_recentMessages.isEmpty) {
      return Center(child: Text('No recent messages', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _recentMessages.length + (_hasMoreMessages ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == _recentMessages.length) {
          // Load more button
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: _loadingMoreMessages
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: HackerTheme.green, strokeWidth: 2))
                  : GestureDetector(
                      onTap: _loadMoreMessages,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
                        child: Text('LOAD MORE', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
                      ),
                    ),
            ),
          );
        }

        final msg = _recentMessages[i];
        final direction = msg['direction'] ?? 'in';
        final contactName = msg['contact_name'] ?? msg['from_phone'] ?? '?';
        final body = msg['body'] ?? '';
        final isGroup = msg['is_group'] == true;
        final handled = msg['handled'] ?? '';
        final isOut = direction == 'out';

        final borderColor = isOut ? HackerTheme.green : isGroup ? HackerTheme.cyan : HackerTheme.amber;

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: HackerTheme.bgCard,
            border: Border(left: BorderSide(color: borderColor, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(isOut ? 'SITI →' : '← ', style: HackerTheme.monoNoGlow(size: 9, color: borderColor)),
                const SizedBox(width: 4),
                Expanded(child: Text(
                  contactName.toString(),
                  style: HackerTheme.monoNoGlow(size: 10, color: borderColor),
                  overflow: TextOverflow.ellipsis,
                )),
                if (handled.toString().isNotEmpty) Text(handled.toString(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
              ]),
              const SizedBox(height: 2),
              Text(
                body.toString().length > 150 ? '${body.toString().substring(0, 150)}...' : body.toString(),
                style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              if (isGroup) Text('GROUP', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
            ],
          ),
        );
      },
    );
  }

  Future<void> _loadMoreMessages() async {
    if (_loadingMoreMessages) return;
    setState(() => _loadingMoreMessages = true);
    try {
      final data = await _fetchJson('/api/messages?limit=50&offset=$_messageOffset');
      if (data != null && mounted) {
        final newMessages = _safeList(data, 'messages');
        setState(() {
          _recentMessages.addAll(newMessages);
          _messageOffset += newMessages.length;
          _hasMoreMessages = newMessages.length >= 50;
          _loadingMoreMessages = false;
        });
      } else {
        if (mounted) setState(() { _loadingMoreMessages = false; _hasMoreMessages = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _loadingMoreMessages = false; });
    }
  }

  // ══════════════════════════════════════════════════
  // TAB 3: CONTACTS (NEW)
  // ══════════════════════════════════════════════════

  String _contactSearch = '';
  bool _showAllPersonal = false;
  int _contactTab = 0; // 0 = personal, 1 = groups

  List<Map<String, dynamic>> get _groupContacts =>
      _contacts.where((c) => c['kind'] == 'group').toList();

  List<Map<String, dynamic>> get _personalContacts =>
      _contacts.where((c) => c['kind'] != 'group').toList();

  List<Map<String, dynamic>> get _activePersonal =>
      _personalContacts.where((c) {
        final perm = (c['permission'] ?? 'readonly').toString();
        return perm != 'readonly';
      }).toList();

  List<Map<String, dynamic>> _applySearch(List<Map<String, dynamic>> list) {
    if (_contactSearch.isEmpty) return list;
    final q = _contactSearch.toLowerCase();
    return list.where((c) {
      final name = (c['name'] ?? '').toString().toLowerCase();
      final phone = (c['phone'] ?? '').toString().toLowerCase();
      final perm = (c['permission'] ?? '').toString().toLowerCase();
      return name.contains(q) || phone.contains(q) || perm.contains(q);
    }).toList();
  }

  Widget _buildContacts() {
    final groups = _applySearch(_groupContacts);
    final personalSource = _showAllPersonal ? _personalContacts : _activePersonal;
    final personal = _applySearch(personalSource);

    return Column(
      children: [
        // Search field
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Container(
            height: 32,
            decoration: BoxDecoration(
              color: HackerTheme.bgCard,
              border: Border.all(color: HackerTheme.borderDim),
            ),
            child: TextField(
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              decoration: InputDecoration(
                hintText: 'Search contacts & groups...',
                hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                prefixIcon: const Icon(Icons.search, size: 14, color: HackerTheme.dimText),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _contactSearch = v),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Sub-tabs: Personal | Groups
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              _contactSubTab('CONTACTS', _activePersonal.length, 0),
              const SizedBox(width: 8),
              _contactSubTab('GROUPS', _groupContacts.length, 1),
              const Spacer(),
              GestureDetector(
                onTap: _showAddContactDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
                  child: Text('+ ADD', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.green)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // Tab content
        if (_contactTab == 0) ...[
          // Personal controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text(
                  _showAllPersonal
                      ? '${personal.length} of ${_personalContacts.length}'
                      : '${personal.length} active of ${_personalContacts.length}',
                  style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _showAllPersonal = !_showAllPersonal),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border.all(color: _showAllPersonal ? HackerTheme.amber : HackerTheme.borderDim),
                    ),
                    child: Text(
                      _showAllPersonal ? 'ACTIVE ONLY' : 'VIEW ALL ${_personalContacts.length}',
                      style: HackerTheme.monoNoGlow(size: 7, color: _showAllPersonal ? HackerTheme.amber : HackerTheme.dimText),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (_contactTab == 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '${groups.length} groups where Siti is active',
              style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
            ),
          ),
        const SizedBox(height: 2),
        Expanded(
          child: () {
            final list = _contactTab == 0 ? personal : groups;
            if (list.isEmpty) {
              return Center(child: Text(
                _contactSearch.isNotEmpty ? 'No matches for "$_contactSearch"' : 'No contacts loaded',
                style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText),
              ));
            }
            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: list.length,
              itemBuilder: (ctx, i) => _contactTile(list[i]),
            );
          }(),
        ),
      ],
    );
  }

  Widget _contactSubTab(String label, int count, int index) {
    final active = _contactTab == index;
    return GestureDetector(
      onTap: () => setState(() => _contactTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(
            color: active ? HackerTheme.green : Colors.transparent,
            width: 2,
          )),
        ),
        child: Row(
          children: [
            Text(label, style: HackerTheme.monoNoGlow(
              size: 9,
              color: active ? HackerTheme.green : HackerTheme.dimText,
            )),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: active ? HackerTheme.green.withValues(alpha: 0.5) : HackerTheme.borderDim),
              ),
              child: Text('$count', style: HackerTheme.monoNoGlow(
                size: 7,
                color: active ? HackerTheme.green : HackerTheme.dimText,
              )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contactTile(Map<String, dynamic> contact) {
    final name = contact['name'] ?? contact['phone'] ?? '?';
    final phone = contact['phone'] ?? '';
    final permission = (contact['permission'] ?? 'chat').toString();
    final autoReply = contact['auto_reply_enabled'] == true;
    final kind = contact['kind'] ?? '';

    final permColor = switch (permission) {
      'owner' => HackerTheme.green,
      'admin' => HackerTheme.cyan,
      'developer' => HackerTheme.amber,
      'chat' => HackerTheme.white,
      'limited' => HackerTheme.amber,
      'blocked' => HackerTheme.red,
      _ => HackerTheme.grey,
    };
    // For developer role: show project_scope as small chip-list under permission badge.
    final projectScope = (contact['project_scope'] is List)
        ? List<String>.from((contact['project_scope'] as List).map((e) => e.toString()))
        : <String>[];

    return GestureDetector(
      onTap: () => _showEditContactDialog(contact),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: permColor, width: 2)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
                  if (phone.toString().isNotEmpty)
                    Text(phone.toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                  if (permission == 'developer' && projectScope.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'scope: ${projectScope.join(", ")}',
                        style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.amber),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (kind.toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(kind.toString(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: permColor.withValues(alpha: 0.5))),
              child: Text(permission.toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: permColor)),
            ),
            const SizedBox(width: 6),
            Icon(
              autoReply ? Icons.reply : Icons.reply_outlined,
              size: 14,
              color: autoReply ? HackerTheme.green : HackerTheme.dimText,
            ),
          ],
        ),
      ),
    );
  }

  void _showAddContactDialog() {
    final phoneCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    String permission = 'chat';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: HackerTheme.bgPanel,
          shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.green)),
          title: Text('ADD CONTACT', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogTextField(phoneCtrl, 'Phone (e.g. 60177519610)', keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              _dialogTextField(nameCtrl, 'Name'),
              const SizedBox(height: 12),
              _permissionDropdown(permission, (v) => setDialogState(() => permission = v)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
            ),
            TextButton(
              onPressed: () async {
                if (phoneCtrl.text.trim().isEmpty) return;
                final result = await _postJson('/api/contacts', {
                  'phone': phoneCtrl.text.trim(),
                  'name': nameCtrl.text.trim(),
                  'permission': permission,
                });
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (result != null) {
                  SoundService.instance.playSent();
                  _showSnack('Contact added');
                  _loadAll();
                } else {
                  SoundService.instance.playWarning();
                  _showSnack('Failed to add contact', error: true);
                }
              },
              child: Text('ADD', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditContactDialog(Map<String, dynamic> contact) {
    final id = contact['id'];
    final nameCtrl = TextEditingController(text: contact['name']?.toString() ?? '');
    final personaCtrl = TextEditingController(text: contact['persona_override']?.toString() ?? '');
    String permission = (contact['permission'] ?? 'chat').toString();
    bool autoReply = contact['auto_reply_enabled'] == true;
    // project_scope: a comma-separated text input, applies only when permission='developer'.
    // text[] from Postgres comes through as List<dynamic>; coerce to strings safely.
    final initialScope = (contact['project_scope'] is List)
        ? List<String>.from((contact['project_scope'] as List).map((e) => e.toString()))
        : <String>[];
    final scopeCtrl = TextEditingController(text: initialScope.join(', '));
    bool saving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: HackerTheme.bgPanel,
          shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.cyan)),
          title: Row(
            children: [
              Expanded(child: Text('EDIT CONTACT', style: HackerTheme.mono(size: 14, color: HackerTheme.cyan))),
              GestureDetector(
                onTap: () => _confirmDeleteContact(ctx, id),
                child: const Icon(Icons.delete_outline, color: HackerTheme.red, size: 20),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Phone: ${contact['phone'] ?? '?'}', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                const SizedBox(height: 12),
                _dialogTextField(nameCtrl, 'Name'),
                const SizedBox(height: 12),
                _permissionDropdown(permission, (v) => setDialogState(() => permission = v)),
                if (permission == 'developer') ...[
                  const SizedBox(height: 12),
                  _dialogTextField(scopeCtrl, 'Project scope (comma-separated, e.g. todak-academy-v2, presentation)'),
                  const SizedBox(height: 4),
                  Text(
                    '↳ developer can only request changes for these project codes. Empty = no access.',
                    style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('Auto-reply', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
                    const Spacer(),
                    Switch(
                      value: autoReply,
                      onChanged: (v) => setDialogState(() => autoReply = v),
                      activeTrackColor: HackerTheme.green,
                      inactiveTrackColor: HackerTheme.bgCard,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _dialogTextField(personaCtrl, 'Persona override', maxLines: 4),
                if (saving)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(color: HackerTheme.green, backgroundColor: HackerTheme.bgCard),
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
              onPressed: saving ? null : () async {
                setDialogState(() => saving = true);
                // Parse comma-separated project scope into clean text[].
                // Only sent for developer permission; backend (Siti) ignores
                // it for other roles, but no point shipping noise.
                final scopeList = permission == 'developer'
                    ? scopeCtrl.text
                        .split(',')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList()
                    : <String>[];
                final result = await _postJson('/api/contacts/$id', {
                  'name': nameCtrl.text.trim(),
                  'permission': permission,
                  'project_scope': scopeList,
                  'auto_reply_enabled': autoReply,
                  'persona_override': personaCtrl.text.trim(),
                }, method: 'PATCH');
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (result != null) {
                  SoundService.instance.playSent();
                  _showSnack('Contact updated');
                  _loadAll();
                } else {
                  SoundService.instance.playWarning();
                  _showSnack('Failed to update contact', error: true);
                }
              },
              child: Text('SAVE', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteContact(BuildContext parentCtx, dynamic contactId) {
    showDialog(
      context: parentCtx,
      builder: (ctx) => AlertDialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.red)),
        title: Text('DELETE CONTACT?', style: HackerTheme.mono(size: 14, color: HackerTheme.red)),
        content: Text('This action cannot be undone.', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              Navigator.of(parentCtx).pop();
              final ok = await _deleteJson('/api/contacts/$contactId');
              if (ok) {
                SoundService.instance.playSent();
                _showSnack('Contact deleted');
                _loadAll();
              } else {
                SoundService.instance.playWarning();
                _showSnack('Failed to delete contact', error: true);
              }
            },
            child: Text('DELETE', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // TAB 4: CONFIG (was TAB 5 before PERSONS sub-tab was dropped — moved to MEM → PEOPLE)
  // ══════════════════════════════════════════════════

  Widget _buildConfig() {
    return _ConfigTab(
      settings: _settings,
      onSave: (updated) async {
        final result = await _postJson('/api/settings', updated);
        if (result != null) {
          SoundService.instance.playSent();
          _showSnack('Settings saved');
          _loadAll();
        } else {
          SoundService.instance.playWarning();
          _showSnack('Failed to save settings', error: true);
        }
      },
    );
  }

  // ── COMPOSE DIALOG ──

  void _showComposeDialog() {
    final phoneCtrl = TextEditingController();
    final msgCtrl = TextEditingController();
    bool sending = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: HackerTheme.bgPanel,
          shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.green)),
          title: Text('SEND WHATSAPP', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogTextField(phoneCtrl, 'Phone (e.g. 60177519610)', keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              _dialogTextField(msgCtrl, 'Message', maxLines: 4),
              if (sending)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(color: HackerTheme.green, backgroundColor: HackerTheme.bgCard),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('CANCEL', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
            ),
            TextButton(
              onPressed: sending
                  ? null
                  : () async {
                      if (phoneCtrl.text.trim().isEmpty || msgCtrl.text.trim().isEmpty) return;
                      setDialogState(() => sending = true);
                      final success = await _sendMessage(phoneCtrl.text.trim(), msgCtrl.text.trim());
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (mounted) {
                        _showSnack(success ? 'Message sent' : 'Failed to send', error: !success);
                        if (success) { SoundService.instance.playSent(); _loadAll(); }
                      }
                    },
              child: Text('SEND', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _sendMessage(String phone, String message) async {
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (kIsWeb) 'Authorization': 'Bearer ${AppConfig.authToken}',
      };
      final res = await http.post(
        Uri.parse('$_sitiBase/api/send'),
        headers: headers,
        body: jsonEncode({'to': phone, 'body': message}),
      ).timeout(const Duration(seconds: 10));
      return res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  // ── SHARED WIDGETS ──

  Widget _dialogTextField(TextEditingController ctrl, String label, {int maxLines = 1, TextInputType? keyboardType}) {
    return TextField(
      controller: ctrl,
      style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
        enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
      ),
      maxLines: maxLines,
      keyboardType: keyboardType,
    );
  }

  Widget _permissionDropdown(String value, ValueChanged<String> onChanged) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: HackerTheme.bgPanel,
      style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
      decoration: InputDecoration(
        labelText: 'Permission',
        labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
        enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
        focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
      ),
      items: ['owner', 'admin', 'developer', 'chat', 'limited', 'readonly', 'blocked'].map((p) {
        final c = switch (p) {
          'owner' => HackerTheme.green,
          'admin' => HackerTheme.cyan,
          'developer' => HackerTheme.amber,
          'blocked' => HackerTheme.red,
          'limited' => HackerTheme.amber,
          'readonly' => HackerTheme.grey,
          _ => HackerTheme.white,
        };
        return DropdownMenuItem(value: p, child: Text(p.toUpperCase(), style: HackerTheme.monoNoGlow(size: 10, color: c)));
      }).toList(),
      onChanged: (v) { if (v != null) onChanged(v); },
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text('// $text', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
  );

  Widget _statRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Row(children: [
      SizedBox(width: 120, child: Text(label, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText))),
      Expanded(child: Text(value, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white))),
    ]),
  );

  Widget _capCard(String name, String desc, Color color) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: HackerTheme.bgCard,
      border: Border(left: BorderSide(color: color, width: 2)),
    ),
    child: Row(children: [
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: HackerTheme.monoNoGlow(size: 10, color: color)),
        Text(desc, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
      ])),
    ]),
  );

  String _formatUptime(dynamic seconds) {
    if (seconds is! num) return '?';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return '${h}h ${m}m';
  }

  String _formatTs(dynamic ts) {
    try {
      final dt = DateTime.parse(ts.toString());
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}

// ══════════════════════════════════════════════════
// CONFIG TAB — Separate StatefulWidget for local editing state
// ══════════════════════════════════════════════════

class _ConfigTab extends StatefulWidget {
  final Map<String, dynamic> settings;
  final Future<void> Function(Map<String, dynamic>) onSave;
  const _ConfigTab({required this.settings, required this.onSave});

  @override
  State<_ConfigTab> createState() => _ConfigTabState();
}

class _ConfigTabState extends State<_ConfigTab> {
  late String _unknownPolicy;
  late TextEditingController _unknownReplyCtrl;
  late TextEditingController _personaCtrl;
  late TextEditingController _voiceIdCtrl;
  late String _voiceModel;
  late String _defaultReplyMode;
  bool _saving = false;

  static const _voiceModels = [
    'eleven_flash_v2_5',
    'eleven_multilingual_v2',
    'eleven_turbo_v2_5',
    'eleven_monolingual_v1',
  ];

  static const _replyModes = ['text', 'voice', 'auto'];

  @override
  void initState() {
    super.initState();
    _unknownPolicy = (widget.settings['unknown_sender_policy'] ?? 'reply_once').toString();
    _unknownReplyCtrl = TextEditingController(text: widget.settings['unknown_sender_reply']?.toString() ?? '');
    _personaCtrl = TextEditingController(text: widget.settings['default_persona']?.toString() ?? '');
    _voiceIdCtrl = TextEditingController(text: widget.settings['voice_id']?.toString() ?? '');
    _voiceModel = widget.settings['voice_model']?.toString() ?? 'eleven_flash_v2_5';
    if (!_voiceModels.contains(_voiceModel)) _voiceModel = 'eleven_flash_v2_5';
    _defaultReplyMode = widget.settings['default_reply_mode']?.toString() ?? 'text';
    if (!_replyModes.contains(_defaultReplyMode)) _defaultReplyMode = 'text';
  }

  @override
  void didUpdateWidget(_ConfigTab old) {
    super.didUpdateWidget(old);
    if (old.settings != widget.settings) {
      _unknownPolicy = (widget.settings['unknown_sender_policy'] ?? 'reply_once').toString();
      _unknownReplyCtrl.text = widget.settings['unknown_sender_reply']?.toString() ?? '';
      _personaCtrl.text = widget.settings['default_persona']?.toString() ?? '';
      _voiceIdCtrl.text = widget.settings['voice_id']?.toString() ?? '';
      _voiceModel = widget.settings['voice_model']?.toString() ?? 'eleven_flash_v2_5';
      if (!_voiceModels.contains(_voiceModel)) _voiceModel = 'eleven_flash_v2_5';
      _defaultReplyMode = widget.settings['default_reply_mode']?.toString() ?? 'text';
      if (!_replyModes.contains(_defaultReplyMode)) _defaultReplyMode = 'text';
    }
  }

  @override
  void dispose() {
    _unknownReplyCtrl.dispose();
    _personaCtrl.dispose();
    _voiceIdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projectGroups = widget.settings['project_groups'];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('// SITI SETTINGS', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
        ),

        // Unknown sender policy
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Unknown Sender Policy', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: ['reply_once', 'reply_always', 'ignore', 'block'].contains(_unknownPolicy) ? _unknownPolicy : 'reply_once',
                dropdownColor: HackerTheme.bgPanel,
                style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
                decoration: const InputDecoration(
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                items: ['reply_once', 'reply_always', 'ignore', 'block'].map((p) {
                  final c = switch (p) {
                    'reply_once' => HackerTheme.green,
                    'reply_always' => HackerTheme.cyan,
                    'ignore' => HackerTheme.amber,
                    'block' => HackerTheme.red,
                    _ => HackerTheme.white,
                  };
                  return DropdownMenuItem(value: p, child: Text(p, style: HackerTheme.monoNoGlow(size: 10, color: c)));
                }).toList(),
                onChanged: (v) { if (v != null) setState(() => _unknownPolicy = v); },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Unknown sender reply
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Unknown Sender Reply', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
              const SizedBox(height: 8),
              TextField(
                controller: _unknownReplyCtrl,
                style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
                decoration: const InputDecoration(
                  hintText: 'Auto-reply message for unknown senders',
                  hintStyle: TextStyle(color: HackerTheme.dimText, fontSize: 10),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Default persona
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Default Persona', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
              const SizedBox(height: 8),
              TextField(
                controller: _personaCtrl,
                style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
                decoration: const InputDecoration(
                  hintText: 'System prompt / persona for Siti',
                  hintStyle: TextStyle(color: HackerTheme.dimText, fontSize: 10),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                maxLines: 10,
                minLines: 5,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Voice settings
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('// VOICE SETTINGS (ElevenLabs)', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
        ),

        // Default reply mode
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Default Reply Mode', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
              const SizedBox(height: 4),
              Text('How Siti responds by default (can be overridden per contact)', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _defaultReplyMode,
                dropdownColor: HackerTheme.bgPanel,
                style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
                decoration: const InputDecoration(
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                items: _replyModes.map((m) {
                  final c = switch (m) {
                    'voice' => HackerTheme.amber,
                    'auto' => HackerTheme.cyan,
                    _ => HackerTheme.green,
                  };
                  final desc = switch (m) {
                    'text' => 'TEXT — always text replies',
                    'voice' => 'VOICE — always voice notes',
                    'auto' => 'AUTO — voice if they send voice, else text',
                    _ => m.toUpperCase(),
                  };
                  return DropdownMenuItem(value: m, child: Text(desc, style: HackerTheme.monoNoGlow(size: 10, color: c)));
                }).toList(),
                onChanged: (v) { if (v != null) setState(() => _defaultReplyMode = v); },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Voice model
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Voice Model', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
              const SizedBox(height: 4),
              Text('ElevenLabs TTS model for voice replies', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _voiceModel,
                dropdownColor: HackerTheme.bgPanel,
                style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
                decoration: const InputDecoration(
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                items: _voiceModels.map((m) {
                  final label = switch (m) {
                    'eleven_flash_v2_5' => 'Flash v2.5 (fastest, recommended)',
                    'eleven_multilingual_v2' => 'Multilingual v2 (best quality)',
                    'eleven_turbo_v2_5' => 'Turbo v2.5 (balanced)',
                    'eleven_monolingual_v1' => 'Monolingual v1 (English only)',
                    _ => m,
                  };
                  return DropdownMenuItem(value: m, child: Text(label, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)));
                }).toList(),
                onChanged: (v) { if (v != null) setState(() => _voiceModel = v); },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Voice ID
        Container(
          padding: const EdgeInsets.all(12),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Voice ID', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan)),
              const SizedBox(height: 4),
              Text('ElevenLabs voice ID (e.g. AFIFAH clone)', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              const SizedBox(height: 8),
              TextField(
                controller: _voiceIdCtrl,
                style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
                decoration: const InputDecoration(
                  hintText: 'ElevenLabs voice ID',
                  hintStyle: TextStyle(color: HackerTheme.dimText, fontSize: 10),
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Save button
        Center(
          child: GestureDetector(
            onTap: _saving ? null : () async {
              setState(() => _saving = true);
              await widget.onSave({
                'unknown_sender_policy': _unknownPolicy,
                'unknown_sender_reply': _unknownReplyCtrl.text.trim(),
                'default_persona': _personaCtrl.text.trim(),
                'voice_id': _voiceIdCtrl.text.trim(),
                'voice_model': _voiceModel,
                'default_reply_mode': _defaultReplyMode,
              });
              if (mounted) setState(() => _saving = false);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: _saving ? HackerTheme.dimText : HackerTheme.green),
                color: HackerTheme.bgCard,
              ),
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: HackerTheme.green, strokeWidth: 2))
                  : Text('SAVE SETTINGS', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.green)),
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Project groups (read-only)
        if (projectGroups != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('// PROJECT GROUPS (read-only)', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: HackerTheme.terminalBox(),
            child: Text(
              const JsonEncoder.withIndent('  ').convert(projectGroups),
              style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey),
            ),
          ),
        ],

        const SizedBox(height: 24),
      ],
    );
  }
}
