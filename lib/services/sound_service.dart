import 'package:flutter/foundation.dart';
import 'dart:js_interop';

/// C&C-inspired sound effects using real MP3/WAV files.
/// Sound files in web/sounds/ — played via HTML5 Audio API.
class SoundService {
  static final SoundService _instance = SoundService._();
  static SoundService get instance => _instance;
  SoundService._();

  bool enabled = true;

  // === C&C Event Sounds (Real MP3/WAV) ===

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

  // === Voice Lines (Seva/Aeva/Ieva WAV) ===

  /// Terminal starts processing — Seva "Building"
  void playSevaBuilding() => _playFile('Seva_Building', isWav: true);

  /// Terminal finishes — Aeva "Construction Complete"
  void playAevaComplete() => _playFile('Aeva_ConComplete', isWav: true);

  /// Session/tab selected — Ieva "Resuming"
  void playIevaResuming() => _playFile('Ieva_Resuming', isWav: true);

  // === Synth Sounds ===

  /// 90s dial-up modem connection sound (hacking animation)
  void playDialUp() => _playDialUpModem();

  /// Navigation click (synth — instant, no loading latency)
  void playClick() => _playSynth();

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

  void _playFile(String name, {bool isWav = false}) {
    if (!enabled || !kIsWeb) return;
    final ext = isWav ? 'wav' : 'mp3';
    try {
      _jsEval('(function(){var a=new Audio("sounds/${name}.${ext}");a.volume=0.4;a.play().catch(function(){})})()'.toJS);
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

  void _playDialUpModem() {
    if (!enabled || !kIsWeb) return;
    try {
      _jsPlayDialUp();
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

/// 90s dial-up modem sound — synthesized via Web Audio API
/// Simulates the iconic handshake: dial tone → dialing → carrier negotiation → data screech
void _jsPlayDialUp() {
  _jsEval('''(function(){
    var c=new (window.AudioContext||window.webkitAudioContext)();
    var vol=0.12;
    var t=c.currentTime;
    var dur=5.5;
    var master=c.createGain();
    master.gain.value=vol;
    master.connect(c.destination);

    // Phase 1: Dial tone (0-0.4s) — two sine waves (350+440 Hz)
    var d1=c.createOscillator();var d2=c.createOscillator();
    var dg=c.createGain();
    d1.frequency.value=350;d2.frequency.value=440;
    d1.type="sine";d2.type="sine";
    d1.connect(dg);d2.connect(dg);dg.connect(master);
    dg.gain.setValueAtTime(1,t);
    dg.gain.linearRampToValueAtTime(0,t+0.4);
    d1.start(t);d1.stop(t+0.4);
    d2.start(t);d2.stop(t+0.4);

    // Phase 2: DTMF dialing (0.5-1.2s) — rapid tone pairs
    var dtmfFreqs=[[697,1209],[770,1336],[852,1477],[941,1209],[697,1336],[770,1477]];
    for(var i=0;i<dtmfFreqs.length;i++){
      var ft=t+0.5+i*0.12;
      var o1=c.createOscillator();var o2=c.createOscillator();
      var tg=c.createGain();
      o1.frequency.value=dtmfFreqs[i][0];o2.frequency.value=dtmfFreqs[i][1];
      o1.type="sine";o2.type="sine";
      o1.connect(tg);o2.connect(tg);tg.connect(master);
      tg.gain.setValueAtTime(0.8,ft);
      tg.gain.setValueAtTime(0,ft+0.08);
      o1.start(ft);o1.stop(ft+0.08);
      o2.start(ft);o2.stop(ft+0.08);
    }

    // Phase 3: Carrier tone (1.4-2.2s) — 2100 Hz answer tone
    var ca=c.createOscillator();var cag=c.createGain();
    ca.frequency.value=2100;ca.type="sine";
    ca.connect(cag);cag.connect(master);
    cag.gain.setValueAtTime(0,t+1.4);
    cag.gain.linearRampToValueAtTime(0.6,t+1.5);
    cag.gain.setValueAtTime(0.6,t+2.1);
    cag.gain.linearRampToValueAtTime(0,t+2.2);
    ca.start(t+1.4);ca.stop(t+2.2);

    // Phase 4: Negotiation screech (2.3-4.5s) — sweeping frequencies + noise
    var sw=c.createOscillator();var swg=c.createGain();
    sw.type="sawtooth";
    sw.frequency.setValueAtTime(1200,t+2.3);
    sw.frequency.linearRampToValueAtTime(2400,t+2.8);
    sw.frequency.linearRampToValueAtTime(980,t+3.2);
    sw.frequency.linearRampToValueAtTime(1800,t+3.6);
    sw.frequency.linearRampToValueAtTime(1400,t+4.0);
    sw.frequency.exponentialRampToValueAtTime(2200,t+4.5);
    sw.connect(swg);swg.connect(master);
    swg.gain.setValueAtTime(0,t+2.3);
    swg.gain.linearRampToValueAtTime(0.5,t+2.5);
    swg.gain.setValueAtTime(0.5,t+4.0);
    swg.gain.linearRampToValueAtTime(0,t+4.5);
    sw.start(t+2.3);sw.stop(t+4.5);

    // Phase 4b: White noise burst during negotiation
    var bs=c.bufferSize||4096;
    var nb=c.createBuffer(1,c.sampleRate*2.2,c.sampleRate);
    var nd=nb.getChannelData(0);
    for(var j=0;j<nd.length;j++)nd[j]=(Math.random()*2-1)*0.3;
    var ns=c.createBufferSource();var ng=c.createGain();
    ns.buffer=nb;ns.connect(ng);ng.connect(master);
    ng.gain.setValueAtTime(0,t+2.3);
    ng.gain.linearRampToValueAtTime(0.25,t+2.6);
    ng.gain.setValueAtTime(0.25,t+4.0);
    ng.gain.linearRampToValueAtTime(0,t+4.5);
    ns.start(t+2.3);

    // Phase 5: Data handshake (4.5-5.5s) — rapid alternating tones
    for(var k=0;k<8;k++){
      var ht=t+4.5+k*0.12;
      var ho=c.createOscillator();var hg=c.createGain();
      ho.frequency.value=k%2===0?1200:2400;
      ho.type="square";
      ho.connect(hg);hg.connect(master);
      hg.gain.setValueAtTime(0.3,ht);
      hg.gain.linearRampToValueAtTime(0,ht+0.1);
      ho.start(ht);ho.stop(ht+0.1);
    }
  })()'''.toJS);
}
