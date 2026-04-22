import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme.dart';
import '../config.dart';
import '../services/sound_service.dart';

/// Siti Dashboard — WhatsApp bot status, recent messages, person graph
class SitiScreen extends StatefulWidget {
  const SitiScreen({super.key});

  @override
  State<SitiScreen> createState() => _SitiScreenState();
}

class _SitiScreenState extends State<SitiScreen> with SingleTickerProviderStateMixin {
  // On web: proxy through VPS backend (port 3100) to avoid CORS
  // On mobile/desktop: direct to Siti (port 3800)
  String get _sitiBase => kIsWeb
      ? '${AppConfig.apiBaseUrl}/api/siti'   // proxy: 3100 → 3800
      : 'http://178.156.241.204:3800';

  Map<String, dynamic>? _health;
  List<Map<String, dynamic>> _recentMessages = [];
  List<Map<String, dynamic>> _persons = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  late TabController _tabCtrl;

  bool get _isSitiOnline => _health != null && _health!.isNotEmpty && (_health!['status'] == 'connected' || _health!['hostname'] != null);

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _loadAll();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _loadAll());
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
      final people = await _fetchJson('/api/people');

      if (mounted) {
        // Merge health + status into one map
        final merged = <String, dynamic>{
          ...?health,
          ...?status,
        };
        setState(() {
          _health = merged.isNotEmpty ? merged : null;
          _recentMessages = _extractMessages(status);
          _persons = _safeList(people, 'people');
          _loading = false;
          _error = (health == null && status == null) ? 'Cannot reach Siti' : null;
        });
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
      // When proxying through VPS backend, include auth token
      final headers = kIsWeb ? {'Authorization': 'Bearer ${AppConfig.authToken}'} : <String, String>{};
      final res = await http.get(Uri.parse('$_sitiBase$path'), headers: headers).timeout(const Duration(seconds: 8));
      if (res.statusCode < 400) return jsonDecode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

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
            tabs: const [
              Tab(text: 'OVERVIEW'),
              Tab(text: 'MESSAGES'),
              Tab(text: 'PERSONS'),
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
                              _buildOverview(),
                              _buildMessages(),
                              _buildPersons(),
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
              TextField(
                controller: phoneCtrl,
                style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
                decoration: InputDecoration(
                  labelText: 'Phone (e.g. 60177519610)',
                  labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                  enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: msgCtrl,
                style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
                decoration: InputDecoration(
                  labelText: 'Message',
                  labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                  enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
                ),
                maxLines: 4,
              ),
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
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                            success ? 'Message sent' : 'Failed to send',
                            style: HackerTheme.monoNoGlow(size: 10, color: success ? HackerTheme.green : HackerTheme.red),
                          ),
                          backgroundColor: HackerTheme.bgCard,
                        ));
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

  Widget _buildOverview() {
    final stats = _health ?? {};
    final personCount = _persons.length;
    final msgCount = _recentMessages.length;
    final waStatus = stats['status'] ?? 'unknown';
    final connAs = stats['connectedAs'] ?? '';
    final contacts = stats['contacts'] ?? 0;
    final memInfo = stats['mem'];
    final diskInfo = stats['disk'];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
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
              _statRow('Persons (graph)', '$personCount'),
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
        _capCard('ElevenLabs AFIFAH', 'TTS voice (eleven_flash_v2_5)', HackerTheme.cyan),
        _capCard('DALL-E 3', 'Image generation', HackerTheme.amber),
        const SizedBox(height: 16),

        _section('15 TOOLS'),
        _capCard('1. search_twin_memory', 'Search neo-brain memories', HackerTheme.green),
        _capCard('2. save_twin_memory', 'Write to neo-brain', HackerTheme.green),
        _capCard('3. update_contact', 'Change permission/persona/reply_mode', HackerTheme.cyan),
        _capCard('4. get_contact_status', 'Lookup contact info', HackerTheme.cyan),
        _capCard('5. search_person', 'Find known persons', HackerTheme.cyan),
        _capCard('6. list_known_persons', 'List all identities', HackerTheme.cyan),
        _capCard('7. send_whatsapp', 'Send text (resolves name→phone)', HackerTheme.green),
        _capCard('8. send_voice_note', 'ElevenLabs AFIFAH → OGG Opus → WA PTT', HackerTheme.amber),
        _capCard('9. generate_image', 'DALL-E 3 → WhatsApp image', HackerTheme.amber),
        _capCard('10. save_face', 'InsightFace embedding → neo-brain', HackerTheme.amber),
        _capCard('11. recognize_faces', 'Detect + match faces in photos', HackerTheme.amber),
        _capCard('12. make_call', 'Telnyx outbound + ElevenLabs TTS playback', HackerTheme.red),
        _capCard('13. web_search', 'DuckDuckGo HTML scraping', HackerTheme.grey),
        _capCard('14. search_conversations', 'Cross-chat history lookup', HackerTheme.grey),
        _capCard('15. sync_whatsapp_contacts', 'Refresh contacts from WhatsApp', HackerTheme.grey),
      ],
    );
  }

  Widget _buildMessages() {
    if (_recentMessages.isEmpty) {
      return Center(child: Text('No recent messages', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _recentMessages.length,
      itemBuilder: (ctx, i) {
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

  Widget _buildPersons() {
    if (_persons.isEmpty) {
      return Center(child: Text('No persons tracked', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _persons.length,
      itemBuilder: (ctx, i) {
        final p = _persons[i];
        final name = p['display_name'] ?? p['name'] ?? 'Unknown';
        final kind = p['kind'] ?? '';
        final notes = p['notes'] ?? '';
        final identifiers = p['identifiers'] as List? ?? [];
        final facts = p['facts'] as List? ?? [];

        final kindColor = switch (kind.toString()) {
          'self' => HackerTheme.green,
          'bot' => HackerTheme.cyan,
          'group' => HackerTheme.amber,
          _ => HackerTheme.white,
        };

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: HackerTheme.terminalBox(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(name.toString(), style: HackerTheme.monoNoGlow(size: 11, color: kindColor)),
                if (kind.toString().isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(kind.toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                ],
              ]),
              if (identifiers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(spacing: 8, children: identifiers.take(2).map<Widget>((id) {
                    if (id is Map) return Text('${id['type']}:${id['value']}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey));
                    return Text(id.toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey));
                  }).toList()),
                ),
              if (notes.toString().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(notes.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText), maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: 4),
                ...facts.take(3).map((f) {
                  final text = f is Map ? (f['fact'] ?? f.toString()) : f.toString();
                  return Text('• $text', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey), overflow: TextOverflow.ellipsis);
                }),
                if (facts.length > 3) Text('+${facts.length - 3} more', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
              ],
            ],
          ),
        );
      },
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
