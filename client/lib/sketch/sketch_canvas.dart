import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../api/sketch_api_client.dart';
import 'plane_indicator.dart';
import 'sketch_controller.dart';
import 'sketch_viewport.dart';
import 'view_transform.dart';

/// The 2D sketch canvas: renders the cursor, Points, Lines, and the
/// snap-to-start indicator, and turns raw pointer events into the unified
/// cursor model (relative+scaled for touch, absolute 1:1 for a real mouse),
/// plus pan/zoom (pinch and two-finger drag on touch; scroll wheel and
/// right-click-drag on a mouse) that only ever adjusts [_viewport] - the
/// controller's cursor stays in sketch-space coordinates throughout, so it
/// is never "converted back" and is unaffected by how the view is panned
/// or zoomed.
class SketchCanvas extends StatefulWidget {
  final SketchController controller;

  /// The active Sketch plane's already-projected ghost wireframe (Stage 12
  /// item 9) - plain 2D coordinate pairs in this Sketch's own local space
  /// (see `projectMeshEdgesOntoPlane` in viewport3d/sketch_geometry_3d.dart,
  /// which computes these from the Part's mesh before this widget is ever
  /// built). Empty when there's no existing solid yet, or this isn't being
  /// opened from [PartScreen] at all.
  final List<((double, double), (double, double))> referenceGhostSegments;

  /// Stage 12 item 9's Hide/Show Reference Body toggle - owned by
  /// [SketchScreen] (mirrors `PartScreen._referencePlanesHidden`'s pattern),
  /// just threaded through here for the painter to honor.
  final bool referenceBodyHidden;

