import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../services/sound_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../config.dart';

/// Settings — connection status, config, agent management
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Map<String, _ConnStatus> _connections = {};
  bool _testing = false;

  // Custom command state
  String _customTarget = 'supervisor';
  final _customCmdCtrl = TextEditingController();
  final _customPayloadCtrl = TextEditingController();
  bool _sendingCustom = false;
  static const _targetAgents = ['supervisor', 'siti', 'dev-agent', 'naca-app'];

  @override
  void initState() {
    super.initState();
    _testConnections();
  }

  @override
  void dispose() {
    _customCmdCtrl.dispose();
    _customPayloadCtrl.dispose();
    super.dispose();
  }

  Future<void> _testConnections() async {
    setState(() => _testing = true);
    final results = <String, _ConnStatus>{};

    // Test VPS Backend
    try {
      final sw = Stopwatch()..start();
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/health'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 5));
      sw.stop();
      if (res.statusCode < 400) {
        final body = jsonDecode(res.body);
        results['VPS Backend'] = _ConnStatus(true, '${sw.elapsedMilliseconds}ms', 'Sessions: ${body['sessions'] ?? '?'}');
      } else {
        results['VPS Backend'] = _ConnStatus(false, 'HTTP ${res.statusCode}', '');
      }
    } catch (e) {
      results['VPS Backend'] = _ConnStatus(false, 'Unreachable', e.toString());
    }

    // Test Supabase
    try {
      final sw = Stopwatch()..start();
      await Supabase.instance.client.from('agent_heartbeats').select('agent_name').limit(1);
      sw.stop();
      results['Supabase (neo-brain)'] = _ConnStatus(true, '${sw.elapsedMilliseconds}ms', 'Connected');
    } catch (e) {
      results['Supabase (neo-brain)'] = _ConnStatus(false, 'Error', e.toString());
    }

    // Test Siti — proxy through VPS backend on web
    try {
      final sitiUrl = kIsWeb
          ? '${AppConfig.apiBaseUrl}/api/siti/api/health'
          : 'http://178.156.241.204:3800/api/health';
      final sitiHeaders = kIsWeb
          ? <String, String>{'Authorization': 'Bearer ${AppConfig.authToken}'}
          : <String, String>{};
      final sw = Stopwatch()..start();
      final res = await http.get(Uri.parse(sitiUrl), headers: sitiHeaders).timeout(const Duration(seconds: 5));
      sw.stop();
      if (res.statusCode < 400) {
        final body = jsonDecode(res.body);
        results['Siti (nclaw)'] = _ConnStatus(true, '${sw.elapsedMilliseconds}ms', 'Host: ${body['hostname'] ?? '?'}');
      } else {
        results['Siti (nclaw)'] = _ConnStatus(false, 'HTTP ${res.statusCode}', '');
      }
    } catch (e) {
      results['Siti (nclaw)'] = _ConnStatus(false, 'Unreachable', e.toString());
    }

    // Test WebSocket
    results['WebSocket'] = _ConnStatus(true, 'configured', AppConfig.wsUrl);

    if (mounted) setState(() { _connections = results; _testing = false; });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _section('CONNECTIONS'),
                ..._connections.entries.map(_buildConnCard),
                if (_testing) const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator(color: HackerTheme.green)),
                ),
                const SizedBox(height: 8),
                _buildTestButton(),
                const SizedBox(height: 24),

                _section('CONFIGURATION'),
                _configRow('Supabase URL', AppConfig.supabaseUrl),
                _configRow('API Base', AppConfig.apiBaseUrl),
                _configRow('WebSocket', AppConfig.wsUrl),
                _configRow('Auth Token', '${AppConfig.authToken.substring(0, 10)}...'),
                const SizedBox(height: 24),

                _section('SYSTEM INFO'),
                _configRow('App', 'NACA v1.0.0'),
                _configRow('Framework', 'Flutter'),
                _configRow('Agent Bus', 'Supabase (neo-brain)'),
                _configRow('VPS', 'Hetzner CPX31 (178.156.241.204)'),
                _configRow('Services', 'nclaw-dashboard, dev-agent, naca-backend'),
                const SizedBox(height: 24),

                _section('AGENT COMMANDS'),
                _buildCommandButton('Ping All Agents', 'heartbeat_check', Icons.favorite_border),
                const SizedBox(height: 8),
                _buildCommandButton('Request Status Report', 'status_report', Icons.assessment),
                const SizedBox(height: 8),
                _buildCommandButton('Restart Dev Agent', 'restart', Icons.refresh, toAgent: 'dev-agent'),
                const SizedBox(height: 24),

                _section('CUSTOM COMMAND'),
                _buildCustomCommandPanel(),
                const SizedBox(height: 24),
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
        Text('settings', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
      ]),
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    child: Text('// $text', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
  );

  Widget _buildConnCard(MapEntry<String, _ConnStatus> entry) {
    final s = entry.value;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: s.ok ? HackerTheme.green : HackerTheme.red, width: 2)),
      ),
      child: Row(children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            color: s.ok ? HackerTheme.green : HackerTheme.red,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.key, style: HackerTheme.monoNoGlow(size: 11, color: s.ok ? HackerTheme.green : HackerTheme.red)),
            if (s.detail.isNotEmpty) Text(s.detail, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
          ],
        )),
        Text(s.latency, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
      ]),
    );
  }

  Widget _buildTestButton() {
    return GestureDetector(
      onTap: _testing ? null : _testConnections,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: _testing ? HackerTheme.dimText : HackerTheme.green),
        ),
        child: Center(
          child: Text(
            _testing ? 'TESTING...' : 'TEST ALL CONNECTIONS',
            style: HackerTheme.monoNoGlow(size: 11, color: _testing ? HackerTheme.dimText : HackerTheme.green),
          ),
        ),
      ),
    );
  }

  Widget _configRow(String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: HackerTheme.bgCard,
      child: Row(children: [
        SizedBox(width: 100, child: Text(label, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText))),
        Expanded(child: Text(value, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white), overflow: TextOverflow.ellipsis)),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Copied', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
              backgroundColor: HackerTheme.bgCard,
              duration: const Duration(seconds: 1),
            ));
          },
          child: const Icon(Icons.copy, size: 12, color: HackerTheme.dimText),
        ),
      ]),
    );
  }

  Widget _buildCommandButton(String label, String command, IconData icon, {String? toAgent}) {
    return GestureDetector(
      onTap: () => _sendCommand(command, toAgent: toAgent),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border.all(color: HackerTheme.borderDim),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: HackerTheme.cyan),
          const SizedBox(width: 10),
          Text(label, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
          const Spacer(),
          const Icon(Icons.send, size: 14, color: HackerTheme.dimText),
        ]),
      ),
    );
  }

  Widget _buildCustomCommandPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: HackerTheme.terminalBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Target agent dropdown
          Row(
            children: [
              SizedBox(
                width: 80,
                child: Text('TARGET', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: HackerTheme.bgCard,
                    border: Border.all(color: HackerTheme.borderDim),
                  ),
                  child: DropdownButton<String>(
                    value: _customTarget,
                    isExpanded: true,
                    dropdownColor: HackerTheme.bgPanel,
                    underline: const SizedBox.shrink(),
                    style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.green),
                    items: _targetAgents.map((a) => DropdownMenuItem(
                      value: a,
                      child: Text(a, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.green)),
                    )).toList(),
                    onChanged: (v) { if (v != null) setState(() => _customTarget = v); },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Command name
          TextField(
            controller: _customCmdCtrl,
            style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
            decoration: InputDecoration(
              labelText: 'Command name',
              labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
              enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
              focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
            ),
          ),
          const SizedBox(height: 10),
          // Payload (optional JSON)
          TextField(
            controller: _customPayloadCtrl,
            style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
            decoration: InputDecoration(
              labelText: 'Payload (JSON, optional)',
              labelStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
              enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
              focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
            ),
            maxLines: 3,
          ),
          const SizedBox(height: 14),
          // Send button
          GestureDetector(
            onTap: _sendingCustom ? null : _sendCustomCommand,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: _sendingCustom ? HackerTheme.dimText : HackerTheme.cyan),
              ),
              child: Center(
                child: _sendingCustom
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(color: HackerTheme.cyan, strokeWidth: 2),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.send, size: 14, color: HackerTheme.cyan),
                          const SizedBox(width: 8),
                          Text('DISPATCH COMMAND', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.cyan)),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendCustomCommand() async {
    final cmd = _customCmdCtrl.text.trim();
    if (cmd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Command name required', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.amber)),
        backgroundColor: HackerTheme.bgCard,
      ));
      return;
    }

    Map<String, dynamic> payload = {};
    final payloadText = _customPayloadCtrl.text.trim();
    if (payloadText.isNotEmpty) {
      try {
        payload = Map<String, dynamic>.from(jsonDecode(payloadText) as Map);
      } catch (_) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Invalid JSON payload', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
          backgroundColor: HackerTheme.bgCard,
        ));
        return;
      }
    }

    setState(() => _sendingCustom = true);
    try {
      await Supabase.instance.client.from('agent_commands').insert({
        'from_agent': 'naca-app',
        'to_agent': _customTarget,
        'command': cmd,
        'payload': payload,
        'priority': 5,
      });
      if (mounted) {
        _customCmdCtrl.clear();
        _customPayloadCtrl.clear();
        SoundService.instance.playAcknowledged();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Sent "$cmd" to $_customTarget', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
          backgroundColor: HackerTheme.bgCard,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
          backgroundColor: HackerTheme.bgCard,
        ));
      }
    } finally {
      if (mounted) setState(() => _sendingCustom = false);
    }
  }

  Future<void> _sendCommand(String command, {String? toAgent}) async {
    try {
      await Supabase.instance.client.from('agent_commands').insert({
        'from_agent': 'naca-app',
        'to_agent': toAgent ?? 'supervisor',
        'command': command,
        'payload': {},
        'priority': 5,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Command sent: $command', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green)),
          backgroundColor: HackerTheme.bgCard,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
          backgroundColor: HackerTheme.bgCard,
        ));
      }
    }
  }
}

class _ConnStatus {
  final bool ok;
  final String latency;
  final String detail;
  const _ConnStatus(this.ok, this.latency, this.detail);
}
