import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';

enum WsState { connecting, connected, disconnected }

class WsService {
  WebSocketChannel? _channel;
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  final _stateController = StreamController<WsState>.broadcast();
  WsState _state = WsState.disconnected;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  final Set<String> _subscribedSessionIds = {};

  Stream<Map<String, dynamic>> get events => _eventController.stream;
  Stream<WsState> get stateStream => _stateController.stream;
  WsState get state => _state;

  void _setState(WsState s) {
    _state = s;
    _stateController.add(s);
  }

  void connect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _channel?.sink.close();

    _setState(WsState.connecting);
    final uri = Uri.parse('${AppConfig.wsUrl}?token=${AppConfig.authToken}');

    try {
      _channel = WebSocketChannel.connect(uri);
    } catch (e) {
      _setState(WsState.disconnected);
      _scheduleReconnect();
      return;
    }

    _setState(WsState.connected);

    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_state == WsState.connected) {
        _send({'action': 'ping'});
      }
    });

    _channel!.stream.listen(
      (data) {
        try {
          final event = jsonDecode(data as String) as Map<String, dynamic>;
          if (event['type'] == 'pong') return;
          _eventController.add(event);
        } catch (_) {}
      },
      onDone: () {
        _pingTimer?.cancel();
        _setState(WsState.disconnected);
        _eventController.add({'type': 'ws_disconnected'});
        _scheduleReconnect();
      },
      onError: (e) {
        _pingTimer?.cancel();
        _setState(WsState.disconnected);
        _scheduleReconnect();
      },
    );

    // Re-subscribe all sessions on reconnect
    if (_subscribedSessionIds.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_state == WsState.connected) {
          for (final id in _subscribedSessionIds) {
            _send({'action': 'subscribe', 'sessionId': id});
          }
        }
      });
    }
  }

  void reconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _channel?.sink.close();
    connect();
  }

  void subscribe(String sessionId) {
    _subscribedSessionIds.add(sessionId);
    _send({'action': 'subscribe', 'sessionId': sessionId});
  }

  void unsubscribe(String sessionId) {
    _subscribedSessionIds.remove(sessionId);
    _send({'action': 'unsubscribe', 'sessionId': sessionId});
  }

  void unsubscribeAll() {
    _subscribedSessionIds.clear();
    _send({'action': 'unsubscribe'});
  }

  void sendPrompt(String sessionId, String content) {
    _send({'action': 'prompt', 'sessionId': sessionId, 'content': content});
  }

  void _send(Map<String, dynamic> data) {
    if (_channel != null && _state == WsState.connected) {
      try {
        _channel!.sink.add(jsonEncode(data));
      } catch (_) {
        _setState(WsState.disconnected);
        _scheduleReconnect();
      }
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), connect);
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _channel?.sink.close();
    _eventController.close();
    _stateController.close();
  }
}
