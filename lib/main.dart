import 'package:flutter/material.dart';
import 'theme.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const CCCApp());
}

class CCCApp extends StatelessWidget {
  const CCCApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CCC',
      debugShowCheckedModeBanner: false,
      theme: HackerTheme.themeData,
      home: const HomeScreen(),
    );
  }
}
