import 'package:flutter/foundation.dart';
import 'dart:js_interop';

/// C&C-inspired sound effects using real MP3 files.
/// Sound files in web/sounds/ — played via HTML5 Audio API.
class SoundService {
  static final SoundService _instance = SoundService._();
  static SoundService get instance => _instance;
  SoundService._();

  bool enabled = true;

  // === C&C Event Sounds (Real MP3) ===

  /// Session started / agent processing / new build starting
  void playBuilding() => _playFile('Building_online');

  /// New notification / incoming command / WhatsApp message
  void playIncomingTransmission() => _playFile('Incoming_transmission');

  /// Task completed / PR merged / deploy done
  void playMissionAccomplished() => _playFile('Mission_accomplished');

  /// Error / task failed / deploy failed
  void playMissionFailed() => _playFile('Mission_failed');

  /// Agent upgraded / intent decomposed / approval completed
  void playUnitUpgraded() => _playFile('Unit_upgraded');

  /// Response received / PR created / build complete
  void playUpgradeComplete() => _playFile('Upgrade_complete');

  /// Sending prompt / command dispatched / processing
  void playUpgradeInProgress() => _playFile('Upgrade_inprogress');

  // === Legacy API (mapped to new sounds for backward compat) ===

  /// Task/build completed successfully
  void playConstructionComplete() => _playFile('Upgrade_complete');

  /// New command received
  void playNewUnit() => _playFile('Incoming_transmission');

  /// Agent ready / session started
  void playUnitReady() => _playFile('Building_online');

  /// Command acknowledged / dispatched
  void playAcknowledged() => _playFile('Upgrade_inprogress');

  /// Success / affirmative
  void playAffirmative() => _playFile('Unit_upgraded');

  /// Warning / degraded status
  void playWarning() => _playFile('Mission_failed');

  /// Error / failure
  void playError() => _playFile('Mission_failed');

  /// Can't perform action
  void playInsufficientFunds() => _playFile('Mission_failed');

  /// Message sent
  void playSent() => _playFile('Upgrade_inprogress');

  /// Navigation click (synth — instant, no loading latency)
  void playClick() => _playSynth();

  void _playFile(String name) {
    if (!enabled || !kIsWeb) return;
    try {
      _jsEval('(function(){var a=new Audio("sounds/${name}.mp3");a.volume=0.4;a.play().catch(function(){})})()'.toJS);
    } catch (e) {
      debugPrint('[SFX] $e');
    }
  }

  void _playSynth() {
    if (!enabled || !kIsWeb) return;
    try {
      _jsPlayClick();
    } catch (e) {
      debugPrint('[SFX] $e');
    }
  }
}

@JS('eval')
external void _jsEval(JSString code);

void _jsPlayClick() {
  _jsEval('''(function(){
    var c=new (window.AudioContext||window.webkitAudioContext)();
    var o=c.createOscillator();var g=c.createGain();
    o.connect(g);g.connect(c.destination);
    o.frequency.value=1000;o.type="sine";
    g.gain.value=0.1;
    o.start();o.stop(c.currentTime+0.03);
  })()'''.toJS);
}
