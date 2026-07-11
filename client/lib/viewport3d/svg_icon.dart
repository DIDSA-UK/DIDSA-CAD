import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A tintable custom SVG glyph, dropped in wherever an `Icon(Icons.xxx)`
/// placeholder is being replaced by one of the approved hand-off icon sets
/// (see the sketch package's own `sketch_speed_dial.dart`/`sketch_ribbon.dart`
/// for the pattern this generalizes). Every source SVG uses `currentColor`
/// for its own fill/stroke, so a [ColorFilter] with [BlendMode.srcIn]
/// re-tints every non-transparent pixel uniformly - the same visual result
/// [Icon]'s own `color` gives a Material icon font glyph.
///
/// Defaults `color`/`size` to the ambient [IconTheme] exactly like [Icon]
/// itself does, so a bare `SvgIcon('assets/...svg')` drops into an existing
/// `leading: Icon(...)`/`child: Icon(...)` slot with the same look the
/// Material icon it replaces already had, no per-call-site theme lookup
/// needed.
class SvgIcon extends StatelessWidget {
  final String asset;
  final double? size;
  final Color? color;

  const SvgIcon(this.asset, {super.key, this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor = color ?? iconTheme.color ?? Colors.black;
    return SvgPicture.asset(
      asset,
      width: resolvedSize,
      height: resolvedSize,
      colorFilter: ColorFilter.mode(resolvedColor, BlendMode.srcIn),
    );
  }
}
