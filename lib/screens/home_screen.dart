import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/api_service.dart';
import '../services/ws_service.dart';
import '../services/sound_service.dart';
import '../widgets/scanline_overlay.dart';
import '../widgets/terminal_card.dart';

enum ViewMode { single, split2, quad4 }

class PaneState {
  String? sessionId;
  final List<Map<String, dynamic>> events = [];
  final Map<int, DateTime> timestamps = {};
  final Set<int> expandedTools = {};
  final ScrollController scrollController = ScrollController();
  final TextEditingController promptController = TextEditingController();
  final FocusNode promptFocus = FocusNode();
  final List<String> promptHistory = [];
  bool isProcessing = false;
  bool autoScroll = true;
  int historyIndex = -1;
  String historyDraft = '';
  List<Map<String, dynamic>> attachments = []; // [{filename, serverPath, bytes (Uint8List)}]
  bool isUploading = false;

  void clear() {
    events.clear();
    timestamps.clear();
    expandedTools.clear();
    attachments.clear();
    isProcessing = false;
    isUploading = false;
    autoScroll = true;
    historyIndex = -1;
    historyDraft = '';
  }

  void dispose() {
    scrollController.dispose();
    promptController.dispose();
    promptFocus.dispose();
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  final WsService _ws = WsService();

  List<dynamic> _sessions = [];
  String _serverStatus = 'CONNECTING...';
  bool _serverOnline = false;
  bool _sidebarOpen = false;
  StreamSubscription? _wsSub;
  StreamSubscription? _wsStateSub;
  late AnimationController _cursorController;
  Timer? _sessionRefreshTimer;
  WsState _wsState = WsState.connecting;

  // View mode
  ViewMode _viewMode = ViewMode.single;
  int _focusedPane = 0;
  late List<PaneState> _panes;

  @override
  void initState() {
    super.initState();
    _panes = [PaneState()];
    _cursorController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat();
    _panes[0].scrollController.addListener(() => _onPaneScroll(0));
    _init();
    _sessionRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _loadSessions());
  }

  void _setViewMode(ViewMode mode) {
    if (_viewMode == mode) return;
    final oldCount = _panes.length;
    final newCount = mode == ViewMode.single ? 1 : mode == ViewMode.split2 ? 2 : 4;

    setState(() {
      _viewMode = mode;
      // Add panes if needed
      while (_panes.length < newCount) {
        final p = PaneState();
        final idx = _panes.length;
        p.scrollController.addListener(() => _onPaneScroll(idx));
        _panes.add(p);
      }
      // Remove panes if needed (unsubscribe first)
      while (_panes.length > newCount) {
        final p = _panes.removeLast();
        if (p.sessionId != null) _ws.unsubscribe(p.sessionId!);
        p.dispose();
      }
      if (_focusedPane >= _panes.length) _focusedPane = 0;
    });
  }

  Future<void> _init() async {
    try {
      await ApiService.health();
      setState(() { _serverStatus = 'ONLINE'; _serverOnline = true; });
    } catch (e) {
      setState(() { _serverStatus = 'OFFLINE'; _serverOnline = false; });
    }
    await _loadSessions();
    _ws.connect();
    _wsSub = _ws.events.listen(_onWsEvent);
    _wsStateSub = _ws.stateStream.listen((s) {
      if (mounted) setState(() => _wsState = s);
    });
  }

  void _onPaneScroll(int paneIdx) {
    if (paneIdx >= _panes.length) return;
    final pane = _panes[paneIdx];
    if (!pane.scrollController.hasClients) return;
    final pos = pane.scrollController.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 50;
    if (pane.autoScroll != atBottom) {
      setState(() => pane.autoScroll = atBottom);
    }
  }

  PaneState? _paneForSession(String sessionId) {
    for (final p in _panes) {
      if (p.sessionId == sessionId) return p;
    }
    return null;
  }

