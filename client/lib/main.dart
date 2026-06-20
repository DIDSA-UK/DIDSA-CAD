import 'package:flutter/material.dart';

import 'sketch/sketch_canvas.dart';
import 'sketch/sketch_controller.dart';
import 'sketch/sketch_speed_dial.dart';

void main() {
  runApp(const DidsaCadApp());
}

class DidsaCadApp extends StatelessWidget {
  /// Overridable for tests, so they don't talk to the real backend.
  final SketchController? controller;

  const DidsaCadApp({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIDSA-CAD',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true),
      home: SketchScreen(controller: controller),
    );
  }
}

/// Stage 4: chained line sketching against the live backend. A Sketch is
/// created on the XY plane on startup; each completed Line triggers a real
/// solve call, and rendering always reflects the backend's solved Point
/// positions, never just the client's own local tracking.
class SketchScreen extends StatefulWidget {
  /// Overridable for tests, so they don't talk to the real backend.
  final SketchController? controller;

  const SketchScreen({super.key, this.controller});

  @override
  State<SketchScreen> createState() => _SketchScreenState();
}

class _SketchScreenState extends State<SketchScreen> {
  late final SketchController _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? SketchController();
    _controller.ensureSketch();
  }

  @override
  void dispose() {
    // Only dispose a controller this widget created itself - an injected
    // (e.g. test-owned) controller's lifecycle belongs to its caller.
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DIDSA-CAD Sketch')),
      body: SafeArea(
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                if (_controller.errorMessage == null) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  color: Colors.red.shade100,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    _controller.errorMessage!,
                    style: TextStyle(color: Colors.red.shade900),
                  ),
                );
              },
            ),
            Expanded(child: SketchCanvas(controller: _controller)),
          ],
        ),
      ),
      floatingActionButton: SketchSpeedDial(controller: _controller),
    );
  }
}
