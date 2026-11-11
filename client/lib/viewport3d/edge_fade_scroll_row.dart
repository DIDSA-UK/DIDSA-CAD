import 'package:material_ui/material_ui.dart';

/// A horizontally scrolling row whose ends fade out while more content lies past them, so a row wider than its
/// container looks scrollable instead of cut off (Flutter-testing feedback 2026-11-11, item 4: the sketch orientation
/// pill's buttons slid past the pill's rounded ends). Put it inside a clipped, rounded parent (`Material` with
/// `clipBehavior`); the fade is only a hint, the clip is what keeps the content inside.
class EdgeFadeScrollRow extends StatefulWidget {
  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  /// How far (in dp) the fade reaches into the content.
  final double fadeExtent;

  const EdgeFadeScrollRow({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
    this.fadeExtent = 20,
  });

  @override
  State<EdgeFadeScrollRow> createState() => _EdgeFadeScrollRowState();
}

class _EdgeFadeScrollRowState extends State<EdgeFadeScrollRow> {
  final ScrollController _controller = ScrollController();
  bool _moreBefore = false;
  bool _moreAfter = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
    // The extent is only known after the first layout.
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final before = position.pixels > 0.5;
    final after = position.pixels < position.maxScrollExtent - 0.5;
    if (before != _moreBefore || after != _moreAfter) {
      setState(() {
        _moreBefore = before;
        _moreAfter = after;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _update());
        return false;
      },
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: Row(mainAxisSize: MainAxisSize.min, children: widget.children),
      ),
    );
    if (!_moreBefore && !_moreAfter) return row;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final f = (widget.fadeExtent / (bounds.width <= 0 ? 1 : bounds.width)).clamp(0.0, 0.5);
        return LinearGradient(
          colors: [
            _moreBefore ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            _moreAfter ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
          ],
          stops: [0, f, 1 - f, 1],
        ).createShader(bounds);
      },
      child: row,
    );
  }
}
