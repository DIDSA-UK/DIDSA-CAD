import 'package:flutter/material.dart';

import 'sketch_canvas.dart';
import 'sketch_construction_method_bar.dart';
import 'sketch_controller.dart';
import 'sketch_ribbon.dart';
import 'sketch_speed_dial.dart';

/// The 2D sketch screen: chained line/circle sketching against the live
/// backend, against a single Sketch. By default it creates a brand-new
/// Sketch on startup (see [SketchController.ensureSketch]); when
/// [adoptSketchId] is given instead - the case when this is pushed from
/// [PartScreen] for an existing SketchFeature - it initializes from that
/// already-created Sketch instead (see [SketchController.adoptSketch]).
class SketchScreen extends StatefulWidget {
  /// Overridable for tests, so they don't talk to the real backend.
  final SketchController? controller;

  /// If set, this screen edits the Sketch with this id instead of creating
  /// a new one.
  final String? adoptSketchId;

  /// Stage 12 item 9: the existing solid's mesh edges, already projected
  /// onto this Sketch's plane by the caller ([PartScreen], which is the
  /// only place that has both the Part's mesh and the plane) - empty when
  /// there's nothing to show (e.g. an empty Part, or this screen reached
  /// outside [PartScreen] at all, such as in isolated tests).
  final List<((double, double), (double, double))> referenceGhostSegments;

  const SketchScreen({
    super.key,
    this.controller,
    this.adoptSketchId,
    this.referenceGhostSegments = const [],
  });

  @override
  State<SketchScreen> createState() => _SketchScreenState();
}

class _SketchScreenState extends State<SketchScreen> {
  late final SketchController _controller;

  /// Stage 12 item 9's Hide/Show Reference Body toggle - in-memory only,
  /// same as PartScreen's `_referencePlanesHidden`. Defaults to shown.
  bool _referenceBodyHidden = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? SketchController();
    final adoptSketchId = widget.adoptSketchId;
    if (adoptSketchId != null) {
      _controller.adoptSketch(adoptSketchId);
    } else {
      _controller.ensureSketch();
    }
  }

  @override
  void dispose() {
    // Only dispose a controller this widget created itself - an injected
    // (e.g. test-owned, or PartScreen-owned) controller's lifecycle belongs
    // to its caller.
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
            Expanded(
              child: Stack(
                children: [
                  SketchCanvas(
                    controller: _controller,
                    referenceGhostSegments: widget.referenceGhostSegments,
                    referenceBodyHidden: _referenceBodyHidden,
                  ),
                  // SketchRibbon aligns and sizes itself (top-left,
                  // shrink-wrapped to its own content) - this just gives it
                  // room to do so without forcing a particular size.
                  Positioned.fill(child: SketchRibbon(controller: _controller)),
                  if (widget.referenceGhostSegments.isNotEmpty)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton.filled(
                        tooltip: _referenceBodyHidden ? 'Show Reference Body' : 'Hide Reference Body',
                        icon: Icon(_referenceBodyHidden ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _referenceBodyHidden = !_referenceBodyHidden),
                      ),
                    ),
                  // Tap-outside barrier: while the FAB menu is open, any tap
                  // outside the FAB itself (which sits above this in the
                  // Stack, so remains tappable) closes the menu instead of
                  // reaching the canvas underneath.
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      if (_controller.fabMenu == FabMenuState.closed) {
                        return const SizedBox.shrink();
                      }
                      return Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _controller.closeFabMenu,
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, _) {
                          if (_controller.mode == SketchMode.select) {
                            return const SizedBox.shrink();
                          }
                          final pill = Material(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Text(
                                _controller.modeLabel,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          );
                          return GestureDetector(
                            onTap: _controller.exitToSelectMode,
                            child: pill,
                          );
                        },
                      ),
                    ),
                  ),
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: SketchSpeedDial(controller: _controller),
                  ),
                  // Construction-method picker: flies up from the bottom
                  // whenever a draw tool is active, non-modal so taps still
                  // reach the canvas underneath (see
                  // SketchConstructionMethodBar's own doc comment for why).
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final visible = _controller.mode == SketchMode.draw;
                        return IgnorePointer(
                          ignoring: !visible,
                          child: AnimatedSlide(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            offset: visible ? Offset.zero : const Offset(0, 1),
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: visible ? 1 : 0,
                              child: SketchConstructionMethodBar(controller: _controller),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
