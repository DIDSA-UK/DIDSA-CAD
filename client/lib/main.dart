import 'package:flutter/material.dart';

import 'connection_screen.dart';

void main() {
  runApp(const DidsaCadApp());
}

class DidsaCadApp extends StatelessWidget {
  const DidsaCadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIDSA-CAD',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      home: const ConnectionScreen(),
    );
  }
}
