import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:js_interop';

/// C&C-inspired sound effects using Web Audio API synthesis.
/// Tones generated programmatically — no external audio files needed.
class SoundService {
  static final SoundService _instance = SoundService._();
  static SoundService get instance => _instance;
  SoundService._();

  bool enabled = true;

  // === C&C Event Sounds ===

  /// Session created / new agent spawned
  void playBuilding() => _play([
    _T(440, 0.1, 'square'), _T(550, 0.1, 'square'), _T(660, 0.15, 'square'),
  ]);

  /// Task/build completed successfully
  void playConstructionComplete() => _play([
    _T(523, 0.12, 'square'), _T(659, 0.12, 'square'), _T(784, 0.12, 'square'), _T(1047, 0.25, 'square'),
  ]);

  /// New command received
  void playNewUnit() => _play([
    _T(880, 0.08, 'sine'), _T(1100, 0.12, 'sine'),
  ]);

  /// Agent ready / session started
  void playUnitReady() => _play([
    _T(600, 0.1, 'sawtooth'), _T(800, 0.15, 'sawtooth'),
  ]);

  /// Command acknowledged
  void playAcknowledged() => _play([
    _T(700, 0.06, 'sine'), _T(900, 0.08, 'sine'),
  ]);

  /// Success / affirmative
  void playAffirmative() => _play([
    _T(440, 0.1, 'sine'), _T(554, 0.1, 'sine'), _T(659, 0.15, 'sine'),
  ]);

  /// Warning / degraded status
  void playWarning() => _play([
    _T(400, 0.15, 'sawtooth'), _T(350, 0.15, 'sawtooth'), _T(400, 0.15, 'sawtooth'),
  ]);

  /// Error / failure
  void playError() => _play([
    _T(300, 0.2, 'square'), _T(200, 0.3, 'square'),
  ]);

  /// Can't perform action
  void playInsufficientFunds() => _play([
    _T(350, 0.1, 'square'), _T(280, 0.1, 'square'), _T(220, 0.2, 'square'),
  ]);

  /// All tasks done
  void playMissionAccomplished() => _play([
    _T(523, 0.12, 'sine'), _T(659, 0.12, 'sine'), _T(784, 0.12, 'sine'),
    _T(1047, 0.15, 'sine'), _T(784, 0.08, 'sine'), _T(1047, 0.3, 'sine'),
  ]);

  /// Message sent
  void playSent() => _play([
    _T(800, 0.05, 'sine'), _T(1200, 0.08, 'sine'),
  ]);

  /// Navigation click
  void playClick() => _play([
    _T(1000, 0.03, 'sine'),
  ]);

  void _play(List<_T> tones) {
    if (!enabled) return;
    if (kIsWeb) {
      try {
        final jsonTones = tones.map((t) => {'freq': t.f, 'dur': t.d, 'type': t.w}).toList();
        _callNacaSound(jsonEncode(jsonTones).toJS);
      } catch (e) {
        debugPrint('[SFX] $e');
      }
    }
  }
}

@JS('eval')
external void _jsEval(JSString code);

void _callNacaSound(JSString tonesJson) {
  _jsEval('window.nacaSound($tonesJson)'.toJS);
}

class _T {
  final double f; // frequency
  final double d; // duration
  final String w; // waveform type
  const _T(this.f, this.d, this.w);
}
