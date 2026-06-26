import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stage 21 item 1/2: shared AppBar `leading` widget for the light-background
/// screens ([PartScreen], [SketchScreen]) - the dark logo variant (for
/// contrast against the off-white AppBar, unlike [ConnectionScreen]'s dark
/// background, which keeps using the light logo and is untouched by this
/// widget), tappable through to the DIDSA website.
class DidsaLogoButton extends StatelessWidget {
  const DidsaLogoButton({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse('https://www.didsa.uk'), mode: LaunchMode.externalApplication),
      child: Image.asset(
        'assets/images/didsa_logo_dark.png',
        height: 32,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            const Text('DIDSA', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
