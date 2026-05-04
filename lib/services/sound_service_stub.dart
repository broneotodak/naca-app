import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Cross-platform SoundService for iOS / macOS / Android — replaces the
/// previous no-op. Plays bundled `assets/sounds/<name>.<ext>` via the
/// audioplayers package. Web target uses sound_service_web.dart instead
/// (JS Audio API), via the conditional export in sound_service.dart.
class SoundService {
  static final SoundService _instance = SoundService._();
  static SoundService get instance => _instance;
  SoundService._();

  bool enabled = true;

  // === C&C event sounds ===
  void playBuilding() => _playFile('Building_online');
  void playIncomingTransmission() => _playFile('Incoming_transmission');
  void playMissionAccomplished() => _playFile('Mission_accomplished');
  void playMissionFailed() => _playFile('Mission_failed');
  void playUnitUpgraded() => _playFile('Unit_upgraded');
  void playUpgradeComplete() => _playFile('Upgrade_complete');
  void playUpgradeInProgress() => _playFile('Upgrade_inprogress');

  // === Voice lines ===
  void playSevaBuilding() => _playFile('Seva_Building', ext: 'm4a');
  void playAevaComplete() => _playFile('Aeva_ConComplete', ext: 'm4a');
  void playIevaResuming() => _playFile('Ieva_Resuming', ext: 'm4a');

  // === Synth / clicks ===
  void playDialUp() => _playFile('Building_online'); // no synth dial-up port
  void playClick() => _playFile('Button_click');

  // === Legacy API mapping ===
  void playConstructionComplete() => _playFile('Upgrade_complete');
  void playNewUnit() => _playFile('Incoming_transmission');
  void playUnitReady() => _playFile('Building_online');
  void playAcknowledged() => _playFile('Upgrade_inprogress');
  void playAffirmative() => _playFile('Unit_upgraded');
  void playWarning() => _playFile('Mission_failed');
  void playError() => _playFile('Mission_failed');
  void playInsufficientFunds() => _playFile('Mission_failed');
  void playSent() => _playFile('Upgrade_inprogress');

  /// Plays a bundled sound. Each call gets its own AudioPlayer so overlapping
  /// triggers (rapid clicks, simultaneous events) don't cancel each other.
  /// AudioPlayer is disposed automatically once playback completes.
  void _playFile(String name, {String ext = 'mp3'}) {
    if (!enabled) return;
    try {
      final player = AudioPlayer();
      player.setReleaseMode(ReleaseMode.release);
      player.play(AssetSource('sounds/$name.$ext'), volume: 0.4);
    } catch (e) {
      debugPrint('[SFX] $e');
    }
  }
}