  const SketchCanvas({
    super.key,
    required this.controller,
    this.referenceGhostSegments = const [],
    this.referenceBodyHidden = false,
  });

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> {
  final SketchViewport _viewport = SketchViewport();

  /// Live touch pointers by id, for pinch-zoom/two-finger-pan - tracked
  /// separately from the single-finger cursor drag, which only applies
  /// while exactly one touch is active.
  final Map<int, Offset> _activeTouches = {};

  /// Cumulative single-finger travel (pixels) since the touch that's about
  /// to end started - used to tell a tap (select gesture) apart from a
  /// cursor-drag. Reset whenever a fresh single-finger touch begins.
  double _singleTouchTravel = 0;

  /// Set once a second finger has touched down during the current gesture,
  /// so the tail end of a pinch (as fingers lift one by one) is never
  /// mistaken for a single tap.
  bool _multiTouchOccurred = false;

  /// How far (pixels) a single-finger touch may travel and still count as
  /// a tap rather than a drag.
  static const double _tapTravelThreshold = 10.0;

  void _handlePointerHover(PointerHoverEvent event, ViewTransform transform) {
    // Hover events only fire for a mouse with no buttons pressed - real
    // mouse movement drives the cursor directly, 1:1.
    if (event.kind != PointerDeviceKind.mouse) return;
    widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
  }

  /// Stage 13 item 3's single dispatch point for "what does a tap at this
  /// screen location do": in [SketchMode.dimension], a tap on an already
  /// rendered ghost's label either opens its inline value input or - if a
  /// different ghost's input is already open - cancels that edit; any other
  /// tap (every other mode, or a dimension-mode tap that misses every
  /// ghost) goes to [SketchController.handleCanvasTap] with the tapped
  /// location converted to sketch-space and a touch-sized hit radius, so
  /// the actual commit/select/dimension-pick always happens at the tap's
  /// own screen position rather than wherever a (possibly stale, for touch)
  /// persistent cursor happens to be.
  void _dispatchTap(Offset screenPosition, ViewTransform transform) {
    final controller = widget.controller;
    if (controller.mode == SketchMode.dimension) {
      final hitKey = _ghostKeyAt(controller, transform, screenPosition);
      if (controller.activeGhostKey != null) {
        if (hitKey != controller.activeGhostKey) {
          controller.cancelGhostEdit();
        }
        return;
      }
      if (hitKey != null) {
        controller.tapGhost(hitKey);
        return;
      }
    }
    final coord = transform.screenToSketch(screenPosition.dx, screenPosition.dy);
    final hitRadius = controller.hitRadiusForPixelsPerUnit(transform.pixelsPerUnit);
    controller.handleCanvasTap(coord.x, coord.y, hitRadius);
  }

  void _handlePointerDown(PointerDownEvent event, ViewTransform transform) {
    if (event.kind == PointerDeviceKind.mouse) {
      // Only the primary (left) button counts as a bare tap, same as a
      // touch tap - a right-click starts a pan drag instead (see
      // _handlePointerMove) and must not also dispatch a tap.
      if (event.buttons & kPrimaryMouseButton != 0) {
        _dispatchTap(event.localPosition, transform);
      }
      return;
    }
    // Touch-down never commits a point by itself - only a tap (a touch that
    // lifts again without much travel, see _handlePointerEnd) does that -
    // but is tracked here so a second finger touching down is seen by the
    // pinch/pan handling below, and so a single-finger touch ending without
    // much travel can be recognized as a tap.
    _activeTouches[event.pointer] = event.localPosition;
    if (_activeTouches.length == 1) {
      _singleTouchTravel = 0;
      _multiTouchOccurred = false;
    } else {
      _multiTouchOccurred = true;
    }
  }

  void _handlePointerMove(PointerMoveEvent event, ViewTransform transform, Size size) {
    if (event.kind == PointerDeviceKind.mouse) {
      if (event.buttons & kSecondaryMouseButton != 0) {
        setState(() => _viewport.panByScreenDelta(event.delta));
      } else {
        widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
      }
      return;
    }

    if (_activeTouches.length < 2) {
      // Single-finger: relative, scaled cursor movement - a live preview
      // only (e.g. the crosshair, chain-start snap highlight); it no longer
      // determines where a tap commits - see _dispatchTap, which always
      // uses the lifted touch's own screen position instead.
      _singleTouchTravel += event.delta.distance;
      widget.controller.moveCursorRelative(event.delta.dx, event.delta.dy, _viewport.zoom);
      return;
    }

    _multiTouchOccurred = true;
    final before = Map<int, Offset>.from(_activeTouches);
    _activeTouches[event.pointer] = event.localPosition;
    _applyPinchPan(before, _activeTouches, size);
  }

  void _handlePointerEnd(PointerEvent event, ViewTransform transform) {
    if (event.kind == PointerDeviceKind.mouse) return;

    // A lone finger lifting (not the tail end of a pinch) after barely
    // moving is a tap - the select/draw/dimension gesture - rather than a
    // drag.
    final wasTap = event is PointerUpEvent &&
        _activeTouches.length == 1 &&
        !_multiTouchOccurred &&
        _singleTouchTravel < _tapTravelThreshold;
    final tapPosition = event.localPosition;
    _activeTouches.remove(event.pointer);
    if (wasTap) {
      _dispatchTap(tapPosition, transform);
    }
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is PointerScrollEvent) {
      // Scrolling "down" (positive dy) zooms out, matching common map/CAD
      // tool conventions.
      final scaleFactor = event.scrollDelta.dy > 0 ? 0.9 : 1 / 0.9;
      setState(() => _viewport.zoomAtScreenPoint(event.localPosition, scaleFactor, size));
    }
  }

  void _applyPinchPan(Map<int, Offset> before, Map<int, Offset> after, Size size) {
    final beforeCentroid = _centroidOf(before.values);
    final afterCentroid = _centroidOf(after.values);
    final beforeSpread = _averageSpread(before.values, beforeCentroid);
    final afterSpread = _averageSpread(after.values, afterCentroid);
    final scaleFactor = beforeSpread > 1e-6 ? afterSpread / beforeSpread : 1.0;

    setState(() {
      _viewport.applyAnchoredZoomPan(
        anchorScreen: beforeCentroid,
        targetScreen: afterCentroid,
        scaleFactor: scaleFactor,
        size: size,
      );
    });
  }