  void _onWsEvent(Map<String, dynamic> event) {
    final type = event['type'] ?? '';
    final sessionId = event['sessionId'] as String?;
    if (type == 'ws_disconnected' || type == 'pong' || type == 'subscribed') return;

    // Route event to correct pane
    final pane = sessionId != null ? _paneForSession(sessionId) : null;

    if (type == 'status' && pane != null) {
      final wasProcessing = pane.isProcessing;
      setState(() => pane.isProcessing = event['content'] == 'processing');
      if (event['content'] == 'processing' && !wasProcessing) {
        SoundService.instance.playBuilding();
      }
      if (event['content'] == 'ready') {
        if (wasProcessing) SoundService.instance.playMissionAccomplished();
        _loadSessions();
      }
      return;
    }

    if (type == 'replay' && pane != null) {
      final replayEvents = (event['events'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final filtered = replayEvents.where((e) => e['type'] != 'status').toList();
      setState(() {
        pane.events.clear();
        pane.timestamps.clear();
        pane.events.addAll(filtered);
        for (var i = 0; i < filtered.length; i++) {
          final ts = filtered[i]['timestamp'];
          pane.timestamps[i] = ts != null ? DateTime.fromMillisecondsSinceEpoch(ts as int) : DateTime.now();
        }
        pane.isProcessing = filtered.isNotEmpty && filtered.last['type'] == 'user_message';
      });
      _scrollPaneToBottom(pane);
      return;
    }

    if (pane == null) return;

    if (type == 'error' && (event['content'] ?? '').toString().contains('still processing')) {
      setState(() {
        pane.timestamps[pane.events.length] = DateTime.now();
        pane.events.add({'type': 'system', 'content': 'Claude is still thinking... please wait.'});
      });
    } else {
      setState(() {
        pane.timestamps[pane.events.length] = DateTime.now();
        pane.events.add(event);
        if (type == 'assistant_text') {
          pane.isProcessing = false;
        }
        if (type == 'tool_call') {
          SoundService.instance.playIncomingTransmission();
        }
        if (type == 'error') {
          SoundService.instance.playMissionFailed();
        }
      });
    }
    if (pane.autoScroll) _scrollPaneToBottom(pane);
  }

  Future<void> _loadSessions() async {
    try {
      final s = await ApiService.listSessions();
      if (mounted) setState(() => _sessions = s);
    } catch (_) {}
  }

  void _scrollPaneToBottom(PaneState pane) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (pane.scrollController.hasClients) {
        pane.scrollController.animateTo(pane.scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 100), curve: Curves.easeOut);
      }
    });
  }

  bool _isMobile(BuildContext context) => MediaQuery.of(context).size.width < 768;

  Future<void> _createSession() async {
    final nameCtl = TextEditingController();
    final dirCtl = TextEditingController(text: '/home/openclaw');
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: HackerTheme.bgPanel,
        shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.green)),
        child: Container(
          padding: const EdgeInsets.all(20), constraints: const BoxConstraints(maxWidth: 400),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('[ NEW SESSION ]', style: HackerTheme.mono(size: 16)),
            const SizedBox(height: 16), _buildInput('SESSION_NAME', nameCtl),
            const SizedBox(height: 12), _buildInput('PROJECT_DIR', dirCtl),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              _buildBtn('CANCEL', onTap: () => Navigator.pop(ctx), primary: false),
              const SizedBox(width: 8),
              _buildBtn('CREATE', onTap: () => Navigator.pop(ctx, {'name': nameCtl.text, 'dir': dirCtl.text})),
            ]),
          ]),
        ),
      ),
    );
    if (result != null && result['name']!.isNotEmpty) {
      await ApiService.createSession(result['name']!, result['dir']!);
      await _loadSessions();
    }
  }

  Widget _buildInput(String label, TextEditingController c) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: HackerTheme.mono(size: 10)), const SizedBox(height: 4),
      TextField(controller: c, style: HackerTheme.monoNoGlow(size: 14, color: HackerTheme.green), cursorColor: HackerTheme.green,
        decoration: InputDecoration(filled: true, fillColor: HackerTheme.bg, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.borderDim), borderRadius: BorderRadius.zero),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: HackerTheme.green), borderRadius: BorderRadius.zero))),
    ]);
  }

  Widget _buildBtn(String t, {required VoidCallback onTap, bool primary = true}) {
    return InkWell(onTap: onTap, child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(color: primary ? HackerTheme.green : HackerTheme.bgPanel, border: Border.all(color: HackerTheme.green)),
      child: Text(t, style: HackerTheme.monoNoGlow(size: 12, color: primary ? Colors.black : HackerTheme.green))));
  }

  void _selectSessionForPane(String id, int paneIdx) {
    final pane = _panes[paneIdx];
    if (pane.sessionId != null) _ws.unsubscribe(pane.sessionId!);
    setState(() {
      pane.sessionId = id;
      pane.clear();
      _sidebarOpen = false;
      _focusedPane = paneIdx;
    });
    _ws.subscribe(id);
  }

  Future<void> _startSession(String id) async {
    try {
      SoundService.instance.playUnitReady();
      await ApiService.startSession(id);
      await _loadSessions();
      _selectSessionForPane(id, _focusedPane);
    } catch (_) {}
  }

  Future<void> _stopSession(String id) async {
    try {
      await ApiService.stopSession(id);
      await _loadSessions();
      final pane = _paneForSession(id);
      if (pane != null) setState(() => pane.isProcessing = false);
    } catch (_) {}
  }

  Future<void> _deleteSession(String id, String name) async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => Dialog(
      backgroundColor: HackerTheme.bgPanel, shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.red)),
      child: Container(padding: const EdgeInsets.all(20), constraints: const BoxConstraints(maxWidth: 350),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('[ DELETE SESSION ]', style: HackerTheme.mono(size: 14, color: HackerTheme.red)),
          const SizedBox(height: 12), Text('Confirm delete "$name"?', style: HackerTheme.monoNoGlow(size: 12)),
          const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            _buildBtn('CANCEL', onTap: () => Navigator.pop(ctx, false), primary: false), const SizedBox(width: 8),
            InkWell(onTap: () => Navigator.pop(ctx, true), child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: HackerTheme.red, border: Border.all(color: HackerTheme.red)),
              child: Text('DELETE', style: HackerTheme.monoNoGlow(size: 12, color: Colors.black)))),
          ]),
        ])),
    ));
    if (confirmed == true) {
      try {
        await ApiService.deleteSession(id);
        for (final p in _panes) {
          if (p.sessionId == id) { p.sessionId = null; p.clear(); }
        }
        await _loadSessions();
      } catch (_) {}
    }
  }

  Future<void> _renameSession(String id, String currentName) async {
    final nameCtl = TextEditingController(text: currentName);
    final newName = await showDialog<String>(context: context, builder: (ctx) => Dialog(
      backgroundColor: HackerTheme.bgPanel, shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.green)),
      child: Container(padding: const EdgeInsets.all(20), constraints: const BoxConstraints(maxWidth: 400),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('[ RENAME SESSION ]', style: HackerTheme.mono(size: 14)),
          const SizedBox(height: 16), _buildInput('NEW_NAME', nameCtl), const SizedBox(height: 20),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            _buildBtn('CANCEL', onTap: () => Navigator.pop(ctx), primary: false), const SizedBox(width: 8),
            _buildBtn('RENAME', onTap: () => Navigator.pop(ctx, nameCtl.text)),
          ]),
        ])),
    ));
    if (newName != null && newName.isNotEmpty && newName != currentName) {
      try { await ApiService.renameSession(id, newName); await _loadSessions(); } catch (_) {}
    }
  }

  void _refreshPane(int paneIdx) {
    final pane = _panes[paneIdx];
    if (pane.sessionId == null) return;
    final sid = pane.sessionId!;
    _ws.unsubscribe(sid);
    setState(() => pane.clear());
    pane.sessionId = sid;
    _ws.subscribe(sid);
  }

  Future<void> _restartSession(int paneIdx) async {
    final pane = _panes[paneIdx];
    if (pane.sessionId == null) return;
    try {
      await ApiService.restartSession(pane.sessionId!);
      await _loadSessions();
      _refreshPane(paneIdx);
    } catch (_) {}
  }

  Future<void> _pickImage(int paneIdx, ImageSource source) async {
    final pane = _panes[paneIdx];
    if (pane.sessionId == null) return;
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85, maxWidth: 2048);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await _uploadAndAttach(paneIdx, bytes, picked.name);
    } catch (e) {
      _showUploadError(e.toString());
    }
  }

  Future<void> _uploadAndAttach(int paneIdx, Uint8List bytes, String filename) async {
    final pane = _panes[paneIdx];
    setState(() => pane.isUploading = true);
    try {
      final b64 = base64Encode(bytes);
      final result = await ApiService.uploadImage(b64, filename);
      if (result['path'] != null) {
        setState(() {
          pane.attachments.add({
            'filename': filename,
            'serverPath': result['path'] as String,
            'bytes': bytes,
          });
        });
      }
    } catch (e) {
      _showUploadError(e.toString());
    } finally {
      if (mounted) setState(() => pane.isUploading = false);
    }
  }

  void _showUploadError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Upload failed: $msg', style: HackerTheme.monoNoGlow(size: 11, color: Colors.black)),
        backgroundColor: HackerTheme.red, duration: const Duration(seconds: 2)));
    }
  }

  Future<bool> _handlePaste(int paneIdx) async {
    // Try clipboard image first (desktop)
    if (!kIsWeb) {
      try {
        final imageBytes = await Pasteboard.image;
        if (imageBytes != null && imageBytes.isNotEmpty) {
          final filename = 'clipboard_${DateTime.now().millisecondsSinceEpoch}.png';
          await _uploadAndAttach(paneIdx, imageBytes, filename);
          return true; // handled
        }
      } catch (_) {}
    }
    return false; // not handled, let default paste work
  }

  void _showAttachMenu(int paneIdx) {
    final mobile = _isMobile(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: HackerTheme.bgPanel,
      shape: const RoundedRectangleBorder(
        side: BorderSide(color: HackerTheme.green),
        borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('[ ATTACH ]', style: HackerTheme.mono(size: 14)),
          const SizedBox(height: 16),
          if (!kIsWeb) ListTile(
            leading: Icon(Icons.camera_alt, color: HackerTheme.green, size: 20),
            title: Text('CAMERA', style: HackerTheme.mono(size: 12)),
            onTap: () { Navigator.pop(ctx); _pickImage(paneIdx, ImageSource.camera); },
          ),
          ListTile(
            leading: Icon(Icons.photo_library, color: HackerTheme.green, size: 20),
            title: Text('GALLERY', style: HackerTheme.mono(size: 12)),
            onTap: () { Navigator.pop(ctx); _pickImage(paneIdx, ImageSource.gallery); },
          ),
          ListTile(
            leading: Icon(Icons.content_paste, color: HackerTheme.green, size: 20),
            title: Text('PASTE IMAGE FROM CLIPBOARD', style: HackerTheme.mono(size: 12)),
            onTap: () { Navigator.pop(ctx); _handlePaste(paneIdx); },
          ),
        ]),
      ),
    );
  }

  void _sendPromptForPane(int paneIdx) {
    final pane = _panes[paneIdx];
    final text = pane.promptController.text.trim();
    if (text.isEmpty || pane.sessionId == null || pane.isProcessing) return;
    pane.promptHistory.add(text);
    pane.historyIndex = -1;
    pane.historyDraft = '';

    // Build prompt with image attachments
    String finalPrompt = text;
    if (pane.attachments.isNotEmpty) {
      final paths = pane.attachments.map((a) => a['serverPath']).join(', ');
      finalPrompt = 'I have attached ${pane.attachments.length} image(s) at: $paths\n\nPlease read and analyze the image(s) first, then respond to my message:\n\n$text';
    }

    SoundService.instance.playAcknowledged();
    _ws.sendPrompt(pane.sessionId!, finalPrompt);
    pane.promptController.clear();
    pane.promptFocus.requestFocus();
    setState(() {
      pane.isProcessing = true;
      pane.attachments.clear();
    });
  }

  void _onPaneInputKey(KeyEvent event, int paneIdx) {
    if (event is! KeyDownEvent) return;
    final pane = _panes[paneIdx];
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (pane.promptHistory.isEmpty) return;
      if (pane.historyIndex == -1) { pane.historyDraft = pane.promptController.text; pane.historyIndex = pane.promptHistory.length - 1; }
      else if (pane.historyIndex > 0) { pane.historyIndex--; }
      pane.promptController.text = pane.promptHistory[pane.historyIndex];
      pane.promptController.selection = TextSelection.fromPosition(TextPosition(offset: pane.promptController.text.length));
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (pane.historyIndex == -1) return;
      if (pane.historyIndex < pane.promptHistory.length - 1) { pane.historyIndex++; pane.promptController.text = pane.promptHistory[pane.historyIndex]; }
      else { pane.historyIndex = -1; pane.promptController.text = pane.historyDraft; }
      pane.promptController.selection = TextSelection.fromPosition(TextPosition(offset: pane.promptController.text.length));
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('COPIED', style: HackerTheme.monoNoGlow(size: 11, color: Colors.black)),
      backgroundColor: HackerTheme.green, duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating, width: 120));
  }

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _wsSub?.cancel(); _wsStateSub?.cancel(); _ws.dispose(); _cursorController.dispose(); _sessionRefreshTimer?.cancel();
    for (final p in _panes) { p.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mobile = _isMobile(context);
    return Scaffold(body: SafeArea(child: ScanlineOverlay(child: Column(children: [
      _buildTopBar(mobile),
      if (mobile) _buildSessionTabs(),
      Expanded(child: Stack(children: [
        Row(children: [
          if (!mobile) _buildSidebar(),
          Expanded(child: _buildPanesArea()),
        ]),
        if (mobile && _sidebarOpen) ...[
          GestureDetector(onTap: () => setState(() => _sidebarOpen = false), child: Container(color: Colors.black54)),
          _buildSidebar(mobile: true),
        ],
      ])),
    ]))));
  }

  Widget _buildPanesArea() {
    switch (_viewMode) {
      case ViewMode.single:
        return _buildSinglePane(0);
      case ViewMode.split2:
        return Row(children: [
          Expanded(child: _buildSinglePane(0)),
          Container(width: 1, color: HackerTheme.green),
          Expanded(child: _buildSinglePane(1)),
        ]);
      case ViewMode.quad4:
        return Column(children: [
          Expanded(child: Row(children: [
            Expanded(child: _buildSinglePane(0)),
            Container(width: 1, color: HackerTheme.green),
            Expanded(child: _buildSinglePane(1)),
          ])),
          Container(height: 1, color: HackerTheme.green),
          Expanded(child: Row(children: [
            Expanded(child: _buildSinglePane(2)),
            Container(width: 1, color: HackerTheme.green),
            Expanded(child: _buildSinglePane(3)),
          ])),
        ]);
    }
  }

  Widget _buildSinglePane(int paneIdx) {
    if (paneIdx >= _panes.length) return const SizedBox();
    final pane = _panes[paneIdx];
    final isFocused = _focusedPane == paneIdx;
    final isMulti = _viewMode != ViewMode.single;

    return GestureDetector(
      onTap: () => setState(() => _focusedPane = paneIdx),
      child: Container(
        decoration: BoxDecoration(
          border: isMulti ? Border.all(color: isFocused ? HackerTheme.green : Colors.transparent, width: 1) : null,
        ),
        child: Column(children: [
          // Pane header (only in multi-view)
          if (isMulti) _buildPaneHeader(paneIdx),
          // Terminal view
          Expanded(child: _buildTerminalView(paneIdx)),
          // Processing bar or action bar
          if (pane.isProcessing) _buildProcessingBar(paneIdx)
          else if (pane.sessionId != null) _buildActionBar(paneIdx),
          // Input bar
          _buildInputBar(paneIdx),
        ]),
      ),
    );
  }

  Widget _buildPaneHeader(int paneIdx) {
    final pane = _panes[paneIdx];
    final isFocused = _focusedPane == paneIdx;
    final session = pane.sessionId != null ? _sessions.firstWhere((s) => s['id'] == pane.sessionId, orElse: () => null) : null;
    final name = session?['name'] ?? 'EMPTY';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isFocused ? HackerTheme.greenDim : HackerTheme.bgPanel,
        border: Border(bottom: BorderSide(color: isFocused ? HackerTheme.green : HackerTheme.borderDim)),
      ),
      child: Row(children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(
          color: isFocused ? HackerTheme.green : HackerTheme.grey, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text('P${paneIdx + 1}', style: HackerTheme.mono(size: 9, color: isFocused ? HackerTheme.green : HackerTheme.dimText)),
        const SizedBox(width: 6),
        Expanded(child: Text(name.toString().toUpperCase(), style: HackerTheme.mono(size: 9, color: isFocused ? HackerTheme.green : HackerTheme.dimText), overflow: TextOverflow.ellipsis)),
        if (pane.sessionId != null)
          InkWell(
            onTap: () { _ws.unsubscribe(pane.sessionId!); setState(() { pane.sessionId = null; pane.clear(); }); },
            child: Text('x', style: HackerTheme.mono(size: 10, color: HackerTheme.red)),
          ),
      ]),
    );
  }

  Widget _buildTopBar(bool mobile) {
    final showWsBadge = _wsState != WsState.connected;
    final activeCount = _sessions.where((s) => s['status'] == 'active').length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: HackerTheme.bgPanel, border: const Border(bottom: BorderSide(color: HackerTheme.borderDim, width: 1))),
      child: Row(children: [
        if (mobile) InkWell(onTap: () => setState(() => _sidebarOpen = !_sidebarOpen),
          child: Padding(padding: const EdgeInsets.only(right: 10), child: Text('[\u2630]', style: HackerTheme.mono(size: 16)))),
        Text('NACA', style: HackerTheme.mono(size: 13)),
        const SizedBox(width: 4),
        Text('terminal', style: HackerTheme.mono(size: 8, color: HackerTheme.dimText)),
        const SizedBox(width: 6),
        Text('///', style: HackerTheme.mono(size: 10, color: HackerTheme.borderDim)),
        const SizedBox(width: 6),
        Container(width: 6, height: 6, decoration: BoxDecoration(
          color: _serverOnline ? HackerTheme.green : HackerTheme.red, shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: _serverOnline ? HackerTheme.greenGlow : const Color(0x99FF003C), blurRadius: 6)])),
        const SizedBox(width: 6),
        Text(_serverStatus, style: HackerTheme.mono(size: 10, color: _serverOnline ? HackerTheme.green : HackerTheme.red)),
        if (showWsBadge) ...[
          const SizedBox(width: 10),
          InkWell(onTap: _wsState == WsState.disconnected ? () => _ws.reconnect() : null,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: _wsState == WsState.disconnected ? HackerTheme.red.withValues(alpha: 0.5) : HackerTheme.amber.withValues(alpha: 0.5))),
              child: Text(_wsState == WsState.disconnected ? 'RECONNECT' : 'CONNECTING...',
                style: HackerTheme.mono(size: 9, color: _wsState == WsState.disconnected ? HackerTheme.red : HackerTheme.amber)))),
        ],
        const Spacer(),
        // View mode buttons (desktop only, need 2+ sessions)
        if (!mobile && _sessions.length >= 2) ...[
          _viewModeBtn('[1]', ViewMode.single),
          const SizedBox(width: 4),
          _viewModeBtn('[2]', ViewMode.split2),
          if (_sessions.length >= 4) ...[
            const SizedBox(width: 4),
            _viewModeBtn('[4]', ViewMode.quad4),
          ],
          const SizedBox(width: 10),
        ],
        AnimatedBuilder(animation: _cursorController, builder: (_, __) => Container(
          width: 8, height: 14, color: _cursorController.value < 0.5 ? HackerTheme.green : Colors.transparent)),
      ]),
    );
  }

  Widget _buildSessionTabs() {
    final focusedPane = _panes[_focusedPane];
    final currentSession = focusedPane.sessionId != null
        ? _sessions.cast<Map<String, dynamic>?>().firstWhere(
            (s) => s?['id'] == focusedPane.sessionId, orElse: () => null)
        : null;
    final sessionName = currentSession?['name'] ?? 'NO SESSION';
    final sessionStatus = currentSession?['status'] ?? 'idle';
    final isRunning = sessionStatus == 'active';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        color: HackerTheme.bgPanel,
        border: Border(bottom: BorderSide(color: HackerTheme.borderDim, width: 1)),
      ),
      child: Row(children: [
        // Session indicator
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            color: isRunning ? HackerTheme.green : HackerTheme.grey,
            shape: BoxShape.circle,
            boxShadow: isRunning ? [const BoxShadow(color: HackerTheme.greenGlow, blurRadius: 6)] : null,
          ),
        ),
        const SizedBox(width: 8),
        // Session name (tap to open sidebar)
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _sidebarOpen = true),
            child: Text(
              sessionName.toString().toUpperCase(),
              style: HackerTheme.mono(size: 11, color: HackerTheme.green),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // Action buttons — visible and touchable
        if (currentSession != null) ...[
          if (!isRunning) _mobileActionBtn('START', Icons.play_arrow, HackerTheme.green, () => _startSession(focusedPane.sessionId!)),
          if (isRunning) _mobileActionBtn('STOP', Icons.stop, HackerTheme.red, () => _stopSession(focusedPane.sessionId!)),
          const SizedBox(width: 6),
          _mobileActionBtn('REFRESH', Icons.refresh, HackerTheme.cyan, () => _refreshPane(_focusedPane)),
        ],
        const SizedBox(width: 6),
        // New session
        GestureDetector(
          onTap: _createSession,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(border: Border.all(color: HackerTheme.green, width: 0.5)),
            child: Text('+', style: HackerTheme.mono(size: 14)),
          ),
        ),
      ]),
    );
  }

  Widget _mobileActionBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.6)),
          color: color.withValues(alpha: 0.1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: HackerTheme.monoNoGlow(size: 9, color: color)),
        ]),
      ),
    );
  }

  Widget _viewModeBtn(String label, ViewMode mode) {
    final active = _viewMode == mode;
    return InkWell(
      onTap: () => _setViewMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active ? HackerTheme.green : Colors.transparent,
          border: Border.all(color: active ? HackerTheme.green : HackerTheme.borderDim),
        ),
        child: Text(label, style: HackerTheme.monoNoGlow(size: 10, color: active ? Colors.black : HackerTheme.dimText)),
      ),
    );
  }

  Widget _buildSidebar({bool mobile = false}) {
    return Container(
      width: mobile ? 260 : 220,
      decoration: BoxDecoration(color: HackerTheme.bgPanel,
        border: const Border(right: BorderSide(color: HackerTheme.green, width: 1)),
        boxShadow: mobile ? [BoxShadow(color: HackerTheme.greenDim, blurRadius: 20)] : null),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: HackerTheme.borderDim))),
          child: Row(children: [
            Text('SESSIONS', style: HackerTheme.mono(size: 11)),
            const Spacer(),
            if (_viewMode != ViewMode.single) Text('P${_focusedPane + 1}', style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
            if (_viewMode != ViewMode.single) const SizedBox(width: 6),
            Text('${_sessions.length}', style: HackerTheme.mono(size: 10, color: HackerTheme.dimText)),
          ])),
        Expanded(child: _sessions.isEmpty
          ? Center(child: Text('NO SESSIONS', style: HackerTheme.mono(size: 10, color: HackerTheme.dimText)))
          : _buildGroupedSessionList()),
        Padding(padding: const EdgeInsets.all(8), child: InkWell(onTap: _createSession,
          child: Container(padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(border: Border.all(color: HackerTheme.green)),
            child: Center(child: Text('[ + NEW SESSION ]', style: HackerTheme.mono(size: 12)))))),
      ]),
    );
  }

  Widget _buildGroupedSessionList() {
    // Group sessions by source
    final nacaSessions = _sessions.where((s) => (s['source'] ?? 'naca') == 'naca').toList();
    final importedSessions = _sessions.where((s) => (s['source'] ?? 'naca') != 'naca').toList();

    return ListView(children: [
      if (nacaSessions.isNotEmpty) ...[
        _sessionGroupHeader('NACA TERMINAL', nacaSessions.length, HackerTheme.green),
        ...nacaSessions.map(_buildSessionTile),
      ],
      if (importedSessions.isNotEmpty) ...[
        _sessionGroupHeader('VPS CLI SESSIONS', importedSessions.length, HackerTheme.cyan),
        ...importedSessions.map((s) => _buildSessionTile(s, imported: true)),
      ],
    ]);
  }

  Widget _sessionGroupHeader(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: HackerTheme.bgContent,
        border: Border(bottom: BorderSide(color: HackerTheme.borderDim, width: 0.5)),
      ),
      child: Row(children: [
        Container(width: 4, height: 4, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: HackerTheme.monoNoGlow(size: 8, color: color)),
        const Spacer(),
        Text('$count', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
      ]),
    );
  }

  Widget _buildSessionTile(dynamic session, {bool imported = false}) {
    final id = session['id'] as String;
    final name = session['name'] as String;
    final status = session['status'] as String;
    final turns = session['turns'] ?? 0;
    final focusedPane = _panes[_focusedPane];
    final isActive = id == focusedPane.sessionId;
    final isRunning = status == 'active';

    // Check if this session is in any pane
    final paneIndex = _panes.indexWhere((p) => p.sessionId == id);
    final isInAnyPane = paneIndex >= 0;

    final source = session['source'] ?? 'naca';
    final agent = session['agent'] as String?;

    Color badgeColor; String badgeText;
    switch (status) {
      case 'active': badgeColor = HackerTheme.green; badgeText = 'RUN';
      case 'error': badgeColor = HackerTheme.red; badgeText = 'ERR';
      default: badgeColor = imported ? HackerTheme.cyan : HackerTheme.grey; badgeText = imported ? 'CLI' : 'IDLE';
    }

    return InkWell(
      onTap: () => _selectSessionForPane(id, _focusedPane),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? HackerTheme.greenDim : Colors.transparent,
          border: Border(
            left: BorderSide(color: isActive ? HackerTheme.green : Colors.transparent, width: 2),
            bottom: const BorderSide(color: HackerTheme.borderDim, width: 0.5))),
        child: Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(border: Border.all(color: badgeColor, width: 0.5),
              boxShadow: isRunning ? [BoxShadow(color: badgeColor.withValues(alpha: 0.4), blurRadius: 4)] : null),
            child: Text(badgeText, style: HackerTheme.monoNoGlow(size: 8, color: badgeColor))),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(name.toUpperCase(), style: HackerTheme.mono(size: 12, color: isActive ? HackerTheme.green : HackerTheme.dimText), overflow: TextOverflow.ellipsis)),
              // Show pane indicator if in a pane
              if (isInAnyPane && _viewMode != ViewMode.single)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: HackerTheme.cyan, width: 0.5)),
                  child: Text('P${paneIndex + 1}', style: HackerTheme.monoNoGlow(size: 7, color: HackerTheme.cyan)),
                ),
            ]),
            Row(children: [
              if (agent != null) ...[
                Text(agent, style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.cyan)),
                const SizedBox(width: 6),
              ],
              Expanded(child: Text(session['project_dir'] ?? '/home/openclaw', style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText), overflow: TextOverflow.ellipsis)),
              if (turns > 0) Text('$turns turns', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.dimText)),
            ]),
          ])),
          if (isActive) ...[
            if (!isRunning) _iconBtn('\u25B6', HackerTheme.green, () => _startSession(id)),
            if (isRunning) _iconBtn('\u25A0', HackerTheme.red, () => _stopSession(id)),
            const SizedBox(width: 4),
            PopupMenuButton<String>(padding: EdgeInsets.zero, constraints: const BoxConstraints(),
              color: HackerTheme.bgPanel, shape: RoundedRectangleBorder(side: const BorderSide(color: HackerTheme.borderDim)),
              icon: Text('...', style: HackerTheme.mono(size: 12, color: HackerTheme.dimText)),
              onSelected: (action) { switch (action) { case 'rename': _renameSession(id, name); case 'delete': _deleteSession(id, name); } },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', child: Text('RENAME', style: HackerTheme.monoNoGlow(size: 11))),
                PopupMenuItem(value: 'delete', child: Text('DELETE', style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.red))),
              ]),
          ],
        ]),
      ),
    );
  }

  Widget _iconBtn(String icon, Color color, VoidCallback onTap) {
    return InkWell(onTap: onTap, child: Container(padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(border: Border.all(color: color)),
      child: Text(icon, style: HackerTheme.mono(size: 10, color: color))));
  }

  Widget _buildActionBar(int paneIdx) {
    final compact = _viewMode != ViewMode.single;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8, vertical: 2),
      decoration: const BoxDecoration(color: HackerTheme.bgCard,
        border: Border(top: BorderSide(color: HackerTheme.borderDim, width: 0.5))),
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        _actionBtn('REFRESH', Icons.refresh, HackerTheme.cyan, () => _refreshPane(paneIdx)),
        const SizedBox(width: 6),
        _actionBtn('RESTART', Icons.restart_alt, HackerTheme.amber, () => _restartSession(paneIdx)),
      ]),
    );
  }

  Widget _actionBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(onTap: onTap, child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Text(label, style: HackerTheme.mono(size: 8, color: color)),
      ]),
    ));
  }

  Widget _buildProcessingBar(int paneIdx) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), color: HackerTheme.bgCard,
      child: Row(children: [
        SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1, color: HackerTheme.green)),
        const SizedBox(width: 6),
        Text('THINKING...', style: HackerTheme.mono(size: 9, color: HackerTheme.amber)),
        const Spacer(),
        _actionBtn('FORCE STOP', Icons.stop, HackerTheme.red, () => _stopSession(_panes[paneIdx].sessionId!)),
      ]));
  }

  Widget _buildTerminalView(int paneIdx) {
    final pane = _panes[paneIdx];
    if (pane.sessionId == null) {
      return Container(color: HackerTheme.bgContent, child: Center(
        child: _viewMode == ViewMode.single
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              Text('  \u2588\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2557  \u2588\u2588\u2588\u2588\u2588\u2588\u2557\n'
                ' \u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255d \u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255d \u2588\u2588\u2554\u2550\u2550\u2550\u2550\u255d\n'
                ' \u2588\u2588\u2551      \u2588\u2588\u2551      \u2588\u2588\u2551     \n'
                ' \u2588\u2588\u2551      \u2588\u2588\u2551      \u2588\u2588\u2551     \n'
                ' \u255a\u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u255a\u2588\u2588\u2588\u2588\u2588\u2588\u2557 \u255a\u2588\u2588\u2588\u2588\u2588\u2588\u2557\n'
                '  \u255a\u2550\u2550\u2550\u2550\u2550\u255d  \u255a\u2550\u2550\u2550\u2550\u2550\u255d  \u255a\u2550\u2550\u2550\u2550\u2550\u255d',
                style: HackerTheme.mono(size: 14), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text('NACA TERMINAL', style: HackerTheme.mono(size: 12, color: HackerTheme.dimText)),
              const SizedBox(height: 24),
              Text('> SELECT OR CREATE A SESSION', style: HackerTheme.mono(color: HackerTheme.dimText, size: 11)),
            ])
          : Text('SELECT SESSION', style: HackerTheme.mono(size: 10, color: HackerTheme.dimText)),
      ));
    }
    return Container(color: HackerTheme.bgContent,
      child: ListView.builder(controller: pane.scrollController, padding: const EdgeInsets.all(12),
        itemCount: pane.events.length, itemBuilder: (_, i) => _buildEventWidget(pane, i)));
  }

  Widget _buildEventWidget(PaneState pane, int index) {
    final event = pane.events[index];
    switch (event['type'] ?? '') {
      case 'user_message': return _buildUserMessage(event['content'] ?? '', pane, index);
      case 'assistant_text': return _buildAssistantMessage(event['content'] ?? '', pane, index);
      case 'tool_call': return _buildToolCall(event, pane, index);
      case 'tool_result': return _buildToolResult(event, pane, index);
      case 'system': return _buildSystemMessage(event['content'] ?? '', pane, index);
      case 'session_ended': return _buildSystemMessage('Session terminated [code: ${event['code']}]', pane, index);
      case 'stderr': final t = event['content'] ?? ''; return t.isEmpty ? const SizedBox.shrink() : Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Text(t, style: HackerTheme.monoNoGlow(color: HackerTheme.dimText, size: 10)));
      default: return const SizedBox.shrink();
    }
  }

  Widget _ts(PaneState pane, int index) {
    final t = pane.timestamps[index];
    if (t == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(left: 4), child: Text(_formatTime(t), style: HackerTheme.monoNoGlow(size: 9, color: HackerTheme.dimText)));
  }

  Widget _buildUserMessage(String c, PaneState pane, int index) {
    return TerminalCard(active: true, margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('> ', style: HackerTheme.mono(size: 13)), Expanded(child: SelectableText(c, style: HackerTheme.mono(size: 12))), _ts(pane, index)]));
  }

  Widget _buildAssistantMessage(String c, PaneState pane, int index) {
    return Container(margin: const EdgeInsets.symmetric(vertical: 3), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: MarkdownBody(data: c, selectable: true,
          onTapLink: (text, href, title) {
            if (href != null) launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
          },
          styleSheet: MarkdownStyleSheet(
          p: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.green),
          h1: HackerTheme.mono(size: 16, color: HackerTheme.cyan), h2: HackerTheme.mono(size: 14, color: HackerTheme.cyan),
          h3: HackerTheme.mono(size: 13, color: HackerTheme.cyan), h4: HackerTheme.mono(size: 12, color: HackerTheme.cyan),
          code: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.amber).copyWith(backgroundColor: HackerTheme.bgCard),
          codeblockDecoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: HackerTheme.borderDim)),
          codeblockPadding: const EdgeInsets.all(10),
          listBullet: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.green),
          strong: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.white),
          em: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.cyan),
          a: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.cyan).copyWith(decoration: TextDecoration.underline, decorationColor: HackerTheme.cyan),
          blockquoteDecoration: BoxDecoration(color: HackerTheme.bgCard, border: const Border(left: BorderSide(color: HackerTheme.green, width: 3))),
          blockquotePadding: const EdgeInsets.all(8),
          tableBorder: TableBorder.all(color: HackerTheme.borderDim),
          tableHead: HackerTheme.mono(size: 10, color: HackerTheme.cyan), tableBody: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.green),
          tableCellsDecoration: const BoxDecoration(color: HackerTheme.bgCard),
          horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: HackerTheme.borderDim)))))),
        InkWell(onTap: () => _copyToClipboard(c), child: Padding(padding: const EdgeInsets.only(left: 6, top: 2), child: Icon(Icons.copy, size: 12, color: HackerTheme.dimText))),
        _ts(pane, index),
      ]));
  }

  Widget _buildToolCall(Map<String, dynamic> event, PaneState pane, int index) {
    final name = event['name'] ?? '?'; final input = event['input']; final expanded = pane.expandedTools.contains(index);
    String detail = '', fullDetail = '';
    if (input is Map) {
      if (input.containsKey('file_path')) detail = input['file_path'];
      else if (input.containsKey('command')) detail = input['command'];
      else if (input.containsKey('pattern')) detail = input['pattern'];
      else { final s = input.toString(); detail = s.length > 60 ? '${s.substring(0, 60)}...' : s; }
      fullDetail = const JsonEncoder.withIndent('  ').convert(input);
    }
    Color ic; String icon;
    switch (name) { case 'Read': icon = '\u2636'; ic = HackerTheme.cyan; case 'Edit': case 'Write': icon = '\u270E'; ic = HackerTheme.amber;
      case 'Bash': icon = '\$'; ic = HackerTheme.green; case 'Grep': case 'Glob': icon = '\u2315'; ic = HackerTheme.cyan; default: icon = '\u2699'; ic = HackerTheme.grey; }
    return GestureDetector(onTap: () => setState(() { if (expanded) pane.expandedTools.remove(index); else pane.expandedTools.add(index); }),
      child: Container(margin: const EdgeInsets.symmetric(vertical: 2), decoration: BoxDecoration(color: HackerTheme.bgCard, border: Border.all(color: expanded ? ic.withValues(alpha: 0.5) : HackerTheme.borderDim)),
        child: Column(children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: Row(children: [
            Text(icon, style: TextStyle(color: ic, fontSize: 12, fontFamily: 'Courier New')), const SizedBox(width: 6),
            Text(name.toUpperCase(), style: HackerTheme.mono(color: ic, size: 10)), const SizedBox(width: 6),
            Expanded(child: Text(detail, style: HackerTheme.monoNoGlow(color: HackerTheme.dimText, size: 10), overflow: TextOverflow.ellipsis)),
            if (fullDetail.isNotEmpty) InkWell(onTap: () => _copyToClipboard(fullDetail), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: Icon(Icons.copy, size: 10, color: HackerTheme.dimText))),
            _ts(pane, index), Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 12, color: HackerTheme.dimText)])),
          if (expanded && fullDetail.isNotEmpty) Container(width: double.infinity, padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: HackerTheme.bg, border: Border.all(color: HackerTheme.borderDim)),
              child: SelectableText(fullDetail, style: HackerTheme.monoNoGlow(color: HackerTheme.amber, size: 9)))),
        ])));
  }

  Widget _buildToolResult(Map<String, dynamic> event, PaneState pane, int index) {
    final content = event['content']?.toString() ?? ''; final hasContent = content.isNotEmpty; final expanded = pane.expandedTools.contains(index);
    return GestureDetector(onTap: hasContent ? () => setState(() { if (expanded) pane.expandedTools.remove(index); else pane.expandedTools.add(index); }) : null,
      child: Column(children: [
        Padding(padding: const EdgeInsets.only(left: 30, bottom: 3), child: Row(children: [
          Text('[OK]', style: HackerTheme.mono(color: HackerTheme.green, size: 9)),
          if (hasContent) ...[const SizedBox(width: 4), Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 10, color: HackerTheme.dimText)]])),
        if (expanded && hasContent) Container(margin: const EdgeInsets.only(left: 30, right: 10, bottom: 4), padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: HackerTheme.bg, border: Border.all(color: HackerTheme.borderDim)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Spacer(), InkWell(onTap: () => _copyToClipboard(content), child: Icon(Icons.copy, size: 10, color: HackerTheme.dimText))]),
            SelectableText(content.length > 2000 ? '${content.substring(0, 2000)}\n... (truncated)' : content, style: HackerTheme.monoNoGlow(color: HackerTheme.dimText, size: 9))])),
      ]));
  }

  Widget _buildSystemMessage(String t, PaneState pane, int index) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [Expanded(child: Text('[SYS] $t', style: HackerTheme.mono(color: HackerTheme.amber, size: 9))), _ts(pane, index)]));
  }

  Widget _buildInputBar(int paneIdx) {
    final pane = _panes[paneIdx];
    final session = pane.sessionId != null ? _sessions.firstWhere((s) => s['id'] == pane.sessionId, orElse: () => null) : null;
    final isRunning = session?['status'] == 'active';
    final canSend = pane.sessionId != null && isRunning && !pane.isProcessing;
    final canAttach = pane.sessionId != null && isRunning && !pane.isUploading;
    final compact = _viewMode != ViewMode.single;

    return Column(mainAxisSize: MainAxisSize.min, children: [
      // Attachment chips
      if (pane.attachments.isNotEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: const BoxDecoration(color: HackerTheme.bgCard,
            border: Border(top: BorderSide(color: HackerTheme.borderDim))),
          child: Row(children: [
            Icon(Icons.attach_file, size: 12, color: HackerTheme.cyan),
            const SizedBox(width: 4),
            Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal,
              child: Row(children: pane.attachments.asMap().entries.map((e) {
                final bytes = e.value['bytes'] as Uint8List?;
                return Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(border: Border.all(color: HackerTheme.cyan, width: 0.5)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (bytes != null) ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Image.memory(bytes, width: 24, height: 24, fit: BoxFit.cover)),
                    if (bytes != null) const SizedBox(width: 4),
                    Text(e.value['filename'] ?? 'image', style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => setState(() => pane.attachments.removeAt(e.key)),
                      child: Text('x', style: HackerTheme.mono(size: 9, color: HackerTheme.red))),
                  ]),
                );
              }).toList()),
            )),
          ]),
        ),
      // Upload progress
      if (pane.isUploading)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: HackerTheme.bgCard,
          child: Row(children: [
            SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1, color: HackerTheme.cyan)),
            const SizedBox(width: 6),
            Text('UPLOADING...', style: HackerTheme.mono(size: 9, color: HackerTheme.cyan)),
          ]),
        ),
      Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 12, vertical: compact ? 6 : 10),
        decoration: BoxDecoration(color: HackerTheme.bgPanel,
          border: const Border(top: BorderSide(color: HackerTheme.green, width: 1)),
          boxShadow: [BoxShadow(color: HackerTheme.greenDim, blurRadius: 4)]),
        child: Row(children: [
          // Attach button
          InkWell(onTap: canAttach ? () => _showAttachMenu(paneIdx) : null,
            child: Padding(padding: EdgeInsets.only(right: compact ? 4 : 8),
              child: Icon(Icons.add_photo_alternate, size: compact ? 16 : 20,
                color: canAttach ? HackerTheme.cyan : HackerTheme.dimText))),
          Text('> ', style: HackerTheme.mono(size: compact ? 12 : 16)),
          Expanded(child: KeyboardListener(focusNode: FocusNode(), onKeyEvent: (e) {
              _onPaneInputKey(e, paneIdx);
              // Intercept Cmd/Ctrl+V for image paste
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyV &&
                  (HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed)) {
                _handlePaste(paneIdx);
              }
            },
            child: TextField(controller: pane.promptController, focusNode: pane.promptFocus,
              style: HackerTheme.monoNoGlow(size: compact ? 11 : 14, color: canSend ? HackerTheme.green : HackerTheme.dimText), cursorColor: HackerTheme.green,
              decoration: InputDecoration(
                hintText: pane.isProcessing ? 'WAITING...' : pane.sessionId == null ? 'SELECT SESSION...' : !isRunning ? 'START FIRST...' : 'ENTER COMMAND...',
                hintStyle: HackerTheme.monoNoGlow(color: pane.isProcessing ? HackerTheme.amber : HackerTheme.dimText, size: compact ? 11 : 14),
                border: InputBorder.none, contentPadding: EdgeInsets.zero),
              onSubmitted: canSend ? (_) => _sendPromptForPane(paneIdx) : null))),
          const SizedBox(width: 4),
          InkWell(onTap: canSend ? () => _sendPromptForPane(paneIdx) : null,
            child: Container(padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 16, vertical: compact ? 4 : 8),
              decoration: BoxDecoration(color: canSend ? HackerTheme.green : HackerTheme.bgCard,
                border: Border.all(color: canSend ? HackerTheme.green : HackerTheme.borderDim),
                boxShadow: canSend ? [BoxShadow(color: HackerTheme.greenGlow, blurRadius: 8)] : null),
              child: Text(pane.isProcessing ? 'WAIT' : 'SEND', style: HackerTheme.monoNoGlow(size: compact ? 9 : 12, color: canSend ? Colors.black : HackerTheme.dimText)))),
        ]),
      ),
    ]);
  }
}
