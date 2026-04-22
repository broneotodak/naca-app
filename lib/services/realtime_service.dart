import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Wraps Supabase Realtime channels for agent data.
///
/// Singleton — call [init] once after Supabase.initialize().
/// Consumers listen to [heartbeats] and [commands] streams.
class RealtimeService {
  static final RealtimeService _instance = RealtimeService._();
  static RealtimeService get instance => _instance;
  RealtimeService._();

  final _heartbeatController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _commandController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<List<Map<String, dynamic>>> get heartbeats =>
      _heartbeatController.stream;
  Stream<Map<String, dynamic>> get commands => _commandController.stream;

  RealtimeChannel? _heartbeatChannel;
  RealtimeChannel? _commandChannel;
  bool _initialized = false;

  SupabaseClient get _sb => Supabase.instance.client;

  void init() {
    if (_initialized) return;
    _initialized = true;

    // Subscribe to agent_heartbeats changes
    _heartbeatChannel = _sb
        .channel('agent-heartbeats')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'agent_heartbeats',
          callback: (payload) {
            _heartbeatController.add([payload.newRecord]);
          },
        )
        .subscribe();

    // Subscribe to agent_commands inserts
    _commandChannel = _sb
        .channel('agent-commands')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'agent_commands',
          callback: (payload) {
            _commandController.add(payload.newRecord);
          },
        )
        .subscribe();
  }

  void dispose() {
    _heartbeatChannel?.unsubscribe();
    _commandChannel?.unsubscribe();
    _heartbeatController.close();
    _commandController.close();
  }
}
