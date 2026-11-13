import 'package:material_ui/material_ui.dart';

import 'home/home_screen.dart';
import 'home/home_theme.dart';
import 'layout/hardware_text_keys.dart';
import 'layout/layout_mode.dart';
import 'viewport3d/controls_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ControlsPreferences.load();
  await HomePreferences.load();
  runApp(const DidsaCadApp());
}

class DidsaCadApp extends StatelessWidget {
  const DidsaCadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIDSA-CAD',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      builder: (context, child) => LayoutModeHost(child: HardwareTextKeys(child: child ?? const SizedBox.shrink())),
      home: const HomeScreen(),
    );
  }
}
