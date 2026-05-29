import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../theme.dart';

/// STUDIO — operator console for the NACA fleet.
///
/// 3-segment shell: TEMPLATES (default — daily-content theme editor),
/// JOBS (placeholder), COST (placeholder).
///
/// Pause/resume of individual agents lives on the HQ tab, where the agent
/// listing already is — see dashboard_screen.dart `_buildAgentCard`. The
/// `/api/studio/agents` backend endpoint remains live but is currently
/// unused by the UI; future segments (JOBS / COST / RUN NOW) will consume
/// their own purpose-built endpoints.
///
/// Backend endpoints used here:
///   - `GET   /api/content-templates`          — templates list
///   - `PATCH /api/content-templates/{id}`     — toggle / edit
///   - `POST  /api/content-templates`          — create
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

enum _Segment { templates, jobs, cost }

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
      case _Segment.jobs:
        return const _ComingSoon(label: 'JOBS', detail: 'Live + recent agent_commands and scheduled_actions');
      case _Segment.cost:
        return const _ComingSoon(label: 'COST', detail: 'Month-to-date per agent + per provider');
    }
  }
}


class _ComingSoon extends StatelessWidget {
  final String label;
  final String detail;
  const _ComingSoon({required this.label, required this.detail});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('// $label — coming soon',
              style: HackerTheme.mono(size: 12, color: HackerTheme.dimText)),
          const SizedBox(height: 6),
          Text(detail,
              textAlign: TextAlign.center,
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
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
                Text('TAP TO EDIT',
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
