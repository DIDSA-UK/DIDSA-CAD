import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pattern/Mirror scoping's Phase 3 (`docs/pattern-mirror-scope.md` §2.4/
/// §4): which layout [PatternSkipGrid] renders - Rectangular's own
/// row-major `i * count_2 + j` grid, or Circular's own angular-step ring.
enum PatternSkipGridLayout { rectangular, radial }

/// The clickable dot-grid picker inside [PatternPanel] for suppressing
/// individual pattern instances without deleting the whole pattern -
/// mirrors SolidWorks/Fusion's own pattern-preview dot-grid convention.
///
/// [totalCount] is the pattern's own total instance count (Rectangular's
/// `count_1 * count_2`; Circular's `count_angular`) - index `0` (the
/// untouched seed Body, never suppressible - see the backend's
/// `PatternFeature.skip_indices` own docstring) is always shown filled and
/// non-interactive; every other index `1..totalCount-1` is tappable,
/// filled when active (not in [skipIndices]) and hollow when skipped.
///
/// [layout] picks between a rectangular grid ([columns] = Rectangular's
/// own `count_2`, rows implied by `totalCount / columns`) and a radial
/// ring spanning [angleTotal] degrees (Circular's own `angle_total`,
/// meaningless for [PatternSkipGridLayout.rectangular]) - both rendered as
/// plain `Positioned`/`Wrap`-friendly dot widgets rather than a
/// `CustomPainter` (the scope doc's own original note suggested one for
/// the radial case): discrete widgets give the identical visual result
/// with free hit-testing and no custom pointer-math needed.
class PatternSkipGrid extends StatelessWidget {
  final PatternSkipGridLayout layout;
  final int totalCount;
  final int columns;
  final double angleTotal;
  final Set<int> skipIndices;
  final void Function(int index) onToggle;

  const PatternSkipGrid({
    super.key,
    required this.layout,
    required this.totalCount,
    this.columns = 1,
    this.angleTotal = 360.0,
    required this.skipIndices,
    required this.onToggle,
  });

  static const double _dotSize = 22.0;

  Widget _dot(BuildContext context, int index) {
    final isSeed = index == 0;
    final isSkipped = !isSeed && skipIndices.contains(index);
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: isSeed ? 'Seed (always included)' : (isSkipped ? 'Skipped - tap to include' : 'Tap to skip'),
      child: GestureDetector(
        key: ValueKey('pattern-skip-dot-$index'),
        onTap: isSeed ? null : () => onToggle(index),
        child: Container(
          width: _dotSize,
          height: _dotSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSkipped ? Colors.transparent : primary,
            border: Border.all(color: primary, width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget _buildRectangular(BuildContext context) {
    final rows = (totalCount / columns).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var j = 0; j < columns; j++)
                  if (i * columns + j < totalCount)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: _dot(context, i * columns + j),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildRadial(BuildContext context) {
    const size = 120.0;
    const radius = 44.0;
    final stepRadians = math.pi / 180.0 * (angleTotal / totalCount);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          for (var i = 0; i < totalCount; i++)
            Builder(
              builder: (context) {
                // Starts at the top (-90 degrees) purely as a legible,
                // fixed drawing convention for this abstract picker - it
                // does not need to (and, since OCCT's own CW/CCW rotation
                // direction for a given axis is never assumed elsewhere in
                // this codebase either, cannot reliably) match the actual
                // 3D rotation direction.
                final angle = stepRadians * i - math.pi / 2;
                final dx = radius * math.cos(angle);
                final dy = radius * math.sin(angle);
                return Positioned(
                  left: size / 2 + dx - _dotSize / 2,
                  top: size / 2 + dy - _dotSize / 2,
                  child: _dot(context, i),
                );
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Fewer than 2 total instances means there is nothing to suppress at
    // all (matches the backend's own `count_1 * count_2 >= 2`/
    // `count_angular >= 2` no-op guards) - render nothing rather than a
    // single, permanently-non-interactive seed dot.
    if (totalCount <= 1) return const SizedBox.shrink();
    return layout == PatternSkipGridLayout.radial ? _buildRadial(context) : _buildRectangular(context);
  }
}