  Offset _centroidOf(Iterable<Offset> points) {
    var sum = Offset.zero;
    for (final point in points) {
      sum += point;
    }
    return sum / points.length.toDouble();
  }

  double _averageSpread(Iterable<Offset> points, Offset centroid) {
    if (points.length < 2) return 0;
    var total = 0.0;
    for (final point in points) {
      total += (point - centroid).distance;
    }
    return total / points.length;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final transform = _viewport.transformFor(size);
        return Stack(
          children: [
            Listener(
              onPointerDown: (e) => _handlePointerDown(e, transform),
              onPointerHover: (e) => _handlePointerHover(e, transform),
              onPointerMove: (e) => _handlePointerMove(e, transform, size),
              onPointerUp: (e) => _handlePointerEnd(e, transform),
              onPointerCancel: (e) => _handlePointerEnd(e, transform),
              onPointerSignal: (e) => _handlePointerSignal(e, size),
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) {
                  return CustomPaint(
                    size: size,
                    painter: _SketchPainter(
                      controller: widget.controller,
                      transform: transform,
                      referenceGhostSegments: widget.referenceGhostSegments,
                      referenceBodyHidden: widget.referenceBodyHidden,
                    ),
                  );
                },
              ),
            ),
            AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) {
                final key = widget.controller.activeGhostKey;
                if (key == null) return const SizedBox.shrink();
                DimensionGhost? ghost;
                for (final candidate in widget.controller.ghosts) {
                  if (candidate.key == key) {
                    ghost = candidate;
                    break;
                  }
                }
                if (ghost == null) return const SizedBox.shrink();
                final layout = _layoutGhost(widget.controller, transform, ghost);
                if (layout == null) return const SizedBox.shrink();
                return _GhostValueEditor(
                  key: ValueKey(key),
                  controller: widget.controller,
                  ghost: ghost,
                  anchor: layout.labelCenter,
                );
              },
            ),
            if (_viewport.zoom != 1 || _viewport.panOffset != Offset.zero)
              Positioned(
                top: 8,
                left: 8,
                child: IconButton.filled(
                  tooltip: 'Reset view',
                  icon: const Icon(Icons.center_focus_strong),
                  onPressed: () => setState(_viewport.reset),
                ),
              ),
            Positioned(
              bottom: 8,
              left: 8,
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) => PlaneIndicator(plane: widget.controller.plane),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The screen-space geometry for one rendered [DimensionGhost] - shared by
/// the painter (drawing the dashed extension/dimension lines and the label
/// pill) and the canvas state (hit-testing a tap against the label, see
/// [_ghostKeyAt]), so the two never disagree about where a ghost actually
/// is on screen.
class _GhostLayout {
  final Offset labelCenter;
  final List<List<Offset>> segments;

  const _GhostLayout(this.labelCenter, this.segments);
}

/// How far (screen pixels) a ghost's dimension line sits offset from the
/// entity/points it measures - mirrors [_SketchPainter._paintDistanceDimension]'s
/// own `offsetDistance`, just renamed for this file's ghost-only geometry.
const double _ghostOffsetPixels = 20.0;

