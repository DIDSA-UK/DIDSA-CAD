import 'package:flutter/material.dart';

import 'connection_screen.dart';
import 'layout/layout_mode.dart';
import 'viewport3d/controls_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ControlsPreferences.load();
  runApp(const DidsaCadApp());
}

class DidsaCadApp extends StatelessWidget {
  const DidsaCadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIDSA-CAD',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      builder: (context, child) => LayoutModeHost(child: child ?? const SizedBox.shrink()),
      home: const ConnectionScreen(),
    );
  }
}
