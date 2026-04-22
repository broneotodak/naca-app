import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

/// Memory viewer — browse neo-brain memories, people, facts
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
          .select('id, display_name, kind, notes, identifiers, metadata, created_at')
          .order('updated_at', ascending: false)
          .limit(50);
      // Also load facts
      final factsData = await _sb.from('facts')
          .select('id, subject_id, fact, category, confidence, created_at')
          .order('created_at', ascending: false)
          .limit(100);
      if (mounted) setState(() {
        _people = List<Map<String, dynamic>>.from(ppl);
        _facts = List<Map<String, dynamic>>.from(factsData);
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
      final data = await _sb.from('memories')
          .select('id, content, category, memory_type, importance, source, created_at')
          .ilike('content', '%$query%')
          .order('created_at', ascending: false)
          .limit(20);
      if (mounted) setState(() { _searchResults = List<Map<String, dynamic>>.from(data); _searching = false; });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  List<Map<String, dynamic>> _factsForPerson(String personId) {
    return _facts.where((f) => f['subject_id'] == personId).toList();
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
                hintText: 'Search neo-brain...',
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
        itemBuilder: (ctx, i) => _personCard(_people[i]),
      ),
    );
  }

  Widget _buildSearchTab() {
    if (_searchResults.isEmpty && !_searching) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.search, size: 48, color: HackerTheme.dimText),
          const SizedBox(height: 8),
          Text('Type a query above', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText)),
        ]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _searchResults.length,
      itemBuilder: (ctx, i) => _memoryCard(_searchResults[i]),
    );
  }

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

  Widget _personCard(Map<String, dynamic> person) {
    final name = person['display_name'] ?? 'Unknown';
    final kind = person['kind'] ?? '';
    final notes = person['notes'] ?? '';
    final identifiers = person['identifiers'];
    final personId = person['id'] as String?;
    final personFacts = personId != null ? _factsForPerson(personId) : <Map<String, dynamic>>[];

    final kindColor = switch (kind.toString()) {
      'self' => HackerTheme.green,
      'bot' => HackerTheme.cyan,
      'group' => HackerTheme.amber,
      _ => HackerTheme.white,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: HackerTheme.terminalBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(name.toString(), style: HackerTheme.monoNoGlow(size: 12, color: kindColor)),
            if (kind.toString().isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(border: Border.all(color: kindColor.withValues(alpha: 0.5))),
                child: Text(kind.toString().toUpperCase(), style: HackerTheme.monoNoGlow(size: 7, color: kindColor)),
              ),
            ],
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
          if (personFacts.isNotEmpty) ...[
            const SizedBox(height: 4),
            ...personFacts.take(4).map((f) => Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Text('• ${f['fact']}', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.grey), overflow: TextOverflow.ellipsis),
            )),
            if (personFacts.length > 4) Text('+${personFacts.length - 4} more', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
          ],
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
