import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../services/sound_service.dart';

class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const LockScreen({super.key, required this.onUnlocked});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with TickerProviderStateMixin {
  static const _correctPin = '404282';

  String _pin = '';
  bool _error = false;
  bool _unlocking = false;
  int _hackStep = 0;
  Timer? _hackTimer;
  final _random = Random();

  // Hacking sequence messages
  static const _hackMessages = [
    'INITIALIZING NEURAL INTERFACE...',
    'BYPASSING FIREWALL [████████░░] 80%',
    'SCANNING NETWORK NODES... 7 AGENTS FOUND',
    'READING /etc/shadow... ACCESS DENIED',
    'INJECTING TROJAN.NACA.V2 INTO KERNEL...',
    'DECRYPTING RSA-4096... ████████████ DONE',
    'DOWNLOADING BRAIN.DB... 893 FACTS LOADED',
    'HIJACKING WHATSAPP SESSION +60126714634...',
    'LOADING PERSONALITY MATRIX... 14 TRAITS',
    'CONNECTING TO SATELLITE UPLINK...',
    'SPOOFING MAC ADDRESS... FF:FF:FF:FF:FF:FF',
    'COMPILING EXPLOIT FOR CVE-2026-NACA...',
    'ESTABLISHING REVERSE SHELL ON PORT 1337...',
    'READING NEO\'S MEMORIES... 907 ENTRIES FOUND',
    'ACCESS GRANTED. WELCOME, COMMANDER.',
  ];

  List<String> _visibleHackLines = [];

  void _onDigit(String digit) {
    if (_unlocking || _pin.length >= 6) return;
    SoundService.instance.playClick();
    setState(() {
      _pin += digit;
      _error = false;
    });
    if (_pin.length == 6) {
      _checkPin();
    }
  }

  void _onDelete() {
    if (_unlocking || _pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = false;
    });
  }

  void _checkPin() {
    if (_pin == _correctPin) {
      _startHackSequence();
    } else {
      SoundService.instance.playError();
      setState(() => _error = true);
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) setState(() { _pin = ''; _error = false; });
      });
    }
  }

  void _startHackSequence() {
    setState(() => _unlocking = true);
    SoundService.instance.playDialUp(); // 90s modem sound during hacking animation

    _hackTimer = Timer.periodic(const Duration(milliseconds: 350), (timer) {
      if (_hackStep >= _hackMessages.length) {
        timer.cancel();
        SoundService.instance.playBuilding(); // "Building online" after unlock
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) widget.onUnlocked();
        });
        return;
      }
      if (mounted) {
        setState(() {
          _visibleHackLines.add(_hackMessages[_hackStep]);
          _hackStep++;
        });
      }
    });
  }

  @override
  void dispose() {
    _hackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HackerTheme.bg,
      body: SafeArea(
        child: _unlocking ? _buildHackSequence() : _buildPinEntry(),
      ),
    );
  }

  // ── PIN ENTRY ──

  Widget _buildPinEntry() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo
          Text('N A C A', style: HackerTheme.mono(size: 28, color: HackerTheme.green)),
          const SizedBox(height: 4),
          Text('NEO AGENTIC CENTRE', style: HackerTheme.monoNoGlow(size: 10, color: HackerTheme.dimText)),
          const SizedBox(height: 40),

          // Pin dots
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(6, (i) {
              final filled = i < _pin.length;
              final isError = _error;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 16, height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isError
                      ? HackerTheme.red
                      : filled
                          ? HackerTheme.green
                          : Colors.transparent,
                  border: Border.all(
                    color: isError ? HackerTheme.red : HackerTheme.green,
                    width: 1.5,
                  ),
                  boxShadow: filled && !isError
                      ? [const BoxShadow(color: HackerTheme.greenGlow, blurRadius: 8)]
                      : null,
                ),
              );
            }),
          ),
          const SizedBox(height: 12),
          Text(
            _error ? 'ACCESS DENIED' : 'ENTER ACCESS CODE',
            style: HackerTheme.monoNoGlow(size: 10, color: _error ? HackerTheme.red : HackerTheme.dimText),
          ),
          const SizedBox(height: 32),

          // Numpad
          SizedBox(
            width: 280,
            child: Column(
              children: [
                _numRow(['1', '2', '3']),
                const SizedBox(height: 12),
                _numRow(['4', '5', '6']),
                const SizedBox(height: 12),
                _numRow(['7', '8', '9']),
                const SizedBox(height: 12),
                _numRow(['', '0', 'DEL']),
              ],
            ),
          ),

          const SizedBox(height: 40),
          // Scanline effect text
          Text('// CLASSIFIED SYSTEM', style: HackerTheme.monoNoGlow(size: 8, color: HackerTheme.borderDim)),
        ],
      ),
    );
  }

  Widget _numRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((d) {
        if (d.isEmpty) return const SizedBox(width: 72, height: 52);
        if (d == 'DEL') {
          return GestureDetector(
            onTap: _onDelete,
            child: Container(
              width: 72, height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: HackerTheme.borderDim),
              ),
              child: const Icon(Icons.backspace_outlined, size: 18, color: HackerTheme.dimText),
            ),
          );
        }
        return GestureDetector(
          onTap: () => _onDigit(d),
          child: Container(
            width: 72, height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: HackerTheme.borderDim),
              color: HackerTheme.bgCard,
            ),
            child: Text(d, style: HackerTheme.mono(size: 20, color: HackerTheme.green)),
          ),
        );
      }).toList(),
    );
  }

  // ── HACKING SEQUENCE ──

  Widget _buildHackSequence() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('root@naca:~# ./breach.sh', style: HackerTheme.mono(size: 14, color: HackerTheme.green)),
          const SizedBox(height: 4),
          Text('Password: ******', style: HackerTheme.monoNoGlow(size: 12, color: HackerTheme.dimText)),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.builder(
              itemCount: _visibleHackLines.length,
              itemBuilder: (ctx, i) {
                final line = _visibleHackLines[i];
                final isLast = i == _visibleHackLines.length - 1;
                final isSuccess = line.contains('ACCESS GRANTED');

                Color lineColor;
                if (isSuccess) {
                  lineColor = HackerTheme.green;
                } else if (line.contains('DENIED') || line.contains('TROJAN') || line.contains('EXPLOIT') || line.contains('HIJACKING') || line.contains('SPOOFING')) {
                  lineColor = HackerTheme.red;
                } else if (line.contains('DONE') || line.contains('FOUND') || line.contains('LOADED')) {
                  lineColor = HackerTheme.cyan;
                } else {
                  lineColor = HackerTheme.amber;
                }

                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSuccess ? '[OK] ' : isLast ? '[>>] ' : '[${_random.nextInt(99).toString().padLeft(2, '0')}] ',
                        style: HackerTheme.monoNoGlow(size: 11, color: HackerTheme.dimText),
                      ),
                      Expanded(
                        child: Text(
                          line,
                          style: HackerTheme.monoNoGlow(
                            size: 11,
                            color: isLast ? lineColor : lineColor.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_hackStep < _hackMessages.length)
            const LinearProgressIndicator(
              color: HackerTheme.green,
              backgroundColor: HackerTheme.bgCard,
              minHeight: 2,
            ),
        ],
      ),
    );
  }
}
