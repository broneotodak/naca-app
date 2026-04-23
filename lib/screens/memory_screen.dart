import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';
import '../theme.dart';

/// Memory viewer — browse neo-brain memories, people, facts, personality
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> with SingleTickerProviderStateMixin {
  SupabaseClient get _sb => Supabase.instance.client;

  late TabController _tabCtrl;
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _memories = [];
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _facts = [];
  List<Map<String, dynamic>> _personality = [];
  bool _loadingMemories = true;
  bool _loadingPeople = true;
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  String? _memError;
  String? _pplError;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _loadMemories();
    _loadPeople();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMemories() async {
    try {
      final data = await _sb.from('memories')
          .select('id, content, category, memory_type, importance, source, created_at')
          .order('created_at', ascending: false)
          .limit(50);
      if (mounted) setState(() { _memories = List<Map<String, dynamic>>.from(data); _loadingMemories = false; _memError = null; });
    } catch (e) {
      if (mounted) setState(() { _loadingMemories = false; _memError = e.toString(); });
    }
  }

  Future<void> _loadPeople() async {
    try {
      final ppl = await _sb.from('people')
          .select('id, display_name, kind, notes, identifiers, metadata, created_at, phone, lid, push_name, relationship, bio, nicknames, languages, facts, traits')
          .order('updated_at', ascending: false)
          .limit(50);
      final factsData = await _sb.from('facts')
          .select('id, subject_id, fact, category, confidence, created_at')
          .order('created_at', ascending: false)
          .limit(200);
      // Load personality traits
      final personalityData = await _sb.from('personality')
          .select('id, subject_id, trait, dimension, value, sample_count, description, example_behaviors')
          .order('dimension');
      if (mounted) setState(() {
        _people = List<Map<String, dynamic>>.from(ppl);
        _facts = List<Map<String, dynamic>>.from(factsData);
        _personality = List<Map<String, dynamic>>.from(personalityData);
        _loadingPeople = false;
        _pplError = null;
      });
    } catch (e) {
      if (mounted) setState(() { _loadingPeople = false; _pplError = e.toString(); });
    }
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _searching = true);
    try {
      // Search memories
      final memResults = await _sb.from('memories')
          .select('id, content, category, memory_type, importance, source, created_at')
          .ilike('content', '%$query%')
          .order('created_at', ascending: false)
          .limit(20);
      // Also search facts
      final factResults = await _sb.from('facts')
          .select('id, subject_id, fact, category, confidence, created_at')
          .ilike('fact', '%$query%')
          .order('created_at', ascending: false)
          .limit(20);
      if (mounted) setState(() {
        _searchResults = [
          ...List<Map<String, dynamic>>.from(memResults).map((m) => {...m, '_type': 'memory'}),
          ...List<Map<String, dynamic>>.from(factResults).map((f) => {...f, '_type': 'fact'}),
        ];
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  List<Map<String, dynamic>> _factsForPerson(String personId) {
    return _facts.where((f) => f['subject_id'] == personId).toList();
  }

  List<Map<String, dynamic>> _personalityForPerson(String personId) {
    return _personality.where((p) => p['subject_id'] == personId).toList();
  }

  Map<String, List<Map<String, dynamic>>> _personalityByDimension(String personId) {
    final traits = _personalityForPerson(personId);
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in traits) {
      final dim = t['dimension']?.toString() ?? 'other';
      grouped.putIfAbsent(dim, () => []).add(t);
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          _buildSearchBar(),
          TabBar(
            controller: _tabCtrl,
            indicatorColor: HackerTheme.green,
            labelColor: HackerTheme.green,
            unselectedLabelColor: HackerTheme.dimText,
            labelStyle: HackerTheme.monoNoGlow(size: 10),
            tabs: const [
              Tab(text: 'MEMORIES'),
              Tab(text: 'PEOPLE'),
              Tab(text: 'SEARCH'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _buildMemoriesTab(),
                _buildPeopleTab(),
                _buildSearchTab(),
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
        Text('neo-brain', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
        const Spacer(),
        Text('${_memories.length} mem', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
        const SizedBox(width: 8),
        Text('${_people.length} ppl', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
        const SizedBox(width: 8),
        Text('${_facts.length} facts', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
        const SizedBox(width: 8),
        Text('${_personality.length} traits', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
      ]),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: HackerTheme.bgCard,
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: HackerTheme.dimText),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.green),
              decoration: InputDecoration(
                hintText: 'Search memories & facts...',
                hintStyle: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.dimText),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (q) {
                _search(q);
                _tabCtrl.animateTo(2);
              },
            ),
          ),
          if (_searching) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: HackerTheme.green)),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // TAB 1: MEMORIES
  // ══════════════════════════════════════════════════

  Widget _buildMemoriesTab() {
    if (_loadingMemories) return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    if (_memError != null) return Center(child: Text('Error: $_memError', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)));
    if (_memories.isEmpty) return Center(child: Text('No memories found', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));

    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgCard,
      onRefresh: _loadMemories,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _memories.length,
        itemBuilder: (ctx, i) => _memoryCard(_memories[i]),
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // TAB 2: PEOPLE (with tap-to-expand detail + personality)
  // ══════════════════════════════════════════════════

  Widget _buildPeopleTab() {
    if (_loadingPeople) return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    if (_pplError != null) return Center(child: Text('Error: $_pplError', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)));
    if (_people.isEmpty) return Center(child: Text('No people found', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));

    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgCard,
      onRefresh: _loadPeople,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _people.length,
        itemBuilder: (ctx, i) {
          final person = _people[i];
          return _personCard(person, onTap: () => _showPersonDetail(person));
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // TAB 3: SEARCH
  // ══════════════════════════════════════════════════

  Widget _buildSearchTab() {
    if (_searchResults.isEmpty && !_searching) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search, size: 48, color: HackerTheme.dimText),
          const SizedBox(height: 8),
          Text('Search memories & facts', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)),
        ]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _searchResults.length,
      itemBuilder: (ctx, i) {
        final item = _searchResults[i];
        if (item['_type'] == 'fact') return _factSearchCard(item);
        return _memoryCard(item);
      },
    );
  }

  // ══════════════════════════════════════════════════
  // PERSON DETAIL — Bottom Sheet
  // ══════════════════════════════════════════════════

  void _showPersonDetail(Map<String, dynamic> person) {
    final personId = person['id'] as String?;
    if (personId == null) return;

    final name = person['display_name'] ?? 'Unknown';
    final kind = person['kind'] ?? '';
    final notes = person['notes'] ?? '';
    final identifiers = person['identifiers'];
    final metadata = person['metadata'];
    final personFacts = _factsForPerson(personId);
    final personalityDims = _personalityByDimension(personId);
    final hasPersonality = personalityDims.isNotEmpty;

    // Group facts by category
    final factsByCategory = <String, List<Map<String, dynamic>>>{};
    for (final f in personFacts) {
      final cat = f['category']?.toString() ?? 'general';
      factsByCategory.putIfAbsent(cat, () => []).add(f);
    }

    final kindColor = switch (kind.toString()) {
      'self' => HackerTheme.green,
      'bot' => HackerTheme.cyan,
      'group' => HackerTheme.amber,
      _ => HackerTheme.white,
    };

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: HackerTheme.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
        side: BorderSide(color: HackerTheme.borderDim),
      ),
      builder: (ctx) => DraggableScrollableSheet(
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
                  Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(color: kindColor, shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: kindColor.withValues(alpha: 0.5), blurRadius: 6)]),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name.toString().toUpperCase(), style: HackerTheme.mono(size: 14, color: kindColor)),
                        Row(children: [
                          if (kind.toString().isNotEmpty) Text(kind.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                          if (personFacts.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text('${personFacts.length} facts', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
                          ],
                          if (hasPersonality) ...[
                            const SizedBox(width: 8),
                            Text('${personalityDims.values.fold<int>(0, (s, l) => s + l.length)} traits', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                          ],
                        ]),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _showEditPersonDialog(person);
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.edit_outlined, size: 18, color: HackerTheme.green),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _confirmDeletePerson(person);
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.delete_outline, size: 18, color: HackerTheme.red),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(),
                    child: const Icon(Icons.close, size: 18, color: HackerTheme.dimText),
                  ),
                ],
              ),
            ),
            // Body
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(12),
                children: [
                  // Identifiers
                  if (identifiers is List && identifiers.isNotEmpty) ...[
                    _detailSection('IDENTIFIERS'),
                    Wrap(spacing: 8, runSpacing: 4, children: identifiers.map<Widget>((id) {
                      final type = id is Map ? (id['type'] ?? '') : '';
                      final value = id is Map ? (id['value'] ?? '') : id.toString();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(border: Border.all(color: HackerTheme.borderDim)),
                        child: Text('$type: $value', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
                      );
                    }).toList()),
                    const SizedBox(height: 16),
                  ],

                  // Notes
                  if (notes.toString().isNotEmpty) ...[
                    _detailSection('NOTES'),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: HackerTheme.terminalBox(),
                      child: Text(notes.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Personality traits (with visual bars)
                  if (hasPersonality) ...[
                    _detailSection('PERSONALITY PROFILE'),
                    ...personalityDims.entries.map((entry) => _buildDimensionCard(entry.key, entry.value)),
                    const SizedBox(height: 16),
                  ],

                  // Facts grouped by category
                  if (personFacts.isNotEmpty) ...[
                    _detailSection('FACTS (${personFacts.length})'),
                    ...factsByCategory.entries.map((entry) => _buildFactCategory(entry.key, entry.value)),
                  ],

                  // Metadata
                  if (metadata is Map && metadata.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _detailSection('METADATA'),
                    Container(
                      padding: const EdgeInsets.all(8),
                      color: HackerTheme.bgCard,
                      child: Text(
                        const JsonEncoder.withIndent('  ').convert(metadata),
                        style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey),
                        maxLines: 20,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailSection(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text('// $text', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
  );

  // ── PERSONALITY DIMENSION CARD ──

  Widget _buildDimensionCard(String dimension, List<Map<String, dynamic>> traits) {
    final dimColor = switch (dimension) {
      'communication' => HackerTheme.cyan,
      'expertise' => HackerTheme.green,
      'work_style' => HackerTheme.amber,
      'decision_making' => HackerTheme.red,
      _ => HackerTheme.white,
    };

    final dimIcon = switch (dimension) {
      'communication' => Icons.chat_bubble_outline,
      'expertise' => Icons.code,
      'work_style' => Icons.build_outlined,
      'decision_making' => Icons.psychology_outlined,
      _ => Icons.extension,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: dimColor, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(dimIcon, size: 14, color: dimColor),
            const SizedBox(width: 6),
            Text(
              dimension.replaceAll('_', ' ').toUpperCase(),
              style: HackerTheme.monoNoGlow(size: 10, color: dimColor),
            ),
          ]),
          const SizedBox(height: 8),
          ...traits.map((t) {
            final trait = t['trait']?.toString() ?? '?';
            final value = (t['value'] as num?)?.toDouble() ?? 0;
            final samples = t['sample_count'] ?? 0;
            final barValue = value.clamp(0.0, 1.0);

            // Color based on value intensity
            final barColor = barValue > 0.6 ? HackerTheme.green
                : barValue > 0.3 ? HackerTheme.amber
                : HackerTheme.dimText;

            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(trait.replaceAll('_', ' '), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.white)),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: barValue,
                            backgroundColor: HackerTheme.bgPanel,
                            color: barColor,
                            minHeight: 8,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 35,
                        child: Text(
                          '${(barValue * 100).toInt()}%',
                          style: HackerTheme.monoNoGlow(size: 8, color: barColor),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 110),
                    child: Text('$samples samples', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ── FACTS BY CATEGORY ──

  Widget _buildFactCategory(String category, List<Map<String, dynamic>> facts) {
    final catColor = switch (category.toLowerCase()) {
      'work' || 'project' || 'professional' => HackerTheme.cyan,
      'personal' || 'identity' || 'family' => HackerTheme.green,
      'technical' || 'skill' || 'expertise' => HackerTheme.amber,
      'preference' || 'opinion' => HackerTheme.white,
      _ => HackerTheme.grey,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: catColor, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: catColor.withValues(alpha: 0.4))),
              child: Text(category.toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: catColor)),
            ),
            const SizedBox(width: 6),
            Text('${facts.length}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
          ]),
          const SizedBox(height: 4),
          ...facts.map((f) {
            final fact = f['fact'] ?? '';
            final confidence = f['confidence'];
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• ', style: HackerTheme.monoNoGlow(size: 9, color: catColor)),
                  Expanded(child: Text(fact.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.white))),
                  if (confidence != null)
                    Text('${((confidence as num) * 100).toInt()}%', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════
  // CARD WIDGETS
  // ══════════════════════════════════════════════════

  Widget _memoryCard(Map<String, dynamic> mem) {
    final content = mem['content'] ?? '';
    final category = mem['category'] ?? '';
    final memType = mem['memory_type'] ?? '';
    final importance = mem['importance'] ?? 5;
    final source = mem['source'] ?? '';
    final createdAt = mem['created_at'] as String?;

    final catColor = switch (category.toString().toLowerCase()) {
      'work' || 'project' => HackerTheme.cyan,
      'personal' || 'identity' => HackerTheme.green,
      'technical' || 'code' => HackerTheme.amber,
      _ => HackerTheme.grey,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: Border(left: BorderSide(color: catColor, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            if (category.toString().isNotEmpty) Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: catColor.withValues(alpha: 0.5))),
              child: Text(category.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: catColor)),
            ),
            if (memType.toString().isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(memType.toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            ],
            const Spacer(),
            if (source.toString().isNotEmpty) Text(source.toString(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
            const SizedBox(width: 6),
            Text('imp:$importance', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
            if (createdAt != null) ...[
              const SizedBox(width: 8),
              Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
            ],
          ]),
          const SizedBox(height: 6),
          Text(
            content.toString().length > 200 ? '${content.toString().substring(0, 200)}...' : content.toString(),
            style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
          ),
        ],
      ),
    );
  }

  Widget _personCard(Map<String, dynamic> person, {VoidCallback? onTap}) {
    final name = person['display_name'] ?? 'Unknown';
    final kind = person['kind'] ?? '';
    final notes = person['notes'] ?? '';
    final identifiers = person['identifiers'];
    final personId = person['id'] as String?;
    final personFacts = personId != null ? _factsForPerson(personId) : <Map<String, dynamic>>[];
    final hasTraits = personId != null && _personalityForPerson(personId).isNotEmpty;

    final kindColor = switch (kind.toString()) {
      'self' => HackerTheme.green,
      'bot' => HackerTheme.cyan,
      'group' => HackerTheme.amber,
      _ => HackerTheme.white,
    };

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: HackerTheme.terminalBox(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: kindColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(name.toString(), style: HackerTheme.monoNoGlow(size: 12, color: kindColor))),
              if (kind.toString().isNotEmpty) Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: kindColor.withValues(alpha: 0.5))),
                child: Text(kind.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: kindColor)),
              ),
              if (hasTraits) ...[
                const SizedBox(width: 6),
                const Icon(Icons.psychology_outlined, size: 14, color: HackerTheme.cyan),
              ],
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 14, color: HackerTheme.dimText),
            ]),
            if (identifiers is List && identifiers.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: identifiers.take(3).map<Widget>((id) {
                final type = id is Map ? (id['type'] ?? '') : '';
                final value = id is Map ? (id['value'] ?? '') : id.toString();
                return Text('$type:$value', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey));
              }).toList()),
            ],
            if (notes.toString().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(notes.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText), maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            // Summary row
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                if (personFacts.isNotEmpty) Text('${personFacts.length} facts', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                if (hasTraits) ...[
                  const SizedBox(width: 8),
                  Text('personality', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
                ],
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _factSearchCard(Map<String, dynamic> fact) {
    final factText = fact['fact'] ?? '';
    final category = fact['category'] ?? '';
    final confidence = fact['confidence'];

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: HackerTheme.bgCard,
        border: const Border(left: BorderSide(color: HackerTheme.amber, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: HackerTheme.amber.withValues(alpha: 0.5))),
              child: Text('FACT', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.amber)),
            ),
            if (category.toString().isNotEmpty) ...[
              const SizedBox(width: 6),
              Text(category.toString(), style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            ],
            const Spacer(),
            if (confidence != null) Text('${((confidence as num) * 100).toInt()}% conf', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
          ]),
          const SizedBox(height: 6),
          Text(factText.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
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

  // ══════════════════════════════════════════════════
  // EDIT PERSON — Form dialog → PATCH /api/siti/api/people/:id
  // ══════════════════════════════════════════════════

  void _showEditPersonDialog(Map<String, dynamic> person) {
    final id = person['id'] as String?;
    if (id == null) return;

    final displayCtrl = TextEditingController(text: (person['display_name'] ?? '').toString());
    final pushCtrl = TextEditingController(text: (person['push_name'] ?? '').toString());
    final relCtrl = TextEditingController(text: (person['relationship'] ?? '').toString());
    final bioCtrl = TextEditingController(text: (person['bio'] ?? '').toString());
    final nicksCtrl = TextEditingController(text: _csv(person['nicknames']));
    final langsCtrl = TextEditingController(text: _csv(person['languages']));
    final factsCtrl = TextEditingController(text: _multiline(person['facts']));
    final traitsCtrl = TextEditingController(text: _multiline(person['traits']));

    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          bool saving = false;
          String? errMsg;
          return Dialog(
            backgroundColor: HackerTheme.bgPanel,
            shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.green)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
              child: StatefulBuilder(
                builder: (ctx2, setLocal) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: HackerTheme.borderDim))),
                      child: Row(children: [
                        Text('EDIT IDENTITY', style: HackerTheme.mono(size: 13, color: HackerTheme.green)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.of(ctx).pop(),
                          child: const Icon(Icons.close, size: 18, color: HackerTheme.dimText),
                        ),
                      ]),
                    ),
                    // Body
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          // Read-only identifiers strip — helps disambiguate who you're editing
                          if (person['identifiers'] is List && (person['identifiers'] as List).isNotEmpty) ...[
                            Text('// IDENTIFIERS (read-only)', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                            const SizedBox(height: 4),
                            Wrap(spacing: 6, runSpacing: 4, children: (person['identifiers'] as List).map<Widget>((id) {
                              final type = id is Map ? (id['type'] ?? '').toString() : '';
                              final value = id is Map ? (id['value'] ?? '').toString() : id.toString();
                              final chipColor = switch (type) {
                                'phone' => HackerTheme.cyan,
                                'lid' => HackerTheme.amber,
                                'push_name' => HackerTheme.grey,
                                _ => HackerTheme.dimText,
                              };
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(border: Border.all(color: chipColor.withValues(alpha: 0.5))),
                                child: Text('$type: $value', style: HackerTheme.monoNoGlow(size: 9, color: chipColor)),
                              );
                            }).toList()),
                            const SizedBox(height: 4),
                            Text('// identifiers are set by Siti from real interactions — not edited here', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                            const SizedBox(height: 6),
                            const Divider(color: HackerTheme.borderDim, height: 1),
                          ],
                          // Show Siti-extracted counts so it's obvious where the rich data lives
                          Padding(
                            padding: const EdgeInsets.only(top: 6, bottom: 6),
                            child: Wrap(spacing: 10, runSpacing: 2, children: [
                              Text('// siti-extracted:', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                              Text('${_facts.where((f) => f['subject_id'] == person['id']).length} facts', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                              Text('${_personality.where((p) => p['subject_id'] == person['id']).length} traits', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                              Text('(separate tables — not edited here)', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                            ]),
                          ),
                          const Divider(color: HackerTheme.borderDim, height: 1),
                          const SizedBox(height: 4),
                          Text('// inline fields below = quick freeform notes you add manually', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                          _fieldLabel('display_name'),
                          _textField(displayCtrl),
                          _fieldLabel('push_name'),
                          _textField(pushCtrl),
                          _fieldLabel('relationship'),
                          _textField(relCtrl, hint: 'e.g. sister, colleague, client'),
                          _fieldLabel('bio'),
                          _textField(bioCtrl, maxLines: 2),
                          _fieldLabel('nicknames (comma-separated)'),
                          _textField(nicksCtrl),
                          _fieldLabel('languages (comma-separated)'),
                          _textField(langsCtrl),
                          _fieldLabel('facts (one per line)'),
                          _textField(factsCtrl, maxLines: 4),
                          _fieldLabel('traits (one per line)'),
                          _textField(traitsCtrl, maxLines: 3),
                          if (errMsg != null) Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text('// $errMsg', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
                          ),
                        ]),
                      ),
                    ),
                    // Footer
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: const BoxDecoration(border: Border(top: BorderSide(color: HackerTheme.borderDim))),
                      child: Row(children: [
                        if (saving) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: HackerTheme.green)),
                        const Spacer(),
                        TextButton(
                          onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                          child: Text('CANCEL', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText)),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(side: const BorderSide(color: HackerTheme.green)),
                          onPressed: saving ? null : () async {
                            setLocal(() { saving = true; errMsg = null; });
                            final body = {
                              'display_name': displayCtrl.text.trim(),
                              'push_name': pushCtrl.text.trim(),
                              'relationship': relCtrl.text.trim(),
                              'bio': bioCtrl.text.trim(),
                              'replace_nicknames': _splitCsv(nicksCtrl.text),
                              'languages': _splitCsv(langsCtrl.text),
                              'facts': _splitLines(factsCtrl.text),
                              'traits': _splitLines(traitsCtrl.text),
                            };
                            final res = await _patchPerson(id, body);
                            if (!mounted) return;
                            if (res == null) {
                              Navigator.of(ctx).pop();
                              await _loadPeople();
                              if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('saved', style: HackerTheme.mono(size: 11, color: HackerTheme.green)), backgroundColor: HackerTheme.bgCard, duration: const Duration(seconds: 2)),
                              );
                            } else {
                              setLocal(() { saving = false; errMsg = res; });
                            }
                          },
                          child: Text('SAVE', style: HackerTheme.mono(size: 11, color: HackerTheme.green)),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _confirmDeletePerson(Map<String, dynamic> person) {
    final id = person['id'] as String?;
    if (id == null) return;
    final name = person['display_name'] ?? 'this person';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: const RoundedRectangleBorder(side: BorderSide(color: HackerTheme.red)),
        title: Text('DELETE $name?', style: HackerTheme.mono(size: 12, color: HackerTheme.red)),
        content: Text(
          'This removes the identity from neo-brain.\nMemories attached by subject_id will unlink (set to NULL). This cannot be undone.',
          style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text('CANCEL', style: HackerTheme.mono(size: 11, color: HackerTheme.dimText))),
          OutlinedButton(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: HackerTheme.red)),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final err = await _deletePerson(id);
              if (!mounted) return;
              if (err == null) {
                await _loadPeople();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('deleted', style: HackerTheme.mono(size: 11, color: HackerTheme.red)),
                  backgroundColor: HackerTheme.bgCard,
                  duration: const Duration(seconds: 2),
                ));
              } else {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('delete failed: $err', style: HackerTheme.mono(size: 11, color: HackerTheme.red)),
                  backgroundColor: HackerTheme.bgCard,
                ));
              }
            },
            child: Text('DELETE', style: HackerTheme.mono(size: 11, color: HackerTheme.red)),
          ),
        ],
      ),
    );
  }

  // Returns null on success, error string on failure.
  Future<String?> _patchPerson(String id, Map<String, dynamic> body) async {
    try {
      final res = await http.patch(
        Uri.parse('${AppConfig.apiBaseUrl}/api/siti/api/people/$id'),
        headers: {
          'Authorization': 'Bearer ${AppConfig.authToken}',
          'content-type': 'application/json',
        },
        body: jsonEncode(body),
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

  Future<String?> _deletePerson(String id) async {
    try {
      final res = await http.delete(
        Uri.parse('${AppConfig.apiBaseUrl}/api/siti/api/people/$id'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
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

  // Form helpers

  Widget _fieldLabel(String t) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 4),
    child: Text('// $t', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
  );

  Widget _textField(TextEditingController c, {String? hint, int maxLines = 1}) => TextField(
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

  String _csv(dynamic v) {
    if (v is List) return v.map((x) => x.toString()).join(', ');
    return '';
  }
  String _multiline(dynamic v) {
    if (v is List) return v.map((x) => x.toString()).join('\n');
    return '';
  }
  List<String> _splitCsv(String s) => s.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
  List<String> _splitLines(String s) => s.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
}
