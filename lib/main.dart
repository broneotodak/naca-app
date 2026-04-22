import 'package:flutter/material.dart';
import 'theme.dart';
import 'screens/home_screen.dart';
import 'screens/naca_dashboard.dart';

void main() {
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
      home: const NacaShell(),
    );
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
    HomeScreen(),      // Tab 0: Terminal (Lan's CCC)
    NacaDashboard(),   // Tab 1: Agent Dashboard
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentTab],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: HackerTheme.borderDim, width: 1)),
          color: HackerTheme.bgPanel,
        ),
        child: BottomNavigationBar(
          currentIndex: _currentTab,
          onTap: (i) => setState(() => _currentTab = i),
          backgroundColor: Colors.transparent,
          selectedItemColor: HackerTheme.green,
          unselectedItemColor: HackerTheme.dimText,
          selectedLabelStyle: HackerTheme.mono(size: 9),
          unselectedLabelStyle: HackerTheme.mono(size: 9, color: HackerTheme.dimText),
          elevation: 0,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.terminal, size: 20),
              label: 'TERMINAL',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard, size: 20),
              label: 'AGENTS',
            ),
          ],
        ),
      ),
    );
  }
}
