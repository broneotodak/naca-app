import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
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

  // MEDIA tab state
  List<Map<String, dynamic>> _media = [];
  bool _loadingMedia = false;
  String? _mediaError;
  String _mediaKind = 'all'; // all|image|audio|video
  String _mediaMode = 'browse'; // browse|search
  final _mediaSearchCtrl = TextEditingController();
  bool _mediaLoadedOnce = false;

  // Cross-link cache: media metadata by id, populated lazily after _loadMemories.
  // Lets memory cards render a badge for rows with non-null media_id without
  // hitting the API per row. Backed by NACA /api/media-batch (no signed URLs).
  Map<String, Map<String, dynamic>> _mediaById = {};
  String? _highlightMemoryId; // set when we navigate from MEDIA → MEMORIES

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _tabCtrl.addListener(() {
      if (_tabCtrl.index == 3 && !_mediaLoadedOnce) {
        _mediaLoadedOnce = true;
        _loadMedia();
      }
    });
    _loadMemories();
    _loadPeople();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    _mediaSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMemories() async {
    try {
      final data = await _sb.from('memories')
          .select('id, content, category, memory_type, importance, source, created_at, media_id')
          .order('created_at', ascending: false)
          .limit(50);
      if (mounted) setState(() { _memories = List<Map<String, dynamic>>.from(data); _loadingMemories = false; _memError = null; });
      // Fire-and-forget enrichment for any rows with media_id
      _enrichMemoriesWithMedia(_memories);
    } catch (e) {
      if (mounted) setState(() { _loadingMemories = false; _memError = e.toString(); });
    }
  }

  // Batch-fetch media metadata for memories that have media_id, then setState
  // so the badges render. No signed URLs here — the badge is metadata-only.
  Future<void> _enrichMemoriesWithMedia(List<Map<String, dynamic>> memories) async {
    final ids = <String>{};
    for (final m in memories) {
      final mid = m['media_id'];
      if (mid is String && mid.isNotEmpty && !_mediaById.containsKey(mid)) ids.add(mid);
    }
    if (ids.isEmpty) return;
    try {
      final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/media-batch')
          .replace(queryParameters: {'ids': ids.join(',')});
      final res = await http.get(uri, headers: {
        'Authorization': 'Bearer ${AppConfig.authToken}',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode >= 400) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = List<Map<String, dynamic>>.from(body['media'] ?? const []);
      if (mounted) setState(() {
        for (final m in list) {
          final id = m['id']?.toString();
          if (id != null) _mediaById[id] = m;
        }
      });
    } catch (_) {
      // Silent — badges just won't render. Memory list still works.
    }
  }

  Future<void> _loadPeople() async {
    try {
      final ppl = await _sb.from('people')
          .select('id, display_name, kind, notes, identifiers, metadata, created_at, phone, lid, push_name, relationship, bio, nicknames, languages, facts, traits')
          .order('updated_at', ascending: false)
          .limit(200);
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
              Tab(text: 'MEDIA'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _buildMemoriesTab(),
                _buildPeopleTab(),
                _buildSearchTab(),
                _buildMediaTab(),
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
        if (_mediaLoadedOnce) ...[
          const SizedBox(width: 8),
          Text('${_media.length} media', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.amber)),
        ],
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

  String _peopleSearch = '';
  bool _showAllPeople = false;

  int _personRichness(Map<String, dynamic> p) {
    int score = 0;
    if (p['bio'] != null && (p['bio'] as String).isNotEmpty) score += 10;
    if (p['relationship'] != null && (p['relationship'] as String).isNotEmpty) score += 5;
    final traits = p['traits'];
    if (traits is List && traits.isNotEmpty) score += traits.length;
    final facts = p['facts'];
    if (facts is List && facts.isNotEmpty) score += facts.length;
    score += (p['message_count'] as int? ?? 0) ~/ 10;
    if (_factsForPerson(p['id'] as String? ?? '').isNotEmpty) score += 5;
    if (_personalityForPerson(p['id'] as String? ?? '').isNotEmpty) score += 10;
    return score;
  }

  List<Map<String, dynamic>> get _richPeople {
    return _people.where((p) => _personRichness(p) >= 5).toList()
      ..sort((a, b) => _personRichness(b).compareTo(_personRichness(a)));
  }

  List<Map<String, dynamic>> get _filteredPeople {
    final source = _showAllPeople ? _people : _richPeople;
    if (_peopleSearch.isEmpty) return source;
    final q = _peopleSearch.toLowerCase();
    return source.where((p) {
      final name = (p['display_name'] ?? '').toString().toLowerCase();
      final rel = (p['relationship'] ?? '').toString().toLowerCase();
      final bio = (p['bio'] ?? '').toString().toLowerCase();
      final nicknames = (p['nicknames'] as List?)?.join(' ').toLowerCase() ?? '';
      return name.contains(q) || rel.contains(q) || bio.contains(q) || nicknames.contains(q);
    }).toList();
  }

  Widget _buildPeopleTab() {
    if (_loadingPeople) return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    if (_pplError != null) return Center(child: Text('Error: $_pplError', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)));
    if (_people.isEmpty) return Center(child: Text('No people found', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)));

    final filtered = _filteredPeople;

    return Column(
      children: [
        // Search bar
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Container(
            height: 32,
            decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
            child: TextField(
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              decoration: InputDecoration(
                hintText: 'Search people by name, relationship, bio...',
                hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                prefixIcon: const Icon(Icons.search, size: 14, color: HackerTheme.dimText),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _peopleSearch = v),
            ),
          ),
        ),
        // Stats + toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Text(
                _showAllPeople
                    ? '${filtered.length} of ${_people.length} people'
                    : '${filtered.length} profiled of ${_people.length}',
                style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _showAllPeople = !_showAllPeople),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: _showAllPeople ? HackerTheme.amber : HackerTheme.borderDim),
                  ),
                  child: Text(
                    _showAllPeople ? 'PROFILED ONLY' : 'VIEW ALL ${_people.length}',
                    style: HackerTheme.monoNoGlow(size: 7, color: _showAllPeople ? HackerTheme.amber : HackerTheme.dimText),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: HackerTheme.green,
            backgroundColor: HackerTheme.bgCard,
            onRefresh: _loadPeople,
            child: filtered.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    Center(child: Text(
                      _peopleSearch.isNotEmpty ? 'No matches for "$_peopleSearch"' : 'No profiled people yet',
                      style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText),
                    )),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final person = filtered[i];
                      return _personCard(person, onTap: () => _showPersonDetail(person));
                    },
                  ),
          ),
        ),
      ],
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
    final fullName = (person['full_name'] ?? '').toString();
    final kind = person['kind'] ?? '';
    final relationship = (person['relationship'] ?? '').toString();
    final bio = (person['bio'] ?? '').toString();
    final notes = person['notes'] ?? '';
    final identifiers = person['identifiers'];
    final nicknames = person['nicknames'] as List? ?? [];
    final inlineTraits = person['traits'] as List? ?? [];
    final inlineFacts = person['facts'] as List? ?? [];
    final languages = person['languages'] as List? ?? [];
    final phone = (person['phone'] ?? '').toString();
    final pushName = (person['push_name'] ?? '').toString();
    final msgCount = person['message_count'] as int? ?? 0;
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

    final kindColor = _relationshipColor(relationship, kind.toString());

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
                          if (relationship.isNotEmpty) ...[
                            Text(relationship, style: HackerTheme.monoNoGlow(size: 9, color: kindColor)),
                            const SizedBox(width: 8),
                          ] else if (kind.toString().isNotEmpty) ...[
                            Text(kind.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)),
                            const SizedBox(width: 8),
                          ],
                          if (inlineTraits.isNotEmpty) Text('${inlineTraits.length} traits', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                          if (inlineFacts.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text('${inlineFacts.length} facts', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.amber)),
                          ],
                          if (personFacts.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text('+${personFacts.length} db', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey)),
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
                  // Identity summary
                  if (bio.isNotEmpty || fullName.isNotEmpty || relationship.isNotEmpty) ...[
                    _detailSection('PROFILE'),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border(left: BorderSide(color: kindColor, width: 2))),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (fullName.isNotEmpty)
                            Text(fullName, style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white)),
                          if (relationship.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(relationship.toUpperCase(), style: HackerTheme.monoNoGlow(size: 9, color: kindColor)),
                            ),
                          if (bio.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(bio, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.grey)),
                            ),
                          if (msgCount > 0 || phone.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(children: [
                                if (phone.isNotEmpty) Text('+$phone', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                                if (phone.isNotEmpty && msgCount > 0) const SizedBox(width: 12),
                                if (msgCount > 0) Text('$msgCount messages tracked', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                              ]),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Nicknames & Languages
                  if (nicknames.isNotEmpty || languages.isNotEmpty) ...[
                    if (nicknames.isNotEmpty) ...[
                      _detailSection('ALSO KNOWN AS'),
                      Wrap(spacing: 6, runSpacing: 4, children: nicknames.map<Widget>((n) =>
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(border: Border.all(color: HackerTheme.borderDim)),
                          child: Text(n.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.white)),
                        ),
                      ).toList()),
                      const SizedBox(height: 8),
                    ],
                    if (languages.isNotEmpty) ...[
                      _detailSection('LANGUAGES'),
                      Wrap(spacing: 6, children: languages.map<Widget>((l) {
                        final langName = switch(l.toString()) { 'ms' => 'Malay', 'en' => 'English', 'id' => 'Indonesian', 'zh' => 'Chinese', 'ar' => 'Arabic', _ => l.toString() };
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(border: Border.all(color: HackerTheme.cyan.withValues(alpha: 0.3))),
                          child: Text(langName, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.cyan)),
                        );
                      }).toList()),
                      const SizedBox(height: 12),
                    ],
                  ],

                  // Traits (from people.traits column)
                  if (inlineTraits.isNotEmpty) ...[
                    _detailSection('PERSONALITY TRAITS (${inlineTraits.length})'),
                    Wrap(spacing: 6, runSpacing: 4, children: inlineTraits.map<Widget>((t) =>
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(border: Border.all(color: HackerTheme.green.withValues(alpha: 0.3)), color: HackerTheme.bgCard),
                        child: Text(t.toString(), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.green)),
                      ),
                    ).toList()),
                    const SizedBox(height: 12),
                  ],

                  // Personality profile (from personality table — visual bars)
                  if (hasPersonality) ...[
                    _detailSection('PERSONALITY PROFILE'),
                    ...personalityDims.entries.map((entry) => _buildDimensionCard(entry.key, entry.value)),
                    const SizedBox(height: 12),
                  ],

                  // Facts (from people.facts column)
                  if (inlineFacts.isNotEmpty) ...[
                    _detailSection('KNOWN FACTS (${inlineFacts.length})'),
                    ...inlineFacts.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('> ', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.amber)),
                          Expanded(child: Text(f.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white))),
                        ],
                      ),
                    )),
                    const SizedBox(height: 12),
                  ],

                  // Facts from facts table (grouped by category)
                  if (personFacts.isNotEmpty) ...[
                    _detailSection('STRUCTURED FACTS (${personFacts.length})'),
                    ...factsByCategory.entries.map((entry) => _buildFactCategory(entry.key, entry.value)),
                    const SizedBox(height: 12),
                  ],

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
                    const SizedBox(height: 12),
                  ],

                  // Notes
                  if (notes.toString().isNotEmpty) ...[
                    _detailSection('NOTES'),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: HackerTheme.terminalBox(),
                      child: Text(notes.toString(), style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
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
    final memId = mem['id']?.toString();
    final mediaId = mem['media_id']?.toString();
    final media = (mediaId != null && mediaId.isNotEmpty) ? _mediaById[mediaId] : null;
    final highlighted = memId != null && memId == _highlightMemoryId;

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
        color: highlighted ? HackerTheme.greenDim : HackerTheme.bgCard,
        border: Border(
          left: BorderSide(color: catColor, width: 2),
          top: highlighted ? const BorderSide(color: HackerTheme.green) : BorderSide.none,
          right: highlighted ? const BorderSide(color: HackerTheme.green) : BorderSide.none,
          bottom: highlighted ? const BorderSide(color: HackerTheme.green) : BorderSide.none,
        ),
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
          if (mediaId != null && mediaId.isNotEmpty) ...[
            const SizedBox(height: 6),
            _memoryMediaBadge(media, mediaId),
          ],
        ],
      ),
    );
  }

  Widget _memoryMediaBadge(Map<String, dynamic>? media, String mediaId) {
    final kind = (media?['kind'] ?? '').toString();
    final transcript = (media?['transcript'] ?? '').toString();
    final caption = (media?['caption'] ?? '').toString();
    final snippet = transcript.isNotEmpty ? transcript : caption;

    final color = switch (kind) {
      'image' => HackerTheme.cyan,
      'audio' => HackerTheme.amber,
      'video' => const Color(0xFFFF00FF),
      _ => HackerTheme.grey,
    };
    final icon = switch (kind) {
      'image' => Icons.image_outlined,
      'audio' => Icons.audiotrack,
      'video' => Icons.videocam_outlined,
      _ => Icons.attachment,
    };
    final label = kind.isEmpty ? 'media' : kind.toUpperCase();

    return GestureDetector(
      onTap: () => _jumpToMediaForMemory(mediaId, snippet),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: color.withValues(alpha: 0.5))),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(label, style: HackerTheme.monoNoGlow(size: 8, color: color)),
            if (snippet.isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  snippet.length > 60 ? '${snippet.substring(0, 60)}...' : snippet,
                  style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 10, color: HackerTheme.dimText),
          ],
        ),
      ),
    );
  }

  // Memory → MEDIA tab navigation. Uses transcript/caption snippet as the
  // semantic-search prefill so the linked media appears at the top of results.
  void _jumpToMediaForMemory(String mediaId, String snippet) {
    if (snippet.isNotEmpty) {
      _mediaSearchCtrl.text = snippet.length > 100 ? snippet.substring(0, 100) : snippet;
    }
    _tabCtrl.animateTo(3); // MEDIA sub-tab
    if (!_mediaLoadedOnce) {
      _mediaLoadedOnce = true;
    }
    _loadMedia();
  }

  Color _relationshipColor(String? relationship, String? kind) {
    if (kind == 'self') return HackerTheme.green;
    if (kind == 'group') return HackerTheme.amber;
    return switch (relationship?.toLowerCase() ?? '') {
      'self' => HackerTheme.green,
      'best friend' => const Color(0xFFFF00FF),
      'family' => HackerTheme.green,
      'ex-wife' => const Color(0xFFFF6B6B),
      'friend' => HackerTheme.amber,
      'employee' => HackerTheme.cyan,
      'colleague' => HackerTheme.cyan,
      'business partner' => HackerTheme.cyan,
      'client' => HackerTheme.grey,
      'acquaintance' => HackerTheme.dimText,
      _ => HackerTheme.white,
    };
  }

  Widget _personCard(Map<String, dynamic> person, {VoidCallback? onTap}) {
    final name = person['display_name'] ?? 'Unknown';
    final kind = person['kind'] ?? '';
    final relationship = (person['relationship'] ?? '').toString();
    final bio = (person['bio'] ?? '').toString();
    final personId = person['id'] as String?;
    final personFacts = personId != null ? _factsForPerson(personId) : <Map<String, dynamic>>[];
    final hasTraits = personId != null && _personalityForPerson(personId).isNotEmpty;
    final traits = person['traits'];
    final facts = person['facts'];
    final hasBio = bio.isNotEmpty;
    final hasInlineTraits = traits is List && traits.isNotEmpty;
    final hasInlineFacts = facts is List && facts.isNotEmpty;
    final richness = _personRichness(person);

    final nodeColor = _relationshipColor(relationship, kind.toString());
    final relLabel = relationship.isNotEmpty ? relationship : kind.toString();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: nodeColor, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: nodeColor, shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: nodeColor.withValues(alpha: 0.4), blurRadius: 4)]),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(name.toString(), style: HackerTheme.monoNoGlow(size: 12, color: nodeColor))),
              if (relLabel.isNotEmpty) Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: nodeColor.withValues(alpha: 0.5))),
                child: Text(relLabel.toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: nodeColor)),
              ),
              if (hasTraits || hasInlineTraits) ...[
                const SizedBox(width: 6),
                const Icon(Icons.psychology_outlined, size: 14, color: HackerTheme.cyan),
              ],
              if (hasInlineFacts || personFacts.isNotEmpty) ...[
                const SizedBox(width: 4),
                Icon(Icons.fact_check_outlined, size: 12, color: HackerTheme.amber.withValues(alpha: 0.7)),
              ],
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, size: 14, color: HackerTheme.dimText),
            ]),
            if (hasBio) ...[
              const SizedBox(height: 4),
              Text(bio.length > 100 ? '${bio.substring(0, 100)}...' : bio,
                style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
            ],
            if (hasInlineTraits) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 2, children: (traits as List).take(5).map<Widget>((t) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: HackerTheme.borderDim)),
                  child: Text(t.toString(), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                );
              }).toList()),
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

  // ══════════════════════════════════════════════════
  // TAB 4: MEDIA — backed by /api/siti/api/media
  // ══════════════════════════════════════════════════

  Future<void> _loadMedia() async {
    if (mounted) setState(() { _loadingMedia = true; _mediaError = null; });
    try {
      final params = <String, String>{'limit': '60'};
      if (_mediaKind != 'all') params['kind'] = _mediaKind;
      final q = _mediaSearchCtrl.text.trim();
      if (q.isNotEmpty) params['q'] = q;
      final uri = Uri.parse('${AppConfig.apiBaseUrl}/api/siti/api/media').replace(queryParameters: params);
      final res = await http.get(uri, headers: {
        'Authorization': 'Bearer ${AppConfig.authToken}',
      }).timeout(const Duration(seconds: 25));
      if (res.statusCode >= 400) {
        String msg = 'HTTP ${res.statusCode}';
        try { final j = jsonDecode(res.body); if (j is Map && j['error'] != null) msg = j['error'].toString(); } catch (_) {}
        if (mounted) setState(() { _loadingMedia = false; _mediaError = msg; });
        return;
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) setState(() {
        _media = List<Map<String, dynamic>>.from(body['media'] ?? const []);
        _mediaMode = body['mode']?.toString() ?? 'browse';
        _loadingMedia = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loadingMedia = false; _mediaError = e.toString(); });
    }
  }

  Widget _buildMediaTab() {
    return Column(
      children: [
        // Search bar
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Container(
            height: 32,
            decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
            child: TextField(
              controller: _mediaSearchCtrl,
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              decoration: InputDecoration(
                hintText: 'Semantic search transcripts & captions...',
                hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                prefixIcon: const Icon(Icons.search, size: 14, color: HackerTheme.dimText),
                suffixIcon: _mediaSearchCtrl.text.isEmpty
                    ? null
                    : GestureDetector(
                        onTap: () { _mediaSearchCtrl.clear(); _loadMedia(); },
                        child: const Icon(Icons.close, size: 14, color: HackerTheme.dimText),
                      ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
              onSubmitted: (_) => _loadMedia(),
            ),
          ),
        ),
        // Kind filter chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              for (final k in const ['all', 'image', 'audio', 'video']) ...[
                _kindChip(k),
                const SizedBox(width: 6),
              ],
              const Spacer(),
              if (_mediaMode == 'search')
                Text('SEMANTIC', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.cyan))
              else
                Text('${_media.length} items', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            ],
          ),
        ),
        Expanded(child: _buildMediaList()),
      ],
    );
  }

  Widget _kindChip(String kind) {
    final selected = _mediaKind == kind;
    final color = selected ? HackerTheme.amber : HackerTheme.dimText;
    return GestureDetector(
      onTap: () {
        if (_mediaKind == kind) return;
        setState(() => _mediaKind = kind);
        _loadMedia();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(border: Border.all(color: color)),
        child: Text(kind.toUpperCase(), style: HackerTheme.monoNoGlow(size: 8, color: color)),
      ),
    );
  }

  Widget _buildMediaList() {
    if (_loadingMedia) return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    if (_mediaError != null) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('media error', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
          const SizedBox(height: 6),
          Text(_mediaError!, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _loadMedia,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
              child: Text('RETRY', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.green)),
            ),
          ),
        ]),
      ));
    }
    if (_media.isEmpty) {
      return Center(child: Text(
        _mediaSearchCtrl.text.trim().isNotEmpty ? 'No matches' : 'No media yet',
        style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText),
      ));
    }
    return RefreshIndicator(
      color: HackerTheme.green,
      backgroundColor: HackerTheme.bgCard,
      onRefresh: _loadMedia,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        itemCount: _media.length,
        itemBuilder: (ctx, i) => _mediaCard(_media[i]),
      ),
    );
  }

  Widget _mediaCard(Map<String, dynamic> m) {
    final kind = (m['kind'] ?? '').toString();
    final mime = (m['mime_type'] ?? '').toString();
    final transcript = (m['transcript'] ?? '').toString();
    final caption = (m['caption'] ?? '').toString();
    final personName = (m['person_name'] ?? '').toString();
    final source = (m['source'] ?? '').toString();
    // Use NACA's HTTPS proxy for image bytes — avoids mixed-content (Siti's
    // signed_url points at http://100.85.18.97:9000/... which Chrome blocks).
    final mediaId = (m['id'] ?? '').toString();
    final blobUrl = mediaId.isNotEmpty ? '${AppConfig.apiBaseUrl}/api/media/$mediaId/blob' : '';
    final signedUrl = (m['signed_url'] ?? '').toString();
    final bytes = (m['bytes'] is num) ? (m['bytes'] as num).toInt() : 0;
    final createdAt = m['created_at']?.toString();
    final similarity = m['similarity'];

    final kindColor = switch (kind) {
      'image' => HackerTheme.cyan,
      'audio' => HackerTheme.amber,
      'video' => const Color(0xFFFF00FF),
      _ => HackerTheme.grey,
    };
    final kindIcon = switch (kind) {
      'image' => Icons.image_outlined,
      'audio' => Icons.audiotrack,
      'video' => Icons.videocam_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

    final body = transcript.isNotEmpty ? transcript : caption;
    final hasSigned = signedUrl.isNotEmpty;

    return GestureDetector(
      onTap: hasSigned ? () => _openMedia(m) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: kindColor, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Row(children: [
                Icon(kindIcon, size: 14, color: kindColor),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: kindColor.withValues(alpha: 0.5))),
                  child: Text(kind.toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: kindColor)),
                ),
                if (mime.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(mime, style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                ],
                const Spacer(),
                if (similarity is num) ...[
                  Text('${(similarity * 100).toStringAsFixed(0)}%', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.cyan)),
                  const SizedBox(width: 6),
                ],
                if (bytes > 0) Text(_humanBytes(bytes), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.grey)),
                if (createdAt != null) ...[
                  const SizedBox(width: 6),
                  Text(_timeAgo(DateTime.parse(createdAt)), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.grey)),
                ],
              ]),
            ),
            // Person + source row + source-memory link
            if (personName.isNotEmpty || source.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(children: [
                  if (personName.isNotEmpty) Text('@ $personName', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.green)),
                  if (personName.isNotEmpty && source.isNotEmpty) const SizedBox(width: 8),
                  if (source.isNotEmpty) Text(source, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _jumpToSourceMemory(m['id']?.toString() ?? ''),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.north_east, size: 10, color: HackerTheme.cyan),
                      const SizedBox(width: 2),
                      Text('SOURCE', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.cyan)),
                    ]),
                  ),
                ]),
              ),
            // Image preview — render via NACA blob proxy (HTTPS, no mixed-content)
            if (kind == 'image' && blobUrl.isNotEmpty) Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: ClipRect(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Image.network(
                    blobUrl,
                    headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
                    fit: BoxFit.cover,
                    width: double.infinity,
                    loadingBuilder: (ctx, child, prog) => prog == null
                        ? child
                        : Container(
                            height: 80,
                            alignment: Alignment.center,
                            child: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: HackerTheme.green)),
                          ),
                    errorBuilder: (ctx, _, __) => Container(
                      height: 80,
                      alignment: Alignment.center,
                      child: Text('image load failed', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red)),
                    ),
                  ),
                ),
              ),
            ),
            // Text body (transcript or caption)
            if (body.isNotEmpty) Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Text(
                body.length > 280 ? '${body.substring(0, 280)}...' : body,
                style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              ),
            )
            else const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // MEDIA → MEMORIES navigation. Looks up the memory whose media_id matches
  // this row's id, prepends to _memories if it isn't visible, then switches to
  // MEMORIES sub-tab and highlights the row.
  Future<void> _jumpToSourceMemory(String mediaId) async {
    if (mediaId.isEmpty) return;
    try {
      final mem = await _sb.from('memories')
          .select('id, content, category, memory_type, importance, source, created_at, media_id')
          .eq('media_id', mediaId)
          .maybeSingle();
      if (mem == null) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No source memory found for this media'), backgroundColor: HackerTheme.amber),
        );
        return;
      }
      final memMap = Map<String, dynamic>.from(mem);
      final memId = memMap['id']?.toString();
      if (mounted) setState(() {
        // If this memory isn't already in the list, prepend it
        if (memId != null && !_memories.any((x) => x['id']?.toString() == memId)) {
          _memories = [memMap, ..._memories];
        }
        _highlightMemoryId = memId;
      });
      _tabCtrl.animateTo(0); // MEMORIES sub-tab
      // Clear highlight after a few seconds so the visual fades
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted && _highlightMemoryId == memId) setState(() => _highlightMemoryId = null);
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Source lookup failed: $e'), backgroundColor: HackerTheme.red),
      );
    }
  }

  void _openMedia(Map<String, dynamic> m) {
    final kind = (m['kind'] ?? '').toString();
    final mediaId = (m['id'] ?? '').toString();
    if (mediaId.isEmpty) return;
    if (kind == 'image') {
      _showImageViewer(m);
    } else {
      // For audio/video, opening the raw signed_url externally still works
      // since the system browser/player isn't bound by HTTPS-page rules.
      // Fall back to NACA blob URL if signed_url missing.
      final url = (m['signed_url'] ?? '').toString();
      _launchExternal(url.isNotEmpty ? url : '${AppConfig.apiBaseUrl}/api/media/$mediaId/blob');
    }
  }

  Future<void> _launchExternal(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open media URL'), backgroundColor: HackerTheme.red),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open failed: $e'), backgroundColor: HackerTheme.red),
      );
    }
  }

  void _showImageViewer(Map<String, dynamic> m) {
    final mediaId = (m['id'] ?? '').toString();
    // Use NACA blob proxy for inline render (HTTPS, browser-safe)
    final url = mediaId.isNotEmpty ? '${AppConfig.apiBaseUrl}/api/media/$mediaId/blob' : (m['signed_url'] ?? '').toString();
    final externalUrl = (m['signed_url'] ?? '').toString(); // for "open in new tab" — that one can be the raw signed URL
    final caption = (m['caption'] ?? '').toString();
    final personName = (m['person_name'] ?? '').toString();
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => Dialog(
        backgroundColor: HackerTheme.bgPanel,
        insetPadding: const EdgeInsets.all(12),
        shape: const RoundedRectangleBorder(
          side: BorderSide(color: HackerTheme.borderDim),
          borderRadius: BorderRadius.zero,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: HackerTheme.borderDim)),
              ),
              child: Row(children: [
                const Icon(Icons.image_outlined, size: 14, color: HackerTheme.cyan),
                const SizedBox(width: 6),
                Expanded(child: Text(
                  personName.isNotEmpty ? '@ $personName' : 'image',
                  style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.cyan),
                )),
                GestureDetector(
                  onTap: () => _launchExternal(externalUrl.isNotEmpty ? externalUrl : url),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.open_in_new, size: 16, color: HackerTheme.green),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(),
                  child: const Icon(Icons.close, size: 16, color: HackerTheme.dimText),
                ),
              ]),
            ),
            Flexible(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Image.network(
                  url,
                  headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
                  fit: BoxFit.contain,
                  errorBuilder: (ctx, _, __) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('image load failed', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red)),
                  ),
                ),
              ),
            ),
            if (caption.isNotEmpty) Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: HackerTheme.borderDim)),
              ),
              child: Text(caption, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white)),
            ),
          ],
        ),
      ),
    );
  }

  String _humanBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)}MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }
}
