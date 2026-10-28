import 'package:flutter/material.dart';

import 'layout_mode.dart';

/// Marks that a panel is inside the dialog [showAdaptiveSheet] made on the desktop layout, so a panel built for the
/// bottom of the screen ([BottomToolPanelFrame]) draws as plain content there.
class AdaptiveSheetScope extends InheritedWidget {
  const AdaptiveSheetScope({super.key, required super.child});

  static bool isInside(BuildContext context) => context.getInheritedWidgetOfExactType<AdaptiveSheetScope>() != null;

  @override
  bool updateShouldNotify(AdaptiveSheetScope oldWidget) => false;
}

/// Desktop layout (D6, `docs/desktop-layout-scope.md` section 2): a bottom sheet on the phone layout, a centred dialog
/// on the desktop one. The same [builder] draws in both; the arguments mirror [showModalBottomSheet] (a few are
/// meaningless for a dialog and ignored there).
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  ShapeBorder? shape,
  Color? backgroundColor,
  bool enableDrag = true,
}) {
  if (!LayoutModeScope.isDesktop(context)) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      isScrollControlled: isScrollControlled,
      shape: shape,
      backgroundColor: backgroundColor,
      enableDrag: enableDrag,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) {
      final height = MediaQuery.sizeOf(dialogContext).height;
      return AdaptiveSheetScope(
        child: Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            key: const ValueKey('adaptive-sheet-dialog'),
            constraints: BoxConstraints(maxWidth: 560, maxHeight: height * 0.85),
            child: Builder(builder: builder),
          ),
        ),
      );
    },
  );
}