/// Computes [ghost]'s on-screen layout - null if either endpoint Point is
/// missing from [controller.points] (e.g. a stale ghost after a delete).
_GhostLayout? _layoutGhost(SketchController controller, ViewTransform transform, DimensionGhost ghost) {
  final a = controller.points[ghost.pointAId];
  final b = controller.points[ghost.pointBId];
  if (a == null || b == null) return null;
  final aScreen = transform.sketchToScreen(a.x, a.y);
  final bScreen = transform.sketchToScreen(b.x, b.y);

  switch (ghost.kind) {
    case GhostKind.length:
      final delta = bScreen - aScreen;
      final len = delta.distance;
      if (len < 1e-6) return null;
      final normal = Offset(-delta.dy, delta.dx) / len * _ghostOffsetPixels;
      final p1 = aScreen + normal;
      final p2 = bScreen + normal;
      return _GhostLayout((p1 + p2) / 2, [
        [aScreen, p1],
        [bScreen, p2],
        [p1, p2],
      ]);

    case GhostKind.vertical:
      final offsetX = math.max(aScreen.dx, bScreen.dx) + _ghostOffsetPixels + 4;
      final p1 = Offset(offsetX, aScreen.dy);
      final p2 = Offset(offsetX, bScreen.dy);
      return _GhostLayout((p1 + p2) / 2, [
        [aScreen, p1],
        [bScreen, p2],
        [p1, p2],
      ]);

    case GhostKind.horizontal:
      final offsetY = math.max(aScreen.dy, bScreen.dy) + _ghostOffsetPixels + 4;
      final p1 = Offset(aScreen.dx, offsetY);
      final p2 = Offset(bScreen.dx, offsetY);
      return _GhostLayout((p1 + p2) / 2, [
        [aScreen, p1],
        [bScreen, p2],
        [p1, p2],
      ]);

    case GhostKind.radius:
      return _GhostLayout((aScreen + bScreen) / 2, [
        [aScreen, bScreen],
      ]);

    case GhostKind.diameter:
      // The full diameter line through the center, offset perpendicular to
      // the radius vector so it reads as a distinct line from the radius
      // ghost's, rather than the same segment extended underneath it.
      final vector = bScreen - aScreen;
      final len = vector.distance;
      if (len < 1e-6) return null;
      final normal = Offset(-vector.dy, vector.dx) / len * 16.0;
      final opposite = aScreen - vector + normal;
      final far = bScreen + normal;
      return _GhostLayout((opposite + far) / 2, [
        [opposite, far],
      ]);
  }
}

/// How close (screen pixels) a tap must land to a ghost's label center to
/// count as tapping that ghost - generous, in the same spirit as Stage 13
/// item 3's 44px touch target, since a ghost's rendered pill is small.
const double _ghostHitRadiusPixels = 20.0;

/// The key of whichever currently-rendered ghost's label [screenPosition]
/// landed on, or null if it missed all of them - see
/// [_SketchCanvasState._dispatchTap].
String? _ghostKeyAt(SketchController controller, ViewTransform transform, Offset screenPosition) {
  for (final ghost in controller.ghosts) {
    final layout = _layoutGhost(controller, transform, ghost);
    if (layout == null) continue;
    if ((screenPosition - layout.labelCenter).distance <= _ghostHitRadiusPixels) {
      return ghost.key;
    }
  }
  return null;
}

/// The inline value-entry box for whichever ghost is currently
/// [SketchController.activeGhostKey] (Stage 13 item 5) - prefilled with the
/// ghost's live geometric value (see [SketchController.currentGhostValue]),
/// confirming via [SketchController.confirmGhostValue] on submit/tap, or
/// dismissing via [SketchController.cancelGhostEdit].
class _GhostValueEditor extends StatefulWidget {
  final SketchController controller;
  final DimensionGhost ghost;
  final Offset anchor;

  const _GhostValueEditor({
    super.key,
    required this.controller,
    required this.ghost,
    required this.anchor,
  });

  @override
  State<_GhostValueEditor> createState() => _GhostValueEditorState();
}

