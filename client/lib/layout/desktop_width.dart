import 'package:flutter/material.dart';

import 'layout_mode.dart';

/// Desktop layout (D6, `docs/desktop-layout-scope.md` section 4): on a big
/// window a form or settings screen stays a readable column instead of
/// stretching edge to edge. Phone layout: [child] as it is.
class DesktopMaxWidth extends StatelessWidget {
  const DesktopMaxWidth({super.key, required this.child, this.maxWidth = 720});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (!LayoutModeScope.isDesktop(context)) return child;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        key: const ValueKey('desktop-max-width'),
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
