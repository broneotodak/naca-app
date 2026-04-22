import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme.dart';
import 'screens/dashboard_screen.dart';
import 'screens/siti_screen.dart';
import 'screens/home_screen.dart';
import 'screens/projects_screen.dart';
import 'screens/memory_screen.dart';
import 'screens/settings_screen.dart';
import 'services/realtime_service.dart';
import 'services/sound_service.dart';
import 'screens/lock_screen.dart';
import 'config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  // Initialize realtime subscriptions & sound service
  RealtimeService.instance.init();
  // SoundService is lazy — just ensure the singleton exists
  SoundService.instance;

  runApp(const NacaApp());
}

class NacaApp extends StatelessWidget {
  const NacaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NACA',
      debugShowCheckedModeBanner: false,
      theme: HackerTheme.themeData,
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();
  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    if (!_unlocked) {
      return LockScreen(onUnlocked: () => setState(() => _unlocked = true));
    }
    return const NacaShell();
  }
}

class NacaShell extends StatefulWidget {
  const NacaShell({super.key});

  @override
  State<NacaShell> createState() => _NacaShellState();
}

class _NacaShellState extends State<NacaShell> {
  int _currentTab = 0;

  final _screens = const [
    DashboardScreen(),  // Tab 0: Overview
    SitiScreen(),       // Tab 1: Siti WhatsApp
    HomeScreen(),       // Tab 2: Terminal (Lan's CCC)
    ProjectsScreen(),   // Tab 3: Projects
    MemoryScreen(),     // Tab 4: Memory
    SettingsScreen(),   // Tab 5: Settings
  ];

  static const _navItems = [
    _NavItem(Icons.dashboard_rounded, 'HQ'),
    _NavItem(Icons.smart_toy_rounded, 'SITI'),
    _NavItem(Icons.terminal_rounded, 'TERM'),
    _NavItem(Icons.folder_rounded, 'PROJ'),
    _NavItem(Icons.memory_rounded, 'MEM'),
    _NavItem(Icons.settings_rounded, 'CFG'),
  ];

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 768;

    return Scaffold(
      body: Row(
        children: [
          // Desktop side rail
          if (!isMobile) _buildSideRail(),
          // Main content
          Expanded(child: _screens[_currentTab]),
        ],
      ),
      // Mobile bottom nav
      bottomNavigationBar: isMobile ? _buildBottomNav() : null,
    );
  }

  Widget _buildSideRail() {
    return Container(
      width: 64,
      decoration: const BoxDecoration(
        color: HackerTheme.bgPanel,
        border: Border(right: BorderSide(color: HackerTheme.borderDim, width: 1)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Logo
          Container(
            padding: const EdgeInsets.all(8),
            child: Text('N', style: HackerTheme.mono(size: 22, color: HackerTheme.green)),
          ),
          Container(height: 1, color: HackerTheme.borderDim, margin: const EdgeInsets.symmetric(horizontal: 12)),
          const SizedBox(height: 8),
          // Nav items
          ...List.generate(_navItems.length, (i) => _buildRailItem(i)),
          const Spacer(),
          // Status dot
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            width: 8, height: 8,
            decoration: const BoxDecoration(
              color: HackerTheme.green,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: HackerTheme.greenGlow, blurRadius: 6)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRailItem(int index) {
    final selected = _currentTab == index;
    final item = _navItems[index];
    return Tooltip(
      message: item.label,
      child: InkWell(
        onTap: () { SoundService.instance.playClick(); setState(() => _currentTab = index); },
        child: Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? HackerTheme.green : Colors.transparent,
                width: 2,
              ),
            ),
            color: selected ? HackerTheme.greenDim : Colors.transparent,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: 20, color: selected ? HackerTheme.green : HackerTheme.dimText),
              const SizedBox(height: 2),
              Text(item.label, style: HackerTheme.monoNoGlow(
                size: 8,
                color: selected ? HackerTheme.green : HackerTheme.dimText,
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: HackerTheme.borderDim, width: 1)),
        color: HackerTheme.bgPanel,
      ),
      child: SafeArea(
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(_navItems.length, (i) {
              final selected = _currentTab == i;
              final item = _navItems[i];
              return GestureDetector(
                onTap: () => setState(() => _currentTab = i),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 52,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icon, size: 18, color: selected ? HackerTheme.green : HackerTheme.dimText),
                      const SizedBox(height: 2),
                      Text(item.label, style: HackerTheme.monoNoGlow(
                        size: 7,
                        color: selected ? HackerTheme.green : HackerTheme.dimText,
                      )),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}