class _GhostValueEditorState extends State<_GhostValueEditor> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    final current = widget.controller.currentGhostValue(widget.ghost);
    _text = TextEditingController(text: current == null ? '' : current.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = double.tryParse(_text.text);
    if (value == null) return;
    widget.controller.confirmGhostValue(widget.ghost.key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.anchor.dx - 70,
      top: widget.anchor.dy + 14,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(isDense: true, suffixText: 'mm'),
                  onSubmitted: (_) => _confirm(),
                ),
              ),
              IconButton(
                tooltip: 'Confirm',
                icon: const Icon(Icons.check, size: 18),
                onPressed: _confirm,
              ),
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.controller.cancelGhostEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SketchPainter extends CustomPainter {
  final SketchController controller;
  final ViewTransform transform;
  final List<((double, double), (double, double))> referenceGhostSegments;
  final bool referenceBodyHidden;

  _SketchPainter({
    required this.controller,
    required this.transform,
    this.referenceGhostSegments = const [],
    this.referenceBodyHidden = false,
  });

  /// Stage 12 item 9's ghost wireframe color - faint and thinner than every
  /// real entity, so the existing solid always reads as a reference, never
  /// as something editable in this Sketch.
  static const Color _referenceGhostColor = Color(0xFF444444);

  /// Idle-state hoverable/selectable highlight colors - deliberately
  /// distinct from each other and from every "in progress" drawing color
  /// (green/deepOrange/indigo) used elsewhere in this painter.
  static const Color _hoverColor = Colors.amber;
  static const Color _selectedColor = Colors.purple;

  /// Construction-only Line/Circle color (Stage 12 item 7) - dashed,
  /// everywhere this painter draws entities, so it stays visually distinct
  /// from solid geometry at a glance.
  static const Color _constructionColor = Color(0xFF4A90D9);

  /// Stage 12 item 10's dimension-overlay color - the prompt only names
  /// this color for the Vertical/Horizontal glyphs, but using it for every
  /// overlay (Distance/Angle too) keeps them all visually distinct from
  /// entity colors without inventing an unspecified palette.
  static const Color _dimensionColor = Color(0xFFF5A623);

  /// Stage 13 item 5/6's ghost-dimension colors: dashed grey by default,
  /// blue for the ghost currently being edited, dimmer grey for the
  /// unchosen ghost in a V/H or radius/diameter pair while the other one is
  /// being edited.
  static const Color _ghostDefaultColor = Color(0xFF888888);
  static const Color _ghostActiveColor = Color(0xFF4A90D9);
  static const Color _ghostInactiveColor = Color(0xFF555555);
  static const Color _ghostLabelBackground = Color(0xCC222222);

  /// Draws [start]-to-[end] as a dashed segment - used for construction
  /// Lines. There's no dashed-stroke primitive on [Canvas]/[Paint], so this
  /// walks the segment in fixed-length on/off increments by hand.
  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashLength = 6.0;
    const gapLength = 4.0;
    final total = (end - start).distance;
    if (total == 0) return;
    final direction = (end - start) / total;
    var travelled = 0.0;
    while (travelled < total) {
      final dashEnd = math.min(travelled + dashLength, total);
      canvas.drawLine(start + direction * travelled, start + direction * dashEnd, paint);
      travelled += dashLength + gapLength;
    }
  }

  /// Draws a dashed circle outline - used for construction Circles. Walks
  /// the circumference in fixed-angle on/off arc increments, mirroring
  /// [_drawDashedLine]'s fixed-length approach (an arc-length-based dash
  /// would vary the angular step with radius, which isn't needed here).
  void _drawDashedCircle(Canvas canvas, Offset center, double radiusPixels, Paint paint) {
    if (radiusPixels <= 0) return;
    const dashAngle = 0.12; // radians
    const gapAngle = 0.08;
    var angle = 0.0;
    while (angle < 2 * math.pi) {
      final sweep = math.min(dashAngle, 2 * math.pi - angle);
      final path = Path()
        ..addArc(
          Rect.fromCircle(center: center, radius: radiusPixels),
          angle,
          sweep,
        );
      canvas.drawPath(path, paint);
      angle += dashAngle + gapAngle;
    }
  }

  /// Stage 12 item 10: renders every Constraint in [SketchController.constraints]
  /// as a render-only overlay - there is no client-side UI to create or edit
  /// a Distance/Angle value yet (the backend has no PATCH endpoint for
  /// constraint values), so these are display-only, dispatched by runtime
  /// type since [ConstraintDto] isn't a sealed hierarchy.
  void _paintDimensionOverlays(Canvas canvas) {
    for (final constraint in controller.constraints.values) {
      switch (constraint) {
        case DistanceConstraintDto c:
          _paintDistanceDimension(canvas, c);
        case VerticalConstraintDto c:
          _paintAxisIndicator(canvas, c.pointAId, c.pointBId, 'V');
        case HorizontalConstraintDto c:
          _paintAxisIndicator(canvas, c.pointAId, c.pointBId, 'H');
        case AngleConstraintDto c:
          _paintAngleDimension(canvas, c);
        default:
          break;
      }
    }
  }

  /// Draws a small filled, rounded-rect "chip" centered on [center] with
  /// [text] in white - shared by every dimension overlay below so they all
  /// read consistently against busy sketch geometry.
  void _drawDimensionLabel(Canvas canvas, Offset center, String text, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const horizontalPadding = 4.0;
    const verticalPadding = 2.0;
    final chipRect = Rect.fromCenter(
      center: center,
      width: textPainter.width + horizontalPadding * 2,
      height: textPainter.height + verticalPadding * 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(chipRect, const Radius.circular(3)),
      Paint()..color = color,
    );
    textPainter.paint(canvas, center - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  /// Distance dimension: a standard two-extension-line-plus-offset-segment
  /// layout, offset perpendicular to the constrained points by a fixed
  /// pixel amount (so it reads clearly regardless of zoom), labeled with
  /// the constraint's own [DistanceConstraintDto.distance] (the solved
  /// value, not a measurement of the current screen geometry).
  void _paintDistanceDimension(Canvas canvas, DistanceConstraintDto c) {
    final a = controller.points[c.pointAId];
    final b = controller.points[c.pointBId];
    if (a == null || b == null) return;
    final aScreen = transform.sketchToScreen(a.x, a.y);
    final bScreen = transform.sketchToScreen(b.x, b.y);
    final delta = bScreen - aScreen;
    final length = delta.distance;
    if (length < 1e-6) return;
    final normal = Offset(-delta.dy, delta.dx) / length;
    const offsetDistance = 18.0;
    final offset = normal * offsetDistance;

    final dimPaint = Paint()
      ..color = _dimensionColor
      ..strokeWidth = 1;
    canvas.drawLine(aScreen, aScreen + offset, dimPaint);
    canvas.drawLine(bScreen, bScreen + offset, dimPaint);
    canvas.drawLine(aScreen + offset, bScreen + offset, dimPaint);

    final midpoint = (aScreen + offset + bScreen + offset) / 2;
    _drawDimensionLabel(canvas, midpoint, c.distance.toStringAsFixed(2), _dimensionColor);
  }

  /// Vertical/Horizontal glyph: just a 'V'/'H' chip at the constrained
  /// Line's midpoint - there's no "value" to dimension, only the
  /// constraint's existence.
  void _paintAxisIndicator(Canvas canvas, String pointAId, String pointBId, String label) {
    final a = controller.points[pointAId];
    final b = controller.points[pointBId];
    if (a == null || b == null) return;
    final midpoint = (transform.sketchToScreen(a.x, a.y) + transform.sketchToScreen(b.x, b.y)) / 2;
    _drawDimensionLabel(canvas, midpoint, label, _dimensionColor);
  }

  /// Angle dimension: deliberately a numeric-only label rather than a
  /// literal arc sweep - the two constrained Lines have no shared vertex in
  /// general, so there's no single well-defined arc to draw. Placed at the
  /// midpoint between each Line's own midpoint, which stays stable and
  /// roughly "between" the two Lines regardless of their actual layout.
  void _paintAngleDimension(Canvas canvas, AngleConstraintDto c) {
    final midpoint1 = _lineMidpointScreen(c.line1Id);
    final midpoint2 = _lineMidpointScreen(c.line2Id);
    if (midpoint1 == null || midpoint2 == null) return;
    final midpoint = (midpoint1 + midpoint2) / 2;
    _drawDimensionLabel(canvas, midpoint, '∠${c.angleDegrees.toStringAsFixed(1)}°', _dimensionColor);
  }

  Offset? _lineMidpointScreen(String lineId) {
    final line = controller.lines[lineId];
    if (line == null) return null;
    final start = controller.points[line.startPointId];
    final end = controller.points[line.endPointId];
    if (start == null || end == null) return null;
    return (transform.sketchToScreen(start.x, start.y) + transform.sketchToScreen(end.x, end.y)) / 2;
  }

  /// Stage 13 item 5's ghost dimensions: every entry in
  /// [SketchController.ghosts], dashed and labeled '?' (or '⌀?' for a
  /// diameter ghost) regardless of the live geometric value - see
  /// [SketchController.currentGhostValue]'s doc comment for why the label
  /// itself never shows a number. The currently-tapped ghost (if any) is
  /// drawn in the active color; its sibling, if there is one, is dimmed.
  void _paintGhosts(Canvas canvas) {
    if (controller.ghosts.isEmpty) return;
    final activeKey = controller.activeGhostKey;
    for (final ghost in controller.ghosts) {
      final layout = _layoutGhost(controller, transform, ghost);
      if (layout == null) continue;
      final isActive = ghost.key == activeKey;
      final color = isActive
          ? _ghostActiveColor
          : (activeKey != null ? _ghostInactiveColor : _ghostDefaultColor);
      final dashPaint = Paint()
        ..color = color
        ..strokeWidth = 1;
      for (final segment in layout.segments) {
        _drawDashedLine(canvas, segment[0], segment[1], dashPaint);
      }
      final label = ghost.kind == GhostKind.diameter ? '⌀?' : '?';
      _drawDimensionLabel(canvas, layout.labelCenter, label, _ghostLabelBackground);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF2F2F2));

    if (!referenceBodyHidden && referenceGhostSegments.isNotEmpty) {
      final ghostPaint = Paint()
        ..color = _referenceGhostColor
        ..strokeWidth = 1;
      for (final segment in referenceGhostSegments) {
        final start = transform.sketchToScreen(segment.$1.$1, segment.$1.$2);
        final end = transform.sketchToScreen(segment.$2.$1, segment.$2.$2);
        _drawDashedLine(canvas, start, end, ghostPaint);
      }
    }

    final hovered = controller.hoveredEntity;
    final selectionSet = controller.selectionSet;
    bool isSelected(SelectionKind kind, String id) =>
        selectionSet.any((s) => s.kind == kind && s.id == id);

    for (final line in controller.lines.values) {
      final start = controller.points[line.startPointId];
      final end = controller.points[line.endPointId];
      if (start == null || end == null) continue;
      final lineIsSelected = isSelected(SelectionKind.line, line.id);
      final isHovered = hovered?.kind == SelectionKind.line && hovered!.id == line.id;
      final linePaint = Paint()
        ..color = lineIsSelected
            ? _selectedColor
            : isHovered
                ? _hoverColor
                : line.construction
                    ? _constructionColor
                    : Colors.blueGrey.shade700
        ..strokeWidth = lineIsSelected || isHovered ? 3 : 2;
      final startScreen = transform.sketchToScreen(start.x, start.y);
      final endScreen = transform.sketchToScreen(end.x, end.y);
      if (line.construction) {
        _drawDashedLine(canvas, startScreen, endScreen, linePaint);
      } else {
        canvas.drawLine(startScreen, endScreen, linePaint);
      }
    }

    for (final circle in controller.circles.values) {
      final center = controller.points[circle.centerPointId];
      final radiusPoint = controller.points[circle.radiusPointId];
      if (center == null || radiusPoint == null) continue;
      final radius = math.sqrt(
        math.pow(radiusPoint.x - center.x, 2) + math.pow(radiusPoint.y - center.y, 2),
      );
      final circleIsSelected = isSelected(SelectionKind.circle, circle.id);
      final isHovered = hovered?.kind == SelectionKind.circle && hovered!.id == circle.id;
      final circlePaint = Paint()
        ..color = circleIsSelected
            ? _selectedColor
            : isHovered
                ? _hoverColor
                : circle.construction
                    ? _constructionColor
                    : Colors.blueGrey.shade700
        ..style = PaintingStyle.stroke
        ..strokeWidth = circleIsSelected || isHovered ? 3 : 2;
      final centerScreen = transform.sketchToScreen(center.x, center.y);
      final radiusPixels = radius * transform.pixelsPerUnit;
      if (circle.construction) {
        _drawDashedCircle(canvas, centerScreen, radiusPixels, circlePaint);
      } else {
        canvas.drawCircle(centerScreen, radiusPixels, circlePaint);
      }
    }

    final originId = controller.originPointId;
    if (originId != null) {
      final origin = controller.points[originId];
      if (origin != null) {
        final isSnappingToOrigin = controller.isHoveringOrigin;
        final originIsSelected = isSelected(SelectionKind.point, originId);
        final isHovered = hovered?.kind == SelectionKind.point && hovered!.id == originId;
        Color color = Colors.indigo;
        if (isSnappingToOrigin) {
          color = Colors.green;
        } else if (originIsSelected) {
          color = _selectedColor;
        } else if (isHovered) {
          color = _hoverColor;
        }
        final originPaint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        final halfSize = isSnappingToOrigin ? 10.0 : 7.0;
        final originScreen = transform.sketchToScreen(origin.x, origin.y);
        canvas.drawRect(
          Rect.fromCenter(center: originScreen, width: halfSize * 2, height: halfSize * 2),
          originPaint,
        );
      }
    }

    final chainFirstId = controller.chainFirstPointId;
    final isSnapping = controller.isHoveringChainStart;
    final circleCenterId = controller.circleCenterPointId;
    for (final point in controller.points.values) {
      if (point.id == originId) continue; // Drawn separately above, as a square marker.
      final isChainStart = controller.chainInProgress && point.id == chainFirstId;
      final isCircleCenter = controller.circleInProgress && point.id == circleCenterId;
      final pointIsSelected = isSelected(SelectionKind.point, point.id);
      final isHovered = hovered?.kind == SelectionKind.point && hovered!.id == point.id;
      final screenPos = transform.sketchToScreen(point.x, point.y);
      Color color = Colors.black87;
      double radius = 4;
      if (isChainStart) {
        color = isSnapping ? Colors.green : Colors.deepOrange;
        radius = isSnapping ? 11 : 6;
      } else if (isCircleCenter) {
        color = Colors.deepOrange;
        radius = 6;
      } else if (pointIsSelected) {
        color = _selectedColor;
        radius = 7;
      } else if (isHovered) {
        color = _hoverColor;
        radius = 6;
      }
      canvas.drawCircle(screenPos, radius, Paint()..color = color);
    }

    _paintDimensionOverlays(canvas);
    _paintGhosts(canvas);

    final cursorScreen = transform.sketchToScreen(controller.cursorX, controller.cursorY);
    final crosshairPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 1.5;
    const armLength = 12.0;
    canvas.drawLine(
      cursorScreen.translate(-armLength, 0),
      cursorScreen.translate(armLength, 0),
      crosshairPaint,
    );
    canvas.drawLine(
      cursorScreen.translate(0, -armLength),
      cursorScreen.translate(0, armLength),
      crosshairPaint,
    );
    canvas.drawCircle(cursorScreen, 3, crosshairPaint);
  }

  @override
  bool shouldRepaint(covariant _SketchPainter oldDelegate) => true;
}
