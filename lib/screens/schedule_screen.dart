import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../theme.dart';

/// SCHEDULE — operator cockpit for neo-brain.scheduled_actions
/// Lists scheduled / fired / failed / cancelled rows. Cancel pending rows.
/// Compose new operator-side reminders (kind=send_whatsapp).
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  List<Map<String, dynamic>> _actions = [];
  Map<String, int> _stats = {};
  bool _loading = true;
  String? _error;

  String _statusFilter = 'scheduled'; // scheduled|fired|failed|cancelled|all
  String _kindFilter = 'all';         // all|send_whatsapp|agent_command|agent_intent

  Timer? _poll;
  final Set<String> _cancelling = {};

  @override
  void initState() {
    super.initState();
    _load();
    // Poll every 15s while screen is mounted — good enough at zero volume.
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
      final params = <String, String>{'limit': '120'};
      if (_statusFilter != 'all') params['status'] = _statusFilter;
      if (_kindFilter != 'all') params['kind'] = _kindFilter;
      final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/scheduled-actions').replace(queryParameters: params);
      final res = await http.get(uri, headers: {
        'Authorization': 'Bearer ${AppConfig.authToken}',
      }).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        if (mounted) setState(() { _loading = false; _error = 'HTTP ${res.statusCode}'; });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) setState(() {
        _actions = List<Map<String, dynamic>>.from(body['actions'] ?? const []);
        _stats = Map<String, int>.from((body['stats'] as Map?)?.map((k, v) => MapEntry(k.toString(), (v as num).toInt())) ?? {});
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _cancel(String id) async {
    setState(() => _cancelling.add(id));
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/scheduled-actions/$id/cancel'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode >= 400) {
        String msg = 'HTTP ${res.statusCode}';
        try { final j = jsonDecode(res.body); if (j is Map && j['error'] != null) msg = j['error'].toString(); } catch (_) {}
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cancel failed: $msg'), backgroundColor: HackerTheme.red),
        );
      } else {
        await _load(silent: true);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cancel error: $e'), backgroundColor: HackerTheme.red),
      );
    } finally {
      if (mounted) setState(() => _cancelling.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Stack(
        children: [
          Column(
            children: [
              _buildHeader(),
              _buildFilters(),
              Expanded(child: _buildList()),
            ],
          ),
          // FABs — REMINDER (existing) + COMPOSE POST (Phase 4 Step E2 first slice)
          Positioned(
            right: 16,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'sched-compose-post',
                  onPressed: _showPostComposeDialog,
                  backgroundColor: HackerTheme.bgPanel,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                    side: BorderSide(color: HackerTheme.cyan),
                  ),
                  icon: const Icon(Icons.send, color: HackerTheme.cyan, size: 16),
                  label: Text('COMPOSE POST', style: HackerTheme.mono(size: 10, color: HackerTheme.cyan)),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: 'sched-reminder',
                  onPressed: _showComposeDialog,
                  backgroundColor: HackerTheme.bgPanel,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                    side: BorderSide(color: HackerTheme.green),
                  ),
                  icon: const Icon(Icons.add, color: HackerTheme.green, size: 16),
                  label: Text('NEW REMINDER', style: HackerTheme.mono(size: 10, color: HackerTheme.green)),
                ),
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
        Text('schedule', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
        const Spacer(),
        _statBadge('${_stats['scheduled'] ?? 0} pending', HackerTheme.cyan),
        const SizedBox(width: 6),
        _statBadge('${_stats['fired'] ?? 0} fired', HackerTheme.green),
        const SizedBox(width: 6),
        _statBadge('${_stats['failed'] ?? 0} failed', HackerTheme.red),
        const SizedBox(width: 6),
        _statBadge('${_stats['cancelled'] ?? 0} cxl', HackerTheme.grey),
      ]),
    );
  }

  Widget _statBadge(String text, Color color) => Text(text, style: HackerTheme.monoNoGlow(size: 9, color: color));

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: HackerTheme.bgCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in const ['scheduled', 'fired', 'failed', 'cancelled', 'all']) ...[
                  _filterChip(s.toUpperCase(), _statusFilter == s, () {
                    setState(() => _statusFilter = s);
                    _load();
                  }, color: _statusColor(s)),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Kind row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text('kind:', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                const SizedBox(width: 6),
                for (final k in const ['all', 'send_whatsapp', 'agent_command', 'agent_intent']) ...[
                  _filterChip(k, _kindFilter == k, () {
                    setState(() => _kindFilter = k);
                    _load();
                  }, color: HackerTheme.amber, small: true),
                  const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String s) => switch (s) {
    'scheduled' => HackerTheme.cyan,
    'fired' => HackerTheme.green,
    'failed' => HackerTheme.red,
    'cancelled' => HackerTheme.grey,
    _ => HackerTheme.amber,
  };

  Widget _filterChip(String label, bool selected, VoidCallback onTap, {required Color color, bool small = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 3),
        decoration: BoxDecoration(border: Border.all(color: selected ? color : HackerTheme.borderDim)),
        child: Text(label, style: HackerTheme.monoNoGlow(size: small ? 7 : 8, color: selected ? color : HackerTheme.dimText)),
      ),
    );
  }

  Widget _buildList() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    if (_error != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('schedule error', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
          const SizedBox(height: 6),
          Text(_error!, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _load,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
              child: Text('RETRY', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.green)),
            ),
          ),
        ]),
      ));
    }
    if (_actions.isEmpty) {
      return Center(child: Text('no actions in this view', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));
    }
    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgCard,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: _actions.length,
        itemBuilder: (ctx, i) => _actionCard(_actions[i]),
      ),
    );
  }

  Widget _actionCard(Map<String, dynamic> a) {
    final id = a['id']?.toString() ?? '';
    final kind = (a['action_kind'] ?? '').toString();
    final status = (a['status'] ?? '').toString();
    final fireAt = a['fire_at']?.toString();
    final firedAt = a['fired_at']?.toString();
    final description = (a['description'] ?? '').toString();
    final createdBy = (a['created_by'] ?? '').toString();
    final recurrence = (a['recurrence'] ?? '').toString();
    final attempts = (a['attempts'] is num) ? (a['attempts'] as num).toInt() : 0;
    final maxAttempts = (a['max_attempts'] is num) ? (a['max_attempts'] as num).toInt() : 0;
    final payload = a['action_payload'];
    final result = a['result'];

    final statusColor = _statusColor(status);
    final kindColor = switch (kind) {
      'send_whatsapp' => HackerTheme.green,
      'agent_command' => HackerTheme.cyan,
      'agent_intent' => HackerTheme.amber,
      _ => HackerTheme.grey,
    };

    final fireDate = fireAt != null ? DateTime.tryParse(fireAt)?.toLocal() : null;
    final firedDate = firedAt != null ? DateTime.tryParse(firedAt)?.toLocal() : null;
    final isPending = status == 'scheduled';
    final timeText = isPending && fireDate != null
        ? 'fires ${_relative(fireDate)}'
        : firedDate != null
            ? 'fired ${_timeAgo(firedDate)} ago'
            : fireDate != null
                ? '${_timeAgo(fireDate)} ago'
                : '';

    final payloadPreview = _payloadPreview(kind, payload);
    final cancelling = _cancelling.contains(id);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: statusColor, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: statusColor.withValues(alpha: 0.6))),
                child: Text(status.toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: statusColor)),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: kindColor.withValues(alpha: 0.5))),
                child: Text(kind, style: HackerTheme.monoNoGlow(size: 7, color: kindColor)),
              ),
              if (recurrence.isNotEmpty) ...[
                const SizedBox(width: 6),
                Icon(Icons.repeat, size: 11, color: HackerTheme.amber.withValues(alpha: 0.7)),
              ],
              const Spacer(),
              if (timeText.isNotEmpty) Text(timeText, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
            ]),
          ),
          // Description
          if (description.isNotEmpty) Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(description, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
          ),
          // Payload preview
          if (payloadPreview.isNotEmpty) Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            child: Text(payloadPreview, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
          ),
          // Footer
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Row(children: [
              if (createdBy.isNotEmpty) Text('by $createdBy', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
              if (recurrence.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(recurrence, style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.amber)),
              ],
              if (attempts > 0) ...[
                const SizedBox(width: 8),
                Text('$attempts/$maxAttempts tries', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.grey)),
              ],
              const Spacer(),
              GestureDetector(
                onTap: () => _showDetail(a),
                child: Text('DETAIL', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
              ),
              if (isPending) ...[
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: cancelling ? null : () => _confirmCancel(id, description),
                  child: cancelling
                      ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: HackerTheme.red))
                      : Text('CANCEL', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.red)),
                ),
              ],
              if (status == 'failed' && result is Map && result['error'] != null) ...[
                const SizedBox(width: 12),
                Tooltip(
                  message: result['error'].toString(),
                  child: const Icon(Icons.error_outline, size: 12, color: HackerTheme.red),
                ),
              ],
            ]),
          ),
        ],
      ),
    );
  }

  String _payloadPreview(String kind, dynamic payload) {
    if (payload is! Map) return '';
    final p = Map<String, dynamic>.from(payload);
    if (kind == 'send_whatsapp') {
      final to = p['to']?.toString() ?? '';
      final msg = p['message']?.toString() ?? '';
      final shortMsg = msg.length > 80 ? '${msg.substring(0, 80)}...' : msg;
      return '→ $to: $shortMsg';
    }
    if (kind == 'agent_command') {
      return '→ ${p['to_agent'] ?? '?'}: ${p['command'] ?? '?'}';
    }
    if (kind == 'agent_intent') {
      final raw = p['raw_text']?.toString() ?? '';
      return raw.length > 80 ? '${raw.substring(0, 80)}...' : raw;
    }
    return '';
  }

  void _showDetail(Map<String, dynamic> a) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: HackerTheme.bgPanel,
      shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.borderDim)),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollCtrl) => Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: HackerTheme.borderDim))),
            child: Row(children: [
              Text('action ${a['id']?.toString().substring(0, 8) ?? ''}', style: HackerTheme.mono(size: 12, color: HackerTheme.green)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: const Icon(Icons.close, size: 18, color: HackerTheme.dimText),
              ),
            ]),
          ),
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(12),
              children: [
                _detailJson('action_payload', a['action_payload']),
                if (a['result'] != null) _detailJson('result', a['result']),
                _detailJson('row', a),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _detailJson(String label, dynamic value) {
    final pretty = const JsonEncoder.withIndent('  ').convert(value);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('// $label', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
          const SizedBox(height: 4),
          SelectableText(pretty, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
        ],
      ),
    );
  }

  Future<void> _confirmCancel(String id, String description) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.borderDim)),
        title: Text('Cancel reminder?', style: HackerTheme.mono(size: 13, color: HackerTheme.red)),
        content: Text(
          description.isEmpty ? 'Cancel scheduled action ${id.substring(0, 8)}?' : 'Cancel "$description"?',
          style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('KEEP', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('CANCEL IT', style: HackerTheme.mono(size: 11, color: HackerTheme.red))),
        ],
      ),
    );
    if (ok == true) await _cancel(id);
  }

  // ─────────────── Compose dialog ───────────────

  void _showComposeDialog() {
    final phoneCtrl = TextEditingController(text: '60177519610');
    final messageCtrl = TextEditingController();
    final rruleCtrl = TextEditingController();
    DateTime fireAt = DateTime.now().add(const Duration(minutes: 30));
    String? formError;
    bool submitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: HackerTheme.bgPanel,
          shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.borderDim)),
          title: Text('// NEW REMINDER', style: HackerTheme.mono(size: 13, color: HackerTheme.green)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('to (phone, no +)'),
                  _input(phoneCtrl, hint: '60177519610'),
                  _label('message'),
                  _input(messageCtrl, hint: 'minum ubat', maxLines: 3),
                  _label('fires at (local time)'),
                  GestureDetector(
                    onTap: () async {
                      final date = await showDatePicker(
                        context: ctx,
                        initialDate: fireAt,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (date == null) return;
                      if (!ctx.mounted) return;
                      final time = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay.fromDateTime(fireAt),
                      );
                      if (time == null) return;
                      setLocal(() => fireAt = DateTime(date.year, date.month, date.day, time.hour, time.minute));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(border: Border.all(color: HackerTheme.borderDim)),
                      child: Row(children: [
                        const Icon(Icons.schedule, size: 14, color: HackerTheme.cyan),
                        const SizedBox(width: 8),
                        Text(_formatLocal(fireAt), style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
                      ]),
                    ),
                  ),
                  _label('recurrence (optional RRULE)'),
                  _input(rruleCtrl, hint: 'FREQ=DAILY  or  FREQ=WEEKLY;BYDAY=MO'),
                  if (formError != null) Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(formError!, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: submitting ? null : () => Navigator.pop(ctx), child: Text('CANCEL', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText))),
            TextButton(
              onPressed: submitting ? null : () async {
                final phone = phoneCtrl.text.trim();
                final msg = messageCtrl.text.trim();
                final rrule = rruleCtrl.text.trim();
                if (phone.isEmpty || msg.isEmpty) { setLocal(() => formError = 'phone and message required'); return; }
                if (fireAt.isBefore(DateTime.now())) { setLocal(() => formError = 'fire_at must be in the future'); return; }
                setLocal(() { submitting = true; formError = null; });
                final err = await _createReminder(to: phone, message: msg, fireAt: fireAt, recurrence: rrule.isEmpty ? null : rrule);
                if (err != null) {
                  setLocal(() { submitting = false; formError = err; });
                } else {
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _load(silent: true);
                }
              },
              child: submitting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: HackerTheme.green))
                  : Text('SCHEDULE', style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
            ),
          ],
        ),
      ),
    );
  }

  // ── COMPOSE POST dialog (Phase 4 Step E2 first slice) ──
  // Backend writes a scheduled_action pointing at poster-agent. Agent itself
  // does not exist yet — these rows wait at status='scheduled' until it ships.
  // For now this is the operator-side data flow; v2 adds Drive/MEDIA pickers.

  static const List<String> _channels = ['linkedin', 'threads', 'instagram', 'tiktok', 'twitter'];

  void _showPostComposeDialog() {
    String channel = 'linkedin';
    final captionCtrl = TextEditingController();
    final driveFileIdCtrl = TextEditingController();
    DateTime fireAt = DateTime.now().add(const Duration(hours: 1));
    String? formError;
    bool submitting = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: HackerTheme.bgPanel,
          shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.cyan)),
          title: Row(children: [
            const Icon(Icons.send, size: 16, color: HackerTheme.cyan),
            const SizedBox(width: 8),
            Text('// COMPOSE POST', style: HackerTheme.mono(size: 13, color: HackerTheme.cyan)),
          ]),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('queue a social media post · poster-agent fires at fire_at',
                    style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                  _label('channel'),
                  Wrap(
                    spacing: 6, runSpacing: 6,
                    children: _channels.map((c) {
                      final selected = channel == c;
                      return GestureDetector(
                        onTap: () => setLocal(() => channel = c),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: selected ? HackerTheme.cyan : HackerTheme.borderDim),
                            color: selected ? HackerTheme.cyan.withValues(alpha: 0.1) : null,
                          ),
                          child: Text(c.toUpperCase(),
                            style: HackerTheme.monoNoGlow(size: 9, color: selected ? HackerTheme.cyan : HackerTheme.dimText)),
                        ),
                      );
                    }).toList(),
                  ),
                  _label('caption'),
                  _input(captionCtrl, hint: 'What to post…', maxLines: 5),
                  _label('fires at (local time)'),
                  GestureDetector(
                    onTap: () async {
                      final date = await showDatePicker(
                        context: ctx,
                        initialDate: fireAt,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (date == null) return;
                      if (!ctx.mounted) return;
                      final time = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay.fromDateTime(fireAt),
                      );
                      if (time == null) return;
                      setLocal(() => fireAt = DateTime(date.year, date.month, date.day, time.hour, time.minute));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      decoration: BoxDecoration(border: Border.all(color: HackerTheme.borderDim)),
                      child: Row(children: [
                        const Icon(Icons.schedule, size: 14, color: HackerTheme.cyan),
                        const SizedBox(width: 8),
                        Text(_formatLocal(fireAt), style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
                      ]),
                    ),
                  ),
                  _label('drive file id (optional — attaches a Drive file as media)'),
                  _input(driveFileIdCtrl, hint: 'paste from WSPC › FILES, or leave empty for text-only'),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(border: Border.all(color: HackerTheme.amber.withValues(alpha: 0.4))),
                      child: Text(
                        '// poster-agent does not exist yet. This row queues at status=scheduled '
                        'and waits. When the agent ships (TODO), it picks up these rows and posts. '
                        'Cancel anytime from the SCHED list.',
                        style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.amber),
                      ),
                    ),
                  ),
                  if (formError != null) Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(formError!, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(ctx),
              child: Text('CANCEL', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)),
            ),
            TextButton(
              onPressed: submitting ? null : () async {
                final caption = captionCtrl.text.trim();
                final driveFileId = driveFileIdCtrl.text.trim();
                if (caption.isEmpty) { setLocal(() => formError = 'caption required'); return; }
                if (fireAt.isBefore(DateTime.now())) { setLocal(() => formError = 'fire_at must be in the future'); return; }
                setLocal(() { submitting = true; formError = null; });
                final err = await _createPost(
                  channel: channel,
                  caption: caption,
                  fireAt: fireAt,
                  driveFileId: driveFileId.isEmpty ? null : driveFileId,
                );
                if (err != null) {
                  setLocal(() { submitting = false; formError = err; });
                } else {
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _load(silent: true);
                }
              },
              child: submitting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: HackerTheme.cyan))
                  : Text('SCHEDULE POST', style: HackerTheme.mono(size: 11, color: HackerTheme.cyan)),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _createPost({
    required String channel,
    required String caption,
    required DateTime fireAt,
    String? driveFileId,
    String? mediaId,
  }) async {
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/content/schedule'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'channel': channel,
          'caption': caption,
          'fire_at': fireAt.toUtc().toIso8601String(),
          if (driveFileId != null) 'drive_file_id': driveFileId,
          if (mediaId != null) 'media_id': mediaId,
        }),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        try { final j = jsonDecode(res.body); return j['error']?.toString() ?? 'HTTP ${res.statusCode}'; } catch (_) {}
        return 'HTTP ${res.statusCode}';
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> _createReminder({required String to, required String message, required DateTime fireAt, String? recurrence}) async {
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.apiBaseUrl}/api/scheduled-actions'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'action_kind': 'send_whatsapp',
          'to': to,
          'message': message,
          'fire_at': fireAt.toUtc().toIso8601String(),
          if (recurrence != null) 'recurrence': recurrence,
          'description': message,
        }),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        try { final j = jsonDecode(res.body); return j['error']?.toString() ?? 'HTTP ${res.statusCode}'; } catch (_) {}
        return 'HTTP ${res.statusCode}';
      }
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text('// $t', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
  );

  Widget _input(TextEditingController c, {String? hint, int maxLines = 1}) => TextField(
    controller: c,
    maxLines: maxLines,
    style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      border: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.green)),
    ),
  );

  // ─────────────── Time helpers ───────────────

  String _formatLocal(DateTime dt) {
    final pad = (int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt).abs();
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  String _relative(DateTime target) {
    final diff = target.difference(DateTime.now());
    if (diff.isNegative) return '${_timeAgo(target)} ago (overdue)';
    if (diff.inSeconds < 60) return 'in ${diff.inSeconds}s';
    if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
    if (diff.inHours < 24) return 'in ${diff.inHours}h';
    return 'in ${diff.inDays}d';
  }
}
