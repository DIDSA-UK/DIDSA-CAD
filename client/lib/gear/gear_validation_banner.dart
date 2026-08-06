import 'package:flutter/material.dart';

/// `00-conventions.md`'s non-blocking validation banner convention - a
/// small colored/iconed message strip, shared by every Gear Design screen
/// ([GearDesignScreen], [GearChainDesignScreen]) rather than each having
/// its own private copy (originally [GearDesignScreen]'s own private
/// `_Banner`, promoted here once a second screen needed the identical
/// widget).
class GearValidationBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;

  const GearValidationBanner({super.key, required this.color, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12))),
        ],
      ),
    );
  }
}
