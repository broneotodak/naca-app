import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../config.dart';
import '../theme.dart';

/// WORKSPACE — Google Workspace browser via NACA's GAM gateway.
/// Three sub-tabs: DRIVES (257), USERS (434), FILES (search Drive).
/// All data flows through https://naca.neotodak.com/api/gam/* — Siti's
/// tools call the same endpoints (Phase 4b Step 1B).
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({super.key});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  // DRIVES state
  List<Map<String, dynamic>> _drives = [];
  bool _drivesLoading = false;
  String? _drivesError;
  bool _drivesLoaded = false;
  String _drivesSearch = '';

  // USERS state
  List<Map<String, dynamic>> _users = [];
  bool _usersLoading = false;
  String? _usersError;
  final _usersCtrl = TextEditingController();

  // FILES state
  List<Map<String, dynamic>> _files = [];
  bool _filesLoading = false;
  String? _filesError;
  final _filesCtrl = TextEditingController();
  String _filesUser = 'neo@todak.com';
  int? _filesMs;

  // Health
  bool? _gamHealthy;
  int? _gamHealthMs;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _checkHealth();
    _tabCtrl.addListener(() {
      // Lazy load on tab switch
      if (_tabCtrl.index == 0 && !_drivesLoaded) _loadDrives();
    });
    _loadDrives(); // Default tab is DRIVES
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _usersCtrl.dispose();
    _filesCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/gam/health'),
        headers: {'Authorization': 'Bearer ${AppConfig.authToken}'},
      ).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (mounted) setState(() {
        _gamHealthy = body['ok'] == true;
        _gamHealthMs = body['ms'] is int ? body['ms'] as int : null;
      });
    } catch (_) {
      if (mounted) setState(() => _gamHealthy = false);
    }
  }

  Future<Map<String, dynamic>?> _gamGet(String path, {Map<String, String>? params}) async {
    try {
      final uri = Uri.parse('${AppConfig.apiBaseUrl}$path').replace(queryParameters: params);
      final res = await http.get(uri, headers: {
        'Authorization': 'Bearer ${AppConfig.authToken}',
        'x-requested-by': 'naca-ui',
      }).timeout(const Duration(seconds: 30));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode >= 400) return {'_error': body['error'] ?? 'HTTP ${res.statusCode}'};
      return body;
    } catch (e) {
      return {'_error': e.toString()};
    }
  }

  // ─── DRIVES ───────────────────────────────────────────────────────

  Future<void> _loadDrives() async {
    if (mounted) setState(() { _drivesLoading = true; _drivesError = null; });
    final body = await _gamGet('/api/gam/shareddrives');
    if (body == null || body['_error'] != null) {
      if (mounted) setState(() {
        _drivesLoading = false;
        _drivesError = body?['_error']?.toString() ?? 'failed';
        _drivesLoaded = true;
      });
      return;
    }
    if (mounted) setState(() {
      _drives = List<Map<String, dynamic>>.from(body['drives'] ?? const []);
      _drivesLoading = false;
      _drivesLoaded = true;
      _drivesError = null;
    });
  }

  // ─── USERS ────────────────────────────────────────────────────────

  Future<void> _searchUsers() async {
    final q = _usersCtrl.text.trim();
    if (q.isEmpty) { if (mounted) setState(() => _users = []); return; }
    if (mounted) setState(() { _usersLoading = true; _usersError = null; });
    final body = await _gamGet('/api/gam/users', params: {'q': q});
    if (body?['_error'] != null) {
      if (mounted) setState(() { _usersLoading = false; _usersError = body!['_error'].toString(); });
      return;
    }
    if (mounted) setState(() {
      _users = List<Map<String, dynamic>>.from(body?['users'] ?? const []);
      _usersLoading = false;
      _usersError = null;
    });
  }

  // ─── FILES ────────────────────────────────────────────────────────

  Future<void> _searchFiles() async {
    final q = _filesCtrl.text.trim();
    if (q.isEmpty) { if (mounted) setState(() => _files = []); return; }
    if (mounted) setState(() { _filesLoading = true; _filesError = null; });
    final body = await _gamGet('/api/gam/files', params: {'q': q, 'user': _filesUser});
    if (body?['_error'] != null) {
      if (mounted) setState(() { _filesLoading = false; _filesError = body!['_error'].toString(); });
      return;
    }
    if (mounted) setState(() {
      _files = List<Map<String, dynamic>>.from(body?['files'] ?? const []);
      _filesLoading = false;
      _filesMs = body?['ms'] is int ? body!['ms'] as int : null;
      _filesError = null;
    });
  }

  Future<void> _openWebLink(String url) async {
    if (url.isEmpty) return;
    try { await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(),
          TabBar(
            controller: _tabCtrl,
            indicatorColor: HackerTheme.cyan,
            labelColor: HackerTheme.cyan,
            unselectedLabelColor: HackerTheme.dimText,
            labelStyle: HackerTheme.monoNoGlow(size: 10),
            tabs: const [
              Tab(text: 'DRIVES'),
              Tab(text: 'USERS'),
              Tab(text: 'FILES'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: [
                _buildDrivesTab(),
                _buildUsersTab(),
                _buildFilesTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final healthDot = _gamHealthy == null
        ? const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5, color: HackerTheme.dimText))
        : Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              color: _gamHealthy! ? HackerTheme.green : HackerTheme.red,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: (_gamHealthy! ? HackerTheme.green : HackerTheme.red).withValues(alpha: 0.5), blurRadius: 6)],
            ),
          );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: HackerTheme.bgPanel,
        border: Border(bottom: BorderSide(color: HackerTheme.borderDim)),
      ),
      child: Row(children: [
        Text('NACA://', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
        Text('workspace', style: HackerTheme.mono(size: 14, color: HackerTheme.dimText)),
        const SizedBox(width: 10),
        healthDot,
        const SizedBox(width: 4),
        Text(_gamHealthy == null ? 'checking' : (_gamHealthy! ? 'gam:ok ${_gamHealthMs ?? '?'}ms' : 'gam:DOWN'),
            style: HackerTheme.monoNoGlow(size: 8, color: _gamHealthy == false ? HackerTheme.red : HackerTheme.dimText)),
        const Spacer(),
        Text('via TDCC + neo@todak.com', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
      ]),
    );
  }

  // ──────────────────────── DRIVES ────────────────────────

  Widget _buildDrivesTab() {
    if (_drivesLoading) return const Center(child: CircularProgressIndicator(color: HackerTheme.green));
    if (_drivesError != null) return _errorBox(_drivesError!, _loadDrives);
    final filtered = _drivesSearch.isEmpty
        ? _drives
        : _drives.where((d) => (d['name']?.toString().toLowerCase() ?? '').contains(_drivesSearch.toLowerCase())).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Container(
            height: 32,
            decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
            child: TextField(
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              decoration: InputDecoration(
                hintText: 'Filter ${_drives.length} shared drives by name…',
                hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                prefixIcon: const Icon(Icons.search, size: 14, color: HackerTheme.dimText),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _drivesSearch = v),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            Text('${filtered.length} of ${_drives.length}', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            color: HackerTheme.green,
            backgroundColor: HackerTheme.bgCard,
            onRefresh: _loadDrives,
            child: filtered.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    Center(child: Text(_drivesSearch.isEmpty ? 'No drives' : 'No match',
                        style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText))),
                  ])
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final d = filtered[i];
                      final name = d['name']?.toString() ?? '?';
                      final id = d['id']?.toString() ?? '';
                      return GestureDetector(
                        onTap: () => _openWebLink('https://drive.google.com/drive/folders/$id'),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: HackerTheme.bgCard,
                            border: const Border(left: BorderSide(color: HackerTheme.cyan, width: 2)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.folder_shared_outlined, size: 14, color: HackerTheme.cyan),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white)),
                                  const SizedBox(height: 2),
                                  Text(id, style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                                ],
                              ),
                            ),
                            const Icon(Icons.open_in_new, size: 12, color: HackerTheme.dimText),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // ──────────────────────── USERS ────────────────────────

  Widget _buildUsersTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Container(
            height: 32,
            decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
            child: TextField(
              controller: _usersCtrl,
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              decoration: InputDecoration(
                hintText: 'Email prefix (e.g. neo, lan, kamiera)…',
                hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                prefixIcon: const Icon(Icons.search, size: 14, color: HackerTheme.dimText),
                suffixIcon: _usersLoading
                    ? const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: HackerTheme.green)))
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
              onSubmitted: (_) => _searchUsers(),
            ),
          ),
        ),
        if (_usersError != null) Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Text(_usersError!, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red)),
        ),
        Expanded(
          child: _users.isEmpty && !_usersLoading
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _usersCtrl.text.isEmpty ? 'Type an email prefix and press Enter\nto search 434 Workspace users' : 'No users match "${_usersCtrl.text}"',
                      style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _users.length,
                  itemBuilder: (ctx, i) {
                    final u = _users[i];
                    final email = u['primaryEmail']?.toString() ?? '?';
                    final fullName = u['name.fullName']?.toString() ?? u['name']?.toString() ?? '';
                    final ou = u['orgUnitPath']?.toString() ?? '';
                    final isAdmin = u['isAdmin']?.toString() == 'True';
                    final isSuspended = u['suspended']?.toString() == 'True';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: HackerTheme.bgCard,
                        border: Border(left: BorderSide(color: isSuspended ? HackerTheme.red : (isAdmin ? HackerTheme.amber : HackerTheme.cyan), width: 2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.person_outline, size: 14, color: HackerTheme.cyan),
                            const SizedBox(width: 6),
                            Expanded(child: Text(email, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white))),
                            if (isAdmin) Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(border: Border.all(color: HackerTheme.amber)),
                              child: Text('ADMIN', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.amber)),
                            ),
                            if (isSuspended) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(border: Border.all(color: HackerTheme.red)),
                                child: Text('SUSP', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.red)),
                              ),
                            ],
                          ]),
                          if (fullName.isNotEmpty || ou.isNotEmpty) Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(children: [
                              if (fullName.isNotEmpty) Text(fullName, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.grey)),
                              if (fullName.isNotEmpty && ou.isNotEmpty) const SizedBox(width: 8),
                              if (ou.isNotEmpty) Text(ou, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
                            ]),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // ──────────────────────── FILES ────────────────────────

  Widget _buildFilesTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Container(
            height: 32,
            decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
            child: TextField(
              controller: _filesCtrl,
              style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.white),
              decoration: InputDecoration(
                hintText: 'Search Drive — name or content keyword…',
                hintStyle: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                prefixIcon: const Icon(Icons.search, size: 14, color: HackerTheme.dimText),
                suffixIcon: _filesLoading
                    ? const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: HackerTheme.green)))
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                isDense: true,
              ),
              onSubmitted: (_) => _searchFiles(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            Text('searching as:', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            const SizedBox(width: 6),
            Text(_filesUser, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
            const Spacer(),
            if (_filesMs != null) Text('${_filesMs}ms', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            if (_files.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text('${_files.length} files', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            ],
          ]),
        ),
        if (_filesError != null) Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Text(_filesError!, style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.red)),
        ),
        Expanded(
          child: _files.isEmpty && !_filesLoading
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _filesCtrl.text.isEmpty
                          ? 'Type a keyword and press Enter\nto search Drive content + filenames'
                          : 'No files match "${_filesCtrl.text}"',
                      style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _files.length,
                  itemBuilder: (ctx, i) => _fileCard(_files[i]),
                ),
        ),
      ],
    );
  }

  Widget _fileCard(Map<String, dynamic> f) {
    final id = f['id']?.toString() ?? '';
    final name = f['name']?.toString() ?? '?';
    final mime = f['mimeType']?.toString() ?? '';
    final size = f['size']?.toString() ?? '';
    final modified = f['modifiedTime']?.toString() ?? '';
    final webViewLink = f['webViewLink']?.toString() ?? '';
    final isFolder = mime == 'application/vnd.google-apps.folder';
    final icon = _mimeIcon(mime);
    final color = isFolder ? HackerTheme.amber : HackerTheme.cyan;
    return GestureDetector(
      onTap: () => _openWebLink(webViewLink.isNotEmpty ? webViewLink : 'https://drive.google.com/file/d/$id/view'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: HackerTheme.bgCard,
          border: Border(left: BorderSide(color: color, width: 2)),
        ),
        child: Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.white), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(children: [
                  Text(_shortMime(mime), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.dimText)),
                  if (size.isNotEmpty && size != '0') ...[
                    const SizedBox(width: 6),
                    Text(_humanBytes(int.tryParse(size) ?? 0), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.grey)),
                  ],
                  if (modified.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(modified.substring(0, 10), style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.grey)),
                  ],
                ]),
              ],
            ),
          ),
          const Icon(Icons.open_in_new, size: 12, color: HackerTheme.dimText),
        ]),
      ),
    );
  }

  IconData _mimeIcon(String mime) {
    if (mime.contains('folder')) return Icons.folder_outlined;
    if (mime.contains('image')) return Icons.image_outlined;
    if (mime.contains('video')) return Icons.videocam_outlined;
    if (mime.contains('audio')) return Icons.audiotrack;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.contains('document')) return Icons.description_outlined;
    if (mime.contains('spreadsheet')) return Icons.grid_on_outlined;
    if (mime.contains('presentation')) return Icons.slideshow_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _shortMime(String mime) {
    if (mime.startsWith('application/vnd.google-apps.')) return 'g/' + mime.substring('application/vnd.google-apps.'.length);
    if (mime.contains('/')) return mime.split('/').last;
    return mime;
  }

  String _humanBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)}KB';
    if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)}MB';
    return '${(b / 1073741824).toStringAsFixed(2)}GB';
  }

  Widget _errorBox(String err, VoidCallback retry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 32, color: HackerTheme.red),
          const SizedBox(height: 8),
          Text(err, style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.red), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: retry,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
              child: Text('RETRY', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.green)),
            ),
          ),
        ]),
      ),
    );
  }
}
