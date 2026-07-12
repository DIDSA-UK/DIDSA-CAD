import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';

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

  /// Sketcher-roadmap Phase 4.3 v1: [referenceGhostSegments]'s own pick
  /// targets - see [SketchScreen.referenceGhostVertices]'s own doc comment.
  final List<(String, int, double, double)> referenceGhostVertices;

  /// Stage 12 item 9's Hide/Show Reference Body toggle - owned by
  /// [SketchScreen] (mirrors `PartScreen._referencePlanesHidden`'s pattern),
  /// just threaded through here for the painter to honor.
  final bool referenceBodyHidden;

  /// Stage 23f's View submenu toggle - owned by [SketchScreen], session-only
  /// (no persistence, unlike `viewport3d`'s `ViewPreferences`). Suppresses
  /// [_SketchPainter._paintDimensionOverlays] entirely when off; tap-to-select
  /// on a constraint label is left as-is (see [dimensionLabelAt]), since the
  /// brief only calls for hiding the rendering.
  final bool constraintLabelsVisible;

  /// Stage 23f's View submenu colour/transparency controls - also
  /// session-only, owned by [SketchScreen]. [defaultColor] matches the fixed
  /// background this painter always drew before Stage 23f.
  final Color canvasColor;
  final double canvasOpacity;

  /// On-device feedback: lets [SketchScreen] keep its shaded-body backdrop
  /// (behind this canvas, see `sketch_screen.dart`'s `_buildBaseLayer`)
  /// visually in sync with this canvas's own pan/zoom - fired (debounced,
  /// post-frame) whenever [SketchViewport]'s `panOffset`/`zoom` or this
  /// canvas's own render size actually changes. `panOffset`/`zoom` are
  /// [SketchViewport]'s own fields verbatim; `canvasSize` is this widget's
  /// current render size.
  final void Function(Offset panOffset, double zoom, Size canvasSize)? onViewportChanged;

  static const Color defaultColor = Color(0xFFF2F2F2);

  const SketchCanvas({
    super.key,
    required this.controller,
    this.referenceGhostSegments = const [],
    this.referenceGhostVertices = const [],
    this.referenceBodyHidden = false,
    this.constraintLabelsVisible = true,
    this.canvasColor = defaultColor,
    this.canvasOpacity = 1.0,
    this.onViewportChanged,
  });

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> with TickerProviderStateMixin {
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

  /// Last values passed to [widget.onViewportChanged] - see
  /// [_notifyViewportChangedIfNeeded], which debounces against these so
  /// the callback only actually fires when something real changed, not on
  /// every unrelated rebuild (e.g. a constraint solve).
  Offset? _lastNotifiedPan;
  double? _lastNotifiedZoom;
  Size? _lastNotifiedSize;

  /// On-device feedback: notifies [widget.onViewportChanged] (if set)
  /// whenever this canvas's pan/zoom/size actually changed since the last
  /// notification - scheduled via [WidgetsBinding.addPostFrameCallback]
  /// rather than fired synchronously from [build], since the callback may
  /// itself call `setState` on a sibling widget (the shaded-body backdrop
  /// in `sketch_screen.dart`) that's already been built earlier in the
  /// same frame - doing that mid-build throws.
  void _notifyViewportChangedIfNeeded(Size size) {
    final onViewportChanged = widget.onViewportChanged;
    if (onViewportChanged == null) return;
    if (_lastNotifiedPan == _viewport.panOffset &&
        _lastNotifiedZoom == _viewport.zoom &&
        _lastNotifiedSize == size) {
      return;
    }
    _lastNotifiedPan = _viewport.panOffset;
    _lastNotifiedZoom = _viewport.zoom;
    _lastNotifiedSize = size;
    final pan = _viewport.panOffset;
    final zoom = _viewport.zoom;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      onViewportChanged(pan, zoom, size);
    });
  }

  /// The canvas's own render size, refreshed every [build] - read by
  /// [_onEdgePanTick], which runs independently of any pointer event so an
  /// RTS-style edge-pan keeps going even while the pointer itself sits
  /// still at the edge.
  Size? _lastSize;

  /// How close (logical pixels) the cursor must sit to a canvas edge to
  /// trigger panning, and how fast (screen pixels/second) panning ramps up
  /// to at the very edge - both arbitrary, tuned for a comfortable RTS-style
  /// feel rather than derived from anything.
  static const double _edgePanMarginPixels = 48.0;
  static const double _edgePanMaxSpeed = 700.0;

  late final Ticker _edgePanTicker;
  Duration _lastTick = Duration.zero;

  /// Stage 15 item 3: the moment the cursor last actually moved (a non-zero
  /// pointer-hover/-move delta from the user - never [_onEdgePanTick]'s own
  /// re-anchoring call, which would otherwise keep the pan alive forever
  /// once started). Gates edge-pan so it only runs while the cursor is
  /// genuinely being held at the edge and moving, not just left sitting
  /// there - see [_edgePanIdleThreshold].
  DateTime? _lastCursorMoveTime;

  /// How long the cursor may sit without moving before edge-pan stops,
  /// per item 3.
  static const Duration _edgePanIdleThreshold = Duration(milliseconds: 150);

  /// Real touchscreens report pointer-move/-hover events with non-zero but
  /// imperceptible (sub-pixel sensor noise) deltas even while a finger or
  /// mouse sits still - left unfiltered (the previous `event.delta !=
  /// Offset.zero` check), that noise kept refreshing [_lastCursorMoveTime]
  /// indefinitely, so [_edgePanIdleThreshold] never elapsed and edge-pan
  /// kept running for a pointer that, to the user, was just sitting at the
  /// edge. Only a move whose distance from the last recorded raw pointer
  /// position exceeds this (logical pixels) counts as real movement - see
  /// [_refreshCursorMoveTimeIfMoved].
  static const double _edgePanMoveThreshold = 1.5;

  /// The last raw pointer position seen by [_refreshCursorMoveTimeIfMoved],
  /// compared against each new event's position to detect real movement.
  /// Deliberately the event's own screen position, not the controller's
  /// (transformed/scaled, relative-for-touch) cursor position, and not
  /// `event.delta` - which is exactly what carries the sensor noise
  /// [_edgePanMoveThreshold] exists to filter out.
  Offset? _lastPointerPosition;

  /// Refreshes [_lastCursorMoveTime] only if [position] is more than
  /// [_edgePanMoveThreshold] from the last recorded raw pointer position -
  /// see that field's doc comment for why a plain non-zero-delta check
  /// isn't enough. Always updates [_lastPointerPosition], regardless of
  /// whether the threshold was cleared, so successive sub-threshold jitters
  /// don't silently accumulate into a false "real movement" later.
  void _refreshCursorMoveTimeIfMoved(Offset position) {
    final last = _lastPointerPosition;
    if (last == null || (position - last).distance > _edgePanMoveThreshold) {
      _lastCursorMoveTime = DateTime.now();
    }
    _lastPointerPosition = position;
  }

  /// Stage 23g: pending long-press timer started by [_maybeStartLongPress] -
  /// non-null only while waiting to see whether the pointer stays put for
  /// [_longPressDuration]; canceled (see [_cancelLongPress]) by excess
  /// travel, the pointer lifting first, or a second pointer touching down.
  Timer? _longPressTimer;

  /// How long a stationary press on empty canvas must hold before it grows
  /// into a marquee-select, per the brief - arbitrary, tuned to feel like a
  /// deliberate "long" press rather than an ordinary tap.
  static const Duration _longPressDuration = Duration(milliseconds: 500);

  /// The screen position the pending long-press (or, once it fires, the
  /// active marquee) started at - both one corner of the eventual marquee
  /// rectangle and the point compared against later pointer-move positions
  /// to cancel a long-press that moves too far before firing.
  Offset? _longPressDownScreen;

  /// Whether the swell-and-pop-then-marquee gesture is currently dragging -
  /// once true, [_handlePointerMove]/[_handlePointerEnd] divert entirely to
  /// marquee handling instead of the usual cursor-move/pan/tap dispatch.
  bool _marqueeActive = false;

  /// The live other corner of the marquee rectangle while [_marqueeActive] -
  /// null only in the instant between the long-press firing and the first
  /// subsequent pointer-move.
  Offset? _marqueeCurrentScreen;

  /// Drives the swell-and-pop circle shown at the long-press point the
  /// moment it fires. Requires the broader `TickerProviderStateMixin`
  /// (rather than the single-ticker variant used before Stage 23g) since it
  /// must coexist with [_edgePanTicker]'s own ticker.
  late final AnimationController _longPressPopController;
  late final Animation<double> _longPressPopRadius;
  late final Animation<double> _longPressPopOpacity;

  /// Screen position of the swell-and-pop circle - null whenever there's
  /// nothing to show, including once [_longPressPopController] finishes.
  Offset? _longPressPopCenter;

  @override
  void initState() {
    super.initState();
    _edgePanTicker = createTicker(_onEdgePanTick)..start();
    _longPressPopController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _longPressPopCenter = null);
        }
      });
    _longPressPopRadius = Tween<double>(begin: 6, end: 26).animate(
      CurvedAnimation(parent: _longPressPopController, curve: Curves.easeOut),
    );
    _longPressPopOpacity = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _longPressPopController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _edgePanTicker.dispose();
    _longPressPopController.dispose();
    _longPressTimer?.cancel();
    super.dispose();
  }

  /// Stage 23g: starts the long-press timer when [downScreen] (the
  /// pointer-down position that's already been confirmed the sketch's only
  /// active pointer) lands on blank canvas while in [SketchMode.select] -
  /// the only situation a long-press should grow into a marquee-select
  /// rather than being left to the existing tap/pan/entity-drag handling.
  /// No-op otherwise, so e.g. a long-press on an existing Point still just
  /// behaves like an ordinary press-and-hold (no special gesture fires).
  void _maybeStartLongPress(Offset downScreen, ViewTransform transform) {
    final controller = widget.controller;
    if (controller.mode != SketchMode.select) return;
    // A marquee-select starting while something's grabbed via drag mode
    // would be a confusing second gesture layered on top of the first - a
    // stationary press elsewhere on the canvas while repositioning a
    // grabbed Point/Line should just be part of that swipe, not grow into
    // a marquee.
    if (controller.isEntityGrabbed) return;
    final coord = transform.screenToSketch(downScreen.dx, downScreen.dy);
    final hitRadius = controller.hitRadiusForPixelsPerUnit(transform.pixelsPerUnit);
    if (controller.hasEntityNear(coord.x, coord.y, hitRadius)) return;
    _longPressDownScreen = downScreen;
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_longPressDuration, () => _startMarquee(downScreen));
  }

  /// Fires once [_longPressDuration] elapses without the pointer traveling
  /// far enough to cancel - shows the swell-and-pop circle and switches the
  /// gesture state machine over to marquee-drag mode.
  void _startMarquee(Offset downScreen) {
    _longPressTimer = null;
    setState(() {
      _marqueeActive = true;
      _longPressDownScreen = downScreen;
      _marqueeCurrentScreen = downScreen;
      _longPressPopCenter = downScreen;
    });
    _longPressPopController.forward(from: 0);
  }

  /// Cancels a pending (not yet fired) long-press timer - does not affect
  /// an already-active marquee, which only ends via [_endMarquee].
  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _longPressDownScreen = null;
  }

  /// Ends the active marquee on pointer-up/-cancel: selects every entity
  /// fully inside the box spanned by [_longPressDownScreen] and
  /// [_marqueeCurrentScreen] (both screen-space, converted to sketch space
  /// here since [SketchController.selectInRect] only knows sketch
  /// coordinates) via [SketchController.selectInRect], then resets all
  /// marquee state. A long-press that never actually dragged (so both
  /// corners coincide) simply selects nothing, same as a deselecting tap.
  void _endMarquee(ViewTransform transform) {
    final anchor = _longPressDownScreen;
    final current = _marqueeCurrentScreen;
    _marqueeActive = false;
    _longPressDownScreen = null;
    _marqueeCurrentScreen = null;
    if (anchor == null || current == null) return;
    final anchorSketch = transform.screenToSketch(anchor.dx, anchor.dy);
    final currentSketch = transform.screenToSketch(current.dx, current.dy);
    final rect = Rect.fromPoints(
      Offset(anchorSketch.x, anchorSketch.y),
      Offset(currentSketch.x, currentSketch.y),
    );
    widget.controller.selectInRect(rect);
  }

  /// Runs every frame regardless of pointer activity: if the cursor's
  /// current on-screen position sits within [_edgePanMarginPixels] of an
  /// edge, pans [_viewport] in that direction and then re-anchors the
  /// controller's cursor to the exact same screen position under the new
  /// transform. That re-anchoring is what makes this feel like a real RTS
  /// edge-pan rather than a one-off nudge: a real mouse that hasn't moved
  /// fires no further hover events, so without it the cursor's *sketch*
  /// coordinates would stay fixed while the view pans underneath, sliding
  /// the rendered cursor back toward the center and stopping the pan after
  /// one frame; pinning it to the same screen pixel keeps it sitting in the
  /// margin for as long as the pointer actually stays there, exactly like a
  /// real cursor held at a game window's edge. Skipped during an active
  /// pinch gesture, so it never fights [_applyPinchPan] over [_viewport].
  void _onEdgePanTick(Duration elapsed) {
    final size = _lastSize;
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (size == null || dt <= 0 || dt > 0.25) return;
    if (_activeTouches.length >= 2) return;
    // Bug-fix round: while something's grabbed via drag mode, the cursor is
    // hidden (see _SketchPainter's isCursorVisible check) but its screen
    // position doesn't stop existing - if it happens to sit near an edge
    // from an earlier move, this ambient RTS-style edge-pan kept firing
    // every tick regardless, silently scrolling the view out from under a
    // drag the user never asked to pan during. Every other pan/gesture path
    // in this file already gates on isEntityGrabbed; this automatic,
    // no-explicit-gesture one is the one that was missing it.
    if (widget.controller.isEntityGrabbed) return;
    final lastMove = _lastCursorMoveTime;
    if (lastMove == null || DateTime.now().difference(lastMove) >= _edgePanIdleThreshold) return;

    final transform = _viewport.transformFor(size);
    final cursorScreen = transform.sketchToScreen(widget.controller.cursorX, widget.controller.cursorY);

    final dx = _edgePanAxisDelta(cursorScreen.dx, size.width, dt);
    final dy = _edgePanAxisDelta(cursorScreen.dy, size.height, dt);
    if (dx == 0 && dy == 0) return;

    setState(() => _viewport.panByScreenDelta(Offset(dx, dy)));
    widget.controller.moveCursorAbsoluteScreen(cursorScreen, _viewport.transformFor(size));
  }

  /// How far (screen pixels) to pan this tick along one axis, given the
  /// cursor's [position] along that axis and the canvas's [extent] - 0 if
  /// the cursor isn't within [_edgePanMarginPixels] of either edge. Speed
  /// ramps up linearly the deeper the cursor sits into the margin, capped
  /// at [_edgePanMaxSpeed] right at the boundary. The sign points the
  /// *content* opposite the cursor's edge (so the camera moves toward
  /// it, revealing more space in that direction) - same convention as
  /// [_handlePointerMove]'s right-click-drag pan.
  double _edgePanAxisDelta(double position, double extent, double dt) {
    if (position < _edgePanMarginPixels) {
      final depth = (_edgePanMarginPixels - position).clamp(0.0, _edgePanMarginPixels);
      return _edgePanMaxSpeed * (depth / _edgePanMarginPixels) * dt;
    }
    if (position > extent - _edgePanMarginPixels) {
      final depth = (position - (extent - _edgePanMarginPixels)).clamp(0.0, _edgePanMarginPixels);
      return -_edgePanMaxSpeed * (depth / _edgePanMarginPixels) * dt;
    }
    return 0;
  }

  void _handlePointerHover(PointerHoverEvent event, ViewTransform transform) {
    // Hover events only fire for a mouse with no buttons pressed - real
    // mouse movement drives the cursor directly, 1:1.
    if (event.kind != PointerDeviceKind.mouse) return;
    _refreshCursorMoveTimeIfMoved(event.localPosition);
    widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
    // Drag-mode's "swipe to move" for a mouse: since a grab/drop is two
    // separate clicks (see _dispatchTap's drag-mode branch), the mouse
    // button is *up* while repositioning a grabbed entity - exactly what
    // fires hover events, not pointer-move. See _handlePointerMove's mirror
    // of this for the button-held case (a literal click-and-drag also
    // works, not just click-move-click).
    _feedMouseSwipeToGrabbedEntity(event, transform);
  }

  /// Feeds a mouse swipe (hover or button-held move, both carry a screen
  /// position + delta) to whatever's currently grabbed via drag mode - a
  /// Point/Line/Constraint-label (see [SketchController.isEntityGrabbed]).
  /// A label's offset lives in screen space (see
  /// [SketchController.updateLabelDrag]'s doc comment for why), so it's fed
  /// [event]'s own delta directly; a Point/Line tracks an absolute cursor
  /// position instead, so its update converts [event]'s screen position
  /// through [transform]. No-op if nothing's grabbed.
  void _feedMouseSwipeToGrabbedEntity(PointerEvent event, ViewTransform transform) {
    final controller = widget.controller;
    if (!controller.isEntityGrabbed) return;
    if (controller.draggingLabelId != null) {
      controller.updateLabelDrag(event.delta);
      return;
    }
    final coord = transform.screenToSketch(event.localPosition.dx, event.localPosition.dy);
    controller.updateGrabbedPosition(coord.x, coord.y);
  }

  /// Trackpad-style dispatch point for "what does a click do right now":
  /// always commits at the controller's own persistent [cursorX]/[cursorY]
  /// (the on-canvas crosshair), never at the literal screen location of the
  /// pointer-down/up that triggered the click - same as a laptop trackpad,
  /// where swiping moves the cursor and tapping clicks wherever the cursor
  /// already sits, even if the tap itself lands elsewhere on the pad. In
  /// [SketchMode.dimension], a click on an already rendered ghost's label
  /// either opens its inline value input or - if a different ghost's input
  /// is already open - cancels that edit; any other click (every other
  /// mode, or a dimension-mode click that misses every ghost) goes to
  /// [SketchController.handleCanvasTap].
  void _dispatchTap(ViewTransform transform) {
    final controller = widget.controller;
    final cursorScreen = transform.sketchToScreen(controller.cursorX, controller.cursorY);
    if (controller.mode == SketchMode.dimension) {
      final hitKey = _ghostKeyAt(controller, transform, cursorScreen);
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
      // Sketcher-roadmap Phase 4.3 v1: only reachable once a tap misses
      // every real ghost/value-editor, and (see hasEntityNear below) every
      // real sketch entity too - the reference body's own ghost geometry
      // is a backdrop, so it never steals a tap real geometry would
      // otherwise have won.
      final hitRadius = controller.hitRadiusForPixelsPerUnit(transform.pixelsPerUnit);
      if (!controller.hasEntityNear(controller.cursorX, controller.cursorY, hitRadius)) {
        final ghostVertex = _referenceGhostVertexAt(transform, cursorScreen);
        if (ghostVertex != null) {
          controller.pickReferenceGhostVertex(ghostVertex.$1, ghostVertex.$2);
          return;
        }
      }
    }
    // Drag-mode's pick-up/drop gesture: a tap while nothing is grabbed
    // picks up whichever Point/Line sits at the cursor; a tap while
    // something already is drops it. Checked ahead of normal select-mode
    // tap handling below, since a drop must always win over an ordinary
    // select-tap landing on the same spot. Movement between the two taps
    // (a "swipe", handled in _handlePointerMove/_handlePointerHover
    // whenever something is grabbed, regardless of which touch/click
    // gesture it's part of) is what actually repositions the grabbed
    // entity - see SketchController.updateGrabbedPosition.
    if (controller.mode == SketchMode.select &&
        controller.dragModeEnabled &&
        _handleDragModeTap(controller, transform)) {
      return;
    }
    if (controller.mode == SketchMode.select) {
      final constraintId = _constraintIdAt(controller, transform, cursorScreen);
      if (constraintId != null) {
        controller.selectConstraint(constraintId);
        return;
      }
    }
    final hitRadius = controller.hitRadiusForPixelsPerUnit(transform.pixelsPerUnit);
    controller.handleCanvasTap(controller.cursorX, controller.cursorY, hitRadius);
  }

  /// Sketcher-roadmap Phase 4.3 v1: the `(bodyId, vertexIndex)` of whichever
  /// [SketchCanvas.referenceGhostVertices] marker [screenPosition] landed
  /// on, or null if it missed all of them - mirrors [_ghostKeyAt]'s own
  /// hit-radius, but lives on this State (not as a top-level function like
  /// [_ghostKeyAt]) since ghost vertices are this widget's own prop, not
  /// something the controller knows about (see [SketchController.
  /// pickReferenceGhostVertex]'s own doc comment for why).
  (String, int)? _referenceGhostVertexAt(ViewTransform transform, Offset screenPosition) {
    for (final (bodyId, vertexIndex, x, y) in widget.referenceGhostVertices) {
      final vertexScreen = transform.sketchToScreen(x, y);
      if ((screenPosition - vertexScreen).distance <= _ghostHitRadiusPixels) {
        return (bodyId, vertexIndex);
      }
    }
    return null;
  }

  /// [_dispatchTap]'s drag-mode branch: drops whatever's grabbed if
  /// something is, otherwise tries to grab a Constraint label, Point, or
  /// Line at the cursor (checked in that order, same priority the old
  /// pointer-down-triggered label grab used). Returns whether the tap was
  /// consumed (grabbed or dropped something) - false falls through to
  /// ordinary select-tap handling (e.g. a tap on empty canvas, or on a
  /// Circle, which this gesture doesn't grab).
  bool _handleDragModeTap(SketchController controller, ViewTransform transform) {
    if (controller.isEntityGrabbed) {
      controller.dropGrabbedEntity();
      return true;
    }
    final cursorScreen = transform.sketchToScreen(controller.cursorX, controller.cursorY);
    final labelId = dimensionLabelAt(controller, transform, cursorScreen, _ghostHitRadiusPixels);
    if (labelId != null && controller.beginLabelDrag(labelId)) return true;
    final hitRadius = controller.hitRadiusForPixelsPerUnit(transform.pixelsPerUnit);
    final target = controller.dragGrabTargetAt(controller.cursorX, controller.cursorY, hitRadius);
    if (target == null) return false;
    switch (target.kind) {
      case SelectionKind.point:
        return controller.beginPointDrag(target.id);
      case SelectionKind.line:
        return controller.beginLineDrag(target.id);
      default:
        return false;
    }
  }

  void _handlePointerDown(PointerDownEvent event, ViewTransform transform) {
    // Stage 23g: the marquee gesture only ever tracks one pointer - a
    // second finger touching down mid-drag is ignored outright rather than
    // feeding into the pinch/pan handling below, which would otherwise
    // fight the marquee over what the gesture even means.
    if (_marqueeActive) return;
    if (event.kind == PointerDeviceKind.mouse) {
      // Only the primary (left) button counts as a bare tap, same as a
      // touch tap - a right-click starts a pan drag instead (see
      // _handlePointerMove) and must not also dispatch a tap. A mouse's
      // cursor is always 1:1 with the pointer (see _handlePointerHover), so
      // syncing it to the down position here is a no-op in the normal case
      // and only matters if the button is pressed without a preceding
      // hover event.
      if (event.buttons & kPrimaryMouseButton != 0) {
        widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
        _maybeStartLongPress(event.localPosition, transform);
        _dispatchTap(transform);
      }
      return;
    }
    // Touch-down never commits a point by itself - only a tap (a touch that
    // lifts again without much travel, see _handlePointerEnd) does that -
    // but is tracked here so a second finger touching down is seen by the
    // pinch/pan handling below, and so a single-finger touch ending without
    // much travel can be recognized as a tap.
    _activeTouches[event.pointer] = event.localPosition;
    if (_activeTouches.length != 1) {
      _multiTouchOccurred = true;
      return;
    }
    // Bug-fix round 2: a brand new single-finger touch (not a continuation
    // of one already in progress) is the one moment the cursor reappears
    // at canvas centre if a prior pan/zoom left it off-canvas - see
    // SketchController.resetCursorToCentreIfHidden's doc comment for why
    // this must never happen mid-drag instead.
    final size = _lastSize;
    if (size != null) {
      widget.controller.resetCursorToCentreIfHidden(size, transform);
    }
    _singleTouchTravel = 0;
    _multiTouchOccurred = false;
    _maybeStartLongPress(event.localPosition, transform);
  }

  void _handlePointerMove(PointerMoveEvent event, ViewTransform transform, Size size) {
    if (_marqueeActive) {
      setState(() => _marqueeCurrentScreen = event.localPosition);
      return;
    }
    if (_longPressTimer != null) {
      final down = _longPressDownScreen;
      if (down != null && (event.localPosition - down).distance > _tapTravelThreshold) {
        _cancelLongPress();
      }
    }
    // Drag-mode's "swipe to move": a grab and its drop are two separate
    // taps (see _dispatchTap's drag-mode branch), so whatever's grabbed -
    // a Point, a Line, or now a Constraint label too - just rides along
    // with the ordinary cursor-move handling below for however many
    // separate swipe gestures happen in between, rather than needing its
    // own early-return/intercept branch the way the old continuous-hold
    // label drag did.
    if (event.kind == PointerDeviceKind.mouse) {
      if (event.buttons & kSecondaryMouseButton != 0) {
        // Panning never itself touches the cursor's sketch-space position
        // (see SketchController's class doc comment) - it may simply drift
        // off-canvas as a result, which is fine: the crosshair just stops
        // rendering (see _SketchPainter's isCursorVisible check) until the
        // next cursor-moving interaction brings it back.
        setState(() => _viewport.panByScreenDelta(event.delta));
      } else {
        _refreshCursorMoveTimeIfMoved(event.localPosition);
        widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
        _feedMouseSwipeToGrabbedEntity(event, transform);
      }
      return;
    }

    if (_activeTouches.length < 2) {
      // Single-finger: relative, scaled cursor movement, trackpad-style -
      // this is what determines where a subsequent tap commits (see
      // _dispatchTap, which always reads the cursor's current position,
      // never the tap's own screen location). Same relative+scaled delta
      // also drives a grabbed Point/Line/label, same as it always drove
      // the old continuous-hold Point drag - see
      // moveCursorRelative's touchSensitivity/zoom scaling. A label's
      // offset lives in screen space (unlike a Point/Line's absolute
      // cursor-position tracking), so it's fed this same raw touch delta
      // directly rather than through the cursor-position-based
      // [SketchController.updateGrabbedPosition].
      _singleTouchTravel += event.delta.distance;
      _refreshCursorMoveTimeIfMoved(event.localPosition);
      widget.controller.moveCursorRelative(event.delta.dx, event.delta.dy, _viewport.zoom);
      if (widget.controller.isEntityGrabbed) {
        if (widget.controller.draggingLabelId != null) {
          widget.controller.updateLabelDrag(event.delta);
        } else {
          widget.controller.updateGrabbedPosition(widget.controller.cursorX, widget.controller.cursorY);
        }
      }
      return;
    }

    _multiTouchOccurred = true;
    final before = Map<int, Offset>.from(_activeTouches);
    _activeTouches[event.pointer] = event.localPosition;
    _applyPinchPan(before, _activeTouches, size);
  }

  void _handlePointerEnd(PointerEvent event, ViewTransform transform) {
    if (_marqueeActive) {
      _activeTouches.remove(event.pointer);
      setState(() => _endMarquee(transform));
      return;
    }
    // A pending (not yet fired) long-press timer never gets the chance to
    // fire if its pointer lifts first - same as any other gesture that's
    // still ambiguous when the pointer ends.
    _cancelLongPress();
    if (event.kind == PointerDeviceKind.mouse) return;

    // A lone finger lifting (not the tail end of a pinch) after barely
    // moving is a tap - the select/draw/dimension gesture - rather than a
    // drag. Deliberately the *only* path that can drop a grabbed Point/
    // Line/label now (via _dispatchTap's drag-mode branch, when this
    // counts as a tap) - a swipe that moved past the threshold just ends
    // this one touch/pinch-pan gesture without dropping anything, since
    // the entity is still grabbed and ready for another swipe or a final
    // drop-tap.
    final wasTap = event is PointerUpEvent &&
        _activeTouches.length == 1 &&
        !_multiTouchOccurred &&
        _singleTouchTravel < _tapTravelThreshold;
    _activeTouches.remove(event.pointer);
    if (wasTap) {
      _dispatchTap(transform);
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

  /// Two-finger touch pan/zoom. Deliberately never touches the cursor's
  /// sketch-space position (same rationale as the mouse right-click pan in
  /// [_handlePointerMove]) - the cursor stays exactly where it was in the
  /// drawing throughout the gesture, simply disappearing from view if that
  /// point pans/zooms off-canvas, rather than snapping anywhere.
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
        _lastSize = size;
        _notifyViewportChangedIfNeeded(size);
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
                      referenceGhostVertices: widget.referenceGhostVertices,
                      referenceBodyHidden: widget.referenceBodyHidden,
                      labelsVisible: widget.constraintLabelsVisible,
                      canvasColor: widget.canvasColor,
                      canvasOpacity: widget.canvasOpacity,
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
            // Stage 23g: the live marquee rectangle - shrink-wraps to
            // whatever's been dragged so far between the long-press anchor
            // and the current pointer position, both screen-space.
            if (_marqueeActive)
              IgnorePointer(
                child: CustomPaint(
                  size: size,
                  painter: _MarqueePainter(
                    rect: Rect.fromPoints(
                      _longPressDownScreen ?? Offset.zero,
                      _marqueeCurrentScreen ?? _longPressDownScreen ?? Offset.zero,
                    ),
                  ),
                ),
              ),
            // Stage 23g: the swell-and-pop circle that announces a
            // long-press just fired, right before the marquee itself
            // becomes draggable.
            AnimatedBuilder(
              animation: _longPressPopController,
              builder: (context, _) {
                final center = _longPressPopCenter;
                if (center == null) return const SizedBox.shrink();
                return IgnorePointer(
                  child: CustomPaint(
                    size: size,
                    painter: _LongPressPopPainter(
                      center: center,
                      radius: _longPressPopRadius.value,
                      opacity: _longPressPopOpacity.value,
                    ),
                  ),
                );
              },
            ),
            // Bug-fix: top:8 used to sit directly underneath (and get
            // obscured by) SketchScreen's own "Menu" FAB - a screen-level
            // Positioned(top: 8, left: 8) drawn on top of this whole canvas
            // (see sketch_screen.dart's 'sketch-menu-fab') - both anchored
            // to the exact same corner since SketchCanvas fills the full
            // screen. Dropped by the same ~64px one FAB's footprint plus a
            // gap that the drag-mode FAB already uses to clear
            // PlaneIndicator at the opposite corner (see that Positioned's
            // own bug-fix comment in sketch_screen.dart).
            Positioned(
              top: 72,
              left: 8,
              child: IconButton.filled(
                tooltip: 'Zoom to fit',
                icon: SvgPicture.asset(
                  'assets/icons/dimbar/dimbar_zoom_to_fit.svg',
                  width: 30,
                  height: 30,
                  colorFilter: ColorFilter.mode(
                    Theme.of(context).colorScheme.onPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: () => setState(
                  () => _viewport.zoomToFit(widget.controller.geometryBoundingBox, size),
                ),
              ),
            ),
            Positioned(
              bottom: 8,
              left: 8,
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) => PlaneIndicator(
                  plane: widget.controller.plane,
                  flip: widget.controller.flip,
                  rotationQuarterTurns: widget.controller.rotationQuarterTurns,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Stage 23g: the live marquee rectangle drawn while
/// [_SketchCanvasState._marqueeActive] - a light fill plus a solid border,
/// matching the conventional "rubber-band select" look.
class _MarqueePainter extends CustomPainter {
  final Rect rect;

  const _MarqueePainter({required this.rect});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(rect, Paint()..color = Colors.blue.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blue.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter oldDelegate) => oldDelegate.rect != rect;
}

/// Stage 23g: the swell-and-pop circle shown at the instant a long-press
/// fires - [radius] grows and [opacity] fades as
/// [_SketchCanvasState._longPressPopController] runs.
class _LongPressPopPainter extends CustomPainter {
  final Offset center;
  final double radius;
  final double opacity;

  const _LongPressPopPainter({
    required this.center,
    required this.radius,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.blue.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _LongPressPopPainter oldDelegate) =>
      oldDelegate.center != center || oldDelegate.radius != radius || oldDelegate.opacity != opacity;
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

/// A Line's current midpoint in screen space - null if the Line or either
/// endpoint Point is missing. Shared by [_layoutGhost]'s line-anchored
/// ghost kinds and [_constraintLabelCenter]'s Angle case, mirroring
/// [_SketchPainter._lineMidpointScreen] for the free-function (non-painter)
/// call sites in this file.
Offset? _lineMidpointScreenFor(SketchController controller, ViewTransform transform, String? lineId) {
  final line = controller.lines[lineId];
  if (line == null) return null;
  final start = controller.points[line.startPointId];
  final end = controller.points[line.endPointId];
  if (start == null || end == null) return null;
  return (transform.sketchToScreen(start.x, start.y) + transform.sketchToScreen(end.x, end.y)) / 2;
}

/// The midpoint between two Lines' own midpoints - the "between the two
/// entities" anchor heuristic (Stage 23e) shared by every value-less
/// two-Line constraint type (Parallel/Perpendicular/EqualLength/Collinear).
Offset? _twoLineMidpointScreen(
  SketchController controller,
  ViewTransform transform,
  String line1Id,
  String line2Id,
) {
  final mid1 = _lineMidpointScreenFor(controller, transform, line1Id);
  final mid2 = _lineMidpointScreenFor(controller, transform, line2Id);
  if (mid1 == null || mid2 == null) return null;
  return (mid1 + mid2) / 2;
}

/// Computes [ghost]'s on-screen layout - null if its anchor Points/Lines
/// are missing from [controller] (e.g. a stale ghost after a delete). Point-
/// anchored kinds (length/linear/vertical/horizontal/radius/diameter) lay
/// out from [ghost.pointAId]/[ghost.pointBId] directly; line-anchored kinds
/// (lineDistance/angle - new work package item 6's two-Line ghosts) lay out
/// from each Line's current midpoint instead, since there's no single pair
/// of Points to anchor to.
_GhostLayout? _layoutGhost(SketchController controller, ViewTransform transform, DimensionGhost ghost) {
  if (ghost.kind == GhostKind.lineDistance) {
    final midA = _lineMidpointScreenFor(controller, transform, ghost.lineAId);
    final midB = _lineMidpointScreenFor(controller, transform, ghost.lineBId);
    if (midA == null || midB == null) return null;
    final delta = midB - midA;
    final len = delta.distance;
    if (len < 1e-6) return null;
    final normal = Offset(-delta.dy, delta.dx) / len * _ghostOffsetPixels;
    final p1 = midA + normal;
    final p2 = midB + normal;
    return _GhostLayout((p1 + p2) / 2, [
      [midA, p1],
      [midB, p2],
      [p1, p2],
    ]);
  }

  if (ghost.kind == GhostKind.angle) {
    final midA = _lineMidpointScreenFor(controller, transform, ghost.lineAId);
    final midB = _lineMidpointScreenFor(controller, transform, ghost.lineBId);
    if (midA == null || midB == null) return null;
    final labelCenter = (midA + midB) / 2;
    return _GhostLayout(labelCenter, [
      [midA, labelCenter],
      [midB, labelCenter],
    ]);
  }

  final a = controller.points[ghost.pointAId];
  final b = controller.points[ghost.pointBId];
  if (a == null || b == null) return null;
  final aScreen = transform.sketchToScreen(a.x, a.y);
  final bScreen = transform.sketchToScreen(b.x, b.y);

  switch (ghost.kind) {
    case GhostKind.length:
    case GhostKind.linear:
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

    case GhostKind.lineDistance:
    case GhostKind.angle:
      return null; // handled above.
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

/// On-device feedback: default distance (screen pixels) a radius/diameter
/// dimension's label rests past the circle/arc's rim, along the entity's
/// own default direction, the very first time it's drawn (before the user
/// has ever dragged its label) - purely an initial resting offset, *not* a
/// minimum/maximum on where the label can subsequently be placed (an
/// earlier version of [_radialDimensionGeometry] also used this to clamp
/// the label's final on-screen distance from the rim, which is exactly
/// what made it impossible to drag a label to live anywhere the user
/// wanted, including inside the circle's own boundary - see that
/// function's own doc comment).
const double _radialLegLength = 24.0;

/// Screen-space geometry for a radius/diameter dimension's leader - see
/// [_radialDimensionGeometry]. [touchScreen] is where the leader's arrow
/// touches the circle/arc boundary; [touchCanvasAngle] is that touch
/// point's angle (Flutter canvas convention: 0 = +X, positive = clockwise)
/// around [centerScreen], used by [_SketchPainter] to test it against an
/// Arc's own drawn sweep. [shoulderScreen] and [labelCenter] are always
/// the same point (kept as two fields so [_SketchPainter]'s existing
/// two-segment draw calls stay harmless no-ops on the second segment) -
/// [touchCanvasAngle] is derived from [labelCenter]'s own bearing from
/// [centerScreen], so the straight line from [touchScreen] to
/// [labelCenter] is always already radially aligned; no separate kink is
/// needed to keep it touching the boundary at the right angle.
/// [oppositeTouchScreen] is the diametrically-opposite touch point (on the
/// far side of the centre) - always computed (cheap), but only drawn for a
/// diameter dimension.
class RadialDimensionGeometry {
  final Offset centerScreen;
  final double radiusPixels;
  final double touchCanvasAngle;
  final Offset touchScreen;
  final Offset shoulderScreen;
  final Offset labelCenter;
  final Offset oppositeTouchScreen;

  const RadialDimensionGeometry({
    required this.centerScreen,
    required this.radiusPixels,
    required this.touchCanvasAngle,
    required this.touchScreen,
    required this.shoulderScreen,
    required this.labelCenter,
    required this.oppositeTouchScreen,
  });
}

/// Technical-drawing-norms pass: a radius/diameter leader used to always
/// point at the constraint's own (arbitrary, fixed-at-creation) rim/start/
/// end Point regardless of where its label had been dragged - a better UX
/// makes the leader actually point wherever the label currently sits,
/// sweeping continuously around the centre as the label is dragged, with
/// the arrowhead always landing exactly on the circle/arc's boundary at
/// that angle (never on a fixed, possibly poorly-placed Point). [c]'s own
/// [DistanceConstraintDto.pointBId] is used only to derive the *default*
/// angle (where the leader points before it's ever been dragged) - once
/// [labelOffset] is non-zero, the touch point is recomputed purely from
/// [c]'s centre Point, its solved radius ([DistanceConstraintDto.distance]),
/// and the angle implied by the dragged label position. Returns null if
/// either endpoint Point is missing or the radius is degenerate.
///
/// Bug-fix round: [labelCenter] is now exactly [labelOffset] applied to the
/// default resting position - the *entire* drag is honoured, not just its
/// horizontal component. An earlier version clamped the label's final
/// distance from centre back onto a fixed [_radialLegLength] "shoulder"
/// (only the horizontal drag component ever reached the screen; vertical
/// drag only ever fed into the touch angle, never the label's own resting
/// distance), which made it impossible to park the label anywhere close to,
/// or inside, the circle's own boundary - exactly the restriction reported
/// as "the length of the arrow before the leg is the limiting factor".
/// Since [touchCanvasAngle] is derived from this same [labelCenter]'s
/// bearing from [centerScreen], [touchScreen] and [labelCenter] always sit
/// on one straight radial line by construction - already "the arrow aligned
/// to the leader line" technical-drawing norms call for - so no separate
/// kink is needed to reach it.
RadialDimensionGeometry? _radialDimensionGeometry(
  SketchController controller,
  ViewTransform transform,
  DistanceConstraintDto c,
  Offset labelOffset,
) {
  final center = controller.points[c.pointAId];
  final rim = controller.points[c.pointBId];
  if (center == null || rim == null) return null;
  final centerScreen = transform.sketchToScreen(center.x, center.y);
  final radiusPixels = c.distance * transform.pixelsPerUnit;
  if (radiusPixels < 1e-6) return null;

  final rimScreen = transform.sketchToScreen(rim.x, rim.y);
  final defaultDelta = rimScreen - centerScreen;
  final defaultLength = defaultDelta.distance;
  final defaultDirection = defaultLength < 1e-6 ? const Offset(1, 0) : defaultDelta / defaultLength;

  final labelCenter = centerScreen + defaultDirection * (radiusPixels + _radialLegLength) + labelOffset;
  final desiredDelta = labelCenter - centerScreen;
  final touchCanvasAngle = desiredDelta.distance < 1e-6
      ? math.atan2(defaultDirection.dy, defaultDirection.dx)
      : math.atan2(desiredDelta.dy, desiredDelta.dx);
  final direction = Offset(math.cos(touchCanvasAngle), math.sin(touchCanvasAngle));
  final touchScreen = centerScreen + direction * radiusPixels;
  // Always the same point as labelCenter (see this function's own doc
  // comment) - kept as a separate field only so [_SketchPainter]'s
  // touch->shoulder->label two-segment draw stays valid (the second
  // segment is simply a harmless zero-length no-op).
  final shoulderScreen = labelCenter;

  return RadialDimensionGeometry(
    centerScreen: centerScreen,
    radiusPixels: radiusPixels,
    touchCanvasAngle: touchCanvasAngle,
    touchScreen: touchScreen,
    shoulderScreen: shoulderScreen,
    labelCenter: labelCenter,
    oppositeTouchScreen: centerScreen * 2 - touchScreen,
  );
}

/// A Point pair's screen-space midpoint - null if either Point is missing.
/// Shared by [_constraintLabelCenter]'s Vertical/Horizontal cases, mirroring
/// [_SketchPainter._paintAxisIndicator]'s own midpoint layout.
Offset? _pointPairMidpointScreen(
  SketchController controller,
  ViewTransform transform,
  String pointAId,
  String pointBId,
) {
  final a = controller.points[pointAId];
  final b = controller.points[pointBId];
  if (a == null || b == null) return null;
  return (transform.sketchToScreen(a.x, a.y) + transform.sketchToScreen(b.x, b.y)) / 2;
}

/// [constraint]'s actual on-screen label center (with [labelOffset] already
/// applied), for hit-testing a [SketchMode.select] tap against it (new work
/// package item 4) - mirrors each of [_SketchPainter._paintDimensionOverlays]'s
/// per-type layouts exactly, so a tap is recognized precisely where the
/// label is actually drawn.
Offset? _constraintLabelCenter(
  SketchController controller,
  ViewTransform transform,
  ConstraintDto constraint,
  Offset labelOffset,
) {
  switch (constraint) {
    case DistanceConstraintDto c:
      // Cardinal-point axis constraints (see SketchController.
      // isCardinalAxisConstraint's own doc comment) are pure solver plumbing
      // - never rendered, so never hit-testable either.
      if (controller.isCardinalAxisConstraint(c)) return null;
      if (controller.isRadiusDistanceConstraint(c)) {
        // _radialDimensionGeometry already bakes labelOffset into its own
        // anchor math (it drives the leader's angle, not just a post-hoc
        // translation) - see its own doc comment - so it's returned as-is,
        // unlike every other case below.
        return _radialDimensionGeometry(controller, transform, c, labelOffset)?.labelCenter;
      }
      // Technical-drawing-norms pass: an Ellipse axis constraint (still
      // centre-to-tip under the hood) renders/hit-tests as an ordinary
      // tip-to-tip length dimension instead - see
      // [SketchController.ellipseAxisForDistanceConstraint]'s own doc
      // comment.
      final ellipseAxis = controller.ellipseAxisForDistanceConstraint(c);
      final String pointAId;
      final String pointBId;
      if (ellipseAxis != null) {
        (pointAId, pointBId) = ellipseAxis;
      } else {
        pointAId = c.pointAId;
        pointBId = c.pointBId;
      }
      final a = controller.points[pointAId];
      final b = controller.points[pointBId];
      if (a == null || b == null) return null;
      final aScreen = transform.sketchToScreen(a.x, a.y);
      final bScreen = transform.sketchToScreen(b.x, b.y);
      // Must mirror _paintDistanceDimension's per-orientation layout exactly,
      // or dragging/hit-testing a horizontal/vertical dimension's label
      // would target the old diagonal-layout midpoint instead of where it's
      // actually drawn.
      switch (c.orientation) {
        case 'vertical':
          final offsetX = math.max(aScreen.dx, bScreen.dx) + 18.0;
          return Offset(offsetX, (aScreen.dy + bScreen.dy) / 2) + labelOffset;
        case 'horizontal':
          final offsetY = math.max(aScreen.dy, bScreen.dy) + 18.0;
          return Offset((aScreen.dx + bScreen.dx) / 2, offsetY) + labelOffset;
        default:
          final delta = bScreen - aScreen;
          final length = delta.distance;
          if (length < 1e-6) return null;
          final normal = Offset(-delta.dy, delta.dx) / length;
          const offsetDistance = 18.0;
          final offset = normal * offsetDistance;
          return (aScreen + offset + bScreen + offset) / 2 + labelOffset;
      }
    case VerticalConstraintDto c:
      final base = _pointPairMidpointScreen(controller, transform, c.pointAId, c.pointBId);
      return base == null ? null : base + labelOffset;
    case HorizontalConstraintDto c:
      final base = _pointPairMidpointScreen(controller, transform, c.pointAId, c.pointBId);
      return base == null ? null : base + labelOffset;
    case AngleConstraintDto c:
      final midpoint1 = _lineMidpointScreenFor(controller, transform, c.line1Id);
      final midpoint2 = _lineMidpointScreenFor(controller, transform, c.line2Id);
      if (midpoint1 == null || midpoint2 == null) return null;
      return (midpoint1 + midpoint2) / 2 + labelOffset;
    case LineDistanceConstraintDto c:
      final midA = _lineMidpointScreenFor(controller, transform, c.line1Id);
      final midB = _lineMidpointScreenFor(controller, transform, c.line2Id);
      if (midA == null || midB == null) return null;
      final delta = midB - midA;
      final length = delta.distance;
      if (length < 1e-6) return null;
      final normal = Offset(-delta.dy, delta.dx) / length;
      const offsetDistance = 18.0;
      final offset = normal * offsetDistance;
      return (midA + offset + midB + offset) / 2 + labelOffset;
    // Stage 23e: extends label rendering/hit-testing to every remaining
    // constraint type. AtMidpointConstraintDto is deliberately excluded -
    // Stage 22 decided it renders no badge at all, since it's purely a
    // construction-time fixup with nothing useful to label or delete from
    // the canvas.
    case CoincidentConstraintDto c:
      final base = _pointPairMidpointScreen(controller, transform, c.pointAId, c.pointBId);
      return base == null ? null : base + labelOffset;
    case ParallelConstraintDto c:
      final base = _twoLineMidpointScreen(controller, transform, c.line1Id, c.line2Id);
      return base == null ? null : base + labelOffset;
    case PerpendicularConstraintDto c:
      final base = _twoLineMidpointScreen(controller, transform, c.line1Id, c.line2Id);
      return base == null ? null : base + labelOffset;
    case EqualLengthConstraintDto c:
      final base = _twoLineMidpointScreen(controller, transform, c.line1Id, c.line2Id);
      return base == null ? null : base + labelOffset;
    case CollinearConstraintDto c:
      final base = _twoLineMidpointScreen(controller, transform, c.line1Id, c.line2Id);
      return base == null ? null : base + labelOffset;
    case PointLineDistanceConstraintDto c:
      final point = controller.points[c.pointId];
      final lineMid = _lineMidpointScreenFor(controller, transform, c.lineId);
      if (point == null || lineMid == null) return null;
      final pointScreen = transform.sketchToScreen(point.x, point.y);
      return (pointScreen + lineMid) / 2 + labelOffset;
    default:
      return null;
  }
}

/// The id of whichever currently-rendered Constraint's label [canvasPos]
/// landed within [radius] of, or null if it missed all of them - see
/// [_constraintLabelCenter]'s own doc comment on how [SketchController.
/// labelOffsetFor] (Stage 15 item 2) is folded in, so this never disagrees
/// with where [_SketchPainter] actually draws it after a drag. Public
/// (unlike its sibling hit-testers in this file) so it's directly
/// unit-testable without pumping a real widget tree - see
/// [_SketchCanvasState._handleDragModeTap], which checks this first,
/// ahead of a Point/Line grab.
String? dimensionLabelAt(
  SketchController controller,
  ViewTransform transform,
  Offset canvasPos,
  double radius,
) {
  for (final entry in controller.constraints.entries) {
    final labelOffset = controller.labelOffsetFor(entry.key);
    final actual = _constraintLabelCenter(controller, transform, entry.value, labelOffset);
    if (actual == null) continue;
    if ((canvasPos - actual).distance <= radius) {
      return entry.key;
    }
  }
  return null;
}

/// The id of whichever currently-rendered Constraint's label
/// [screenPosition] landed on, or null if it missed all of them - see
/// [_SketchCanvasState._dispatchTap]. Reuses [_ghostHitRadiusPixels]'s
/// touch target, same generous tolerance as ghost-label hit-testing.
String? _constraintIdAt(SketchController controller, ViewTransform transform, Offset screenPosition) {
  return dimensionLabelAt(controller, transform, screenPosition, _ghostHitRadiusPixels);
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
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final current = widget.controller.currentGhostValue(widget.ghost);
    _text = TextEditingController(text: current == null ? '' : current.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _text.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // Releasing focus explicitly before the controller call below removes
  // this whole widget (activeGhostKey reverting to null) avoids a Flutter
  // framework race where a still-focused TextField is unmounted before its
  // Focus dependents are cleaned up, which trips the
  // '_dependents.isEmpty' assertion in framework.dart. unfocus() only
  // *schedules* that focus change though - FocusManager applies it during
  // the next frame's pre-build phase, so the controller call that removes
  // this widget (via notifyListeners() triggering the AnimatedBuilder in
  // [SketchCanvas] that owns this editor) is deferred to a post-frame
  // callback, guaranteeing a full frame elapses first rather than racing
  // the focus-change application within the same frame.
  void _confirm() {
    final value = double.tryParse(_text.text);
    if (value == null) return;
    _focusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.confirmGhostValue(widget.ghost.key, value);
    });
  }

  void _cancel() {
    _focusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.cancelGhostEdit();
    });
  }

  @override
  Widget build(BuildContext context) {
    final suffix = widget.ghost.kind == GhostKind.angle ? '°' : 'mm';
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
                  focusNode: _focusNode,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(isDense: true, suffixText: suffix),
                  onSubmitted: (_) => _confirm(),
                ),
              ),
              IconButton(
                tooltip: 'Confirm',
                icon: SvgPicture.asset(
                  'assets/icons/dimbar/dimbar_confirm.svg',
                  width: 24,
                  height: 24,
                  colorFilter: ColorFilter.mode(
                    Theme.of(context).colorScheme.onSurface,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: _confirm,
              ),
              IconButton(
                tooltip: 'Cancel',
                icon: SvgPicture.asset(
                  'assets/icons/dimbar/dimbar_exit.svg',
                  width: 24,
                  height: 24,
                  colorFilter: ColorFilter.mode(
                    Theme.of(context).colorScheme.onSurface,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: _cancel,
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
  final List<(String, int, double, double)> referenceGhostVertices;
  final bool referenceBodyHidden;
  final bool labelsVisible;
  final Color canvasColor;
  final double canvasOpacity;

  _SketchPainter({
    required this.controller,
    required this.transform,
    this.referenceGhostSegments = const [],
    this.referenceGhostVertices = const [],
    this.referenceBodyHidden = false,
    this.labelsVisible = true,
    this.canvasColor = SketchCanvas.defaultColor,
    this.canvasOpacity = 1.0,
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

  /// Drag-mode's "currently grabbed" highlight - the entity a tap has
  /// picked up (see [SketchController.isEntityGrabbed]) while its cursor is
  /// hidden (see this painter's cursor-visibility check), so it needs to
  /// read as unambiguously "this is what's about to move" - distinct from
  /// both selected (purple) and hover (amber) and given priority over them.
  static const Color _grabbedColor = Colors.orangeAccent;

  /// The crosshair's color while [SketchMode.draw] is active - distinct
  /// from [_selectCursorColor] so the cursor itself signals "you are
  /// sketching right now" independent of any toolbar/mode-label text.
  static const Color _sketchingCursorColor = Colors.green;
  static const Color _selectCursorColor = Colors.red;

  /// Construction-only Line/Circle color (Stage 12 item 7) - dashed,
  /// everywhere this painter draws entities, so it stays visually distinct
  /// from solid geometry at a glance.
  static const Color _constructionColor = Color(0xFF4A90D9);

  /// Phase 3 (3.1): a Line/Circle/Point whose defining Points are all fully
  /// constrained (see [SketchController.rigidity]/[SketchController.
  /// isFullyConstrained]) - deliberately a darker green than
  /// [_sketchingCursorColor]'s plain green (the draw-mode cursor) or the
  /// origin marker's "snapping" green, both unrelated signals, so none of
  /// the three read as the same thing. Bug-fix round: nudged a shade
  /// brighter than the original 0xFF1B5E20 per on-device feedback ("a
  /// touch more green").
  static const Color _fullyConstrainedColor = Color(0xFF2E7D32);

  /// Phase 3: a Line/Circle/Point that is *not* fully constrained and
  /// *not* flagged as over-constrained either - plain "still has freedom"
  /// charcoal grey, replacing the old sketch-wide-only black/blueGrey
  /// split (Prompt B item B5) now that per-entity colouring covers that
  /// role instead.
  static const Color _unconstrainedColor = Color(0xFF36454F);

  /// Phase 3 (3.2): a Line/Circle/Point implicated by an over-constrained
  /// (redundant/conflicting) Constraint cluster, or by one of the other
  /// red sources [SketchController.isPointForcedOverConstrained] combines
  /// (a backend solve failure, or a structurally-degenerate Constraint
  /// combination - see that method's doc comment) - a slightly deeper red
  /// than [_selectCursorColor]'s plain red (an unrelated cursor color), so
  /// it reads as a deliberate warning rather than incidentally the same
  /// shade.
  static const Color _overConstrainedColor = Color(0xFFB71C1C);

  /// Technical-drawing-norms pass: a real measured dimension's line/
  /// extension-line/arrowhead geometry (Distance, Radius/Diameter,
  /// LineDistance, Angle, PointLineDistance - every case [_paintDimensionOverlays]
  /// passes `plainBlackText: true` for) now reads as plain black, matching
  /// ISO 128/ASME Y14.2 convention (a dimension line is a thin black line,
  /// not a status color) - distinct from [_constraintBadgeColor] below,
  /// which stays the original amber for the value-less relationship badges
  /// (V/H/Coincident/Parallel/etc.) that have no real technical-drawing
  /// equivalent to match and are meant to read as a status indicator, not a
  /// measurement.
  static const Color _dimensionLineColor = Colors.black;

  /// Stage 12 item 10's original dimension-overlay color, now scoped to
  /// just the value-less constraint badges - see [_dimensionLineColor]'s
  /// own doc comment for why real dimensions no longer share this color.
  static const Color _constraintBadgeColor = Color(0xFFF5A623);

  /// Stage 13 item 5/6's ghost-dimension colors: dashed grey by default,
  /// blue for the ghost currently being edited, dimmer grey for the
  /// unchosen ghost in a V/H or radius/diameter pair while the other one is
  /// being edited.
  static const Color _ghostDefaultColor = Color(0xFF888888);
  static const Color _ghostActiveColor = Color(0xFF4A90D9);
  static const Color _ghostInactiveColor = Color(0xFF555555);
  static const Color _ghostLabelBackground = Color(0xCC222222);

  /// Sketcher global size-down: every point/line/label size below is
  /// centralized here (rather than scattered magic numbers) specifically so
  /// it's a one-line change to re-tune after on-device feedback - the
  /// values below are a first pass, not final. All shrunk from their prior
  /// values (noted per-constant) in response to feedback that the sketcher
  /// felt oversized generally, independent of the touch hit-radius (which
  /// stays deliberately more generous than the visual size for touchability
  /// - see [SketchController.minTapHitRadiusPixels]/[SketchController.pointHitRadiusMultiplier]).
  static const double _pointRadius = 3.0; // was 4
  static const double _pointRadiusEmphasis = 4.5; // was 6 (chain-start/circle-center/hover)
  static const double _pointRadiusSelected = 5.0; // was 7
  static const double _pointRadiusSnapping = 7.0; // was 11 (chain-start snap-to-close)
  static const double _lineStrokeWidth = 1.5; // was 2
  static const double _lineStrokeWidthEmphasis = 2.25; // was 3 (selected/hover)
  static const double _originHalfSize = 5.0; // was 7
  static const double _originHalfSizeSnapping = 7.0; // was 10
  static const double _dimensionFontSize = 9.5; // was 11
  static const double _snapHighlightPointRadius = 3.0; // was 4 (snap/coincident highlight base)
  static const double _midpointSnapIndicatorRadius = 6.5; // was 9

  /// Technical-drawing-norms pass: a dimension/extension/leader line reads
  /// thinner than the entity lines it measures - about 3/4 of
  /// [_lineStrokeWidth] - so it's visually subordinate to the geometry,
  /// matching standard technical-drawing weight hierarchy (dimension lines
  /// thinner than visible/object lines). Was a bare `1` duplicated at every
  /// dimension paint call site; centralized here like every other constant
  /// in this block.
  static const double _dimensionStrokeWidth = _lineStrokeWidth * 0.75;

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

  /// Draws a dashed oval outline within [rect] - used for construction
  /// Ellipses, mirroring [_drawDashedCircle]'s fixed-angle dash walk
  /// exactly, generalized from a circular to an elliptical bounding rect
  /// (`Path.addArc` already supports either - a circle is just the
  /// special case of an oval with equal width/height).
  void _drawDashedOval(Canvas canvas, Rect rect, Paint paint) {
    const dashAngle = 0.12; // radians
    const gapAngle = 0.08;
    var angle = 0.0;
    while (angle < 2 * math.pi) {
      final sweep = math.min(dashAngle, 2 * math.pi - angle);
      final path = Path()..addArc(rect, angle, sweep);
      canvas.drawPath(path, paint);
      angle += dashAngle + gapAngle;
    }
  }

  /// Draws an arbitrary [path] (e.g. a Spline's own multi-segment cubic
  /// curve) dashed - unlike the fixed-angle walks
  /// [_drawDashedCircle]/[_drawDashedArc]/[_drawDashedOval] use (each
  /// shape's own simple parametrization makes an angle-based walk
  /// natural), a Spline has no single parametrization to walk like that,
  /// so this instead uses `Path.computeMetrics()` - Flutter's own
  /// arc-length-based sub-path extraction - to walk fixed *lengths*
  /// instead, the same on/off dash rhythm in spirit.
  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    const dashLength = 6.0;
    const gapLength = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = math.min(distance + dashLength, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += dashLength + gapLength;
      }
    }
  }

  /// Draws a dashed arc outline (a construction Arc's version of
  /// [_drawDashedCircle]) - walks [startAngle]/[sweepAngle] (both already
  /// in Flutter's `Canvas.drawArc` convention - see [_arcScreenAngles]) in
  /// fixed-angle on/off increments, honoring [sweepAngle]'s sign so a
  /// negative (CCW-on-screen) sweep dashes in the same direction the solid
  /// version would draw.
  void _drawDashedArc(Canvas canvas, Rect rect, double startAngle, double sweepAngle, Paint paint) {
    const dashAngle = 0.12; // radians
    const gapAngle = 0.08;
    final direction = sweepAngle < 0 ? -1.0 : 1.0;
    final totalSweep = sweepAngle.abs();
    var travelled = 0.0;
    while (travelled < totalSweep) {
      final segment = math.min(dashAngle, totalSweep - travelled);
      final path = Path()..addArc(rect, startAngle + direction * travelled, direction * segment);
      canvas.drawPath(path, paint);
      travelled += dashAngle + gapAngle;
    }
  }

  /// The [Canvas.drawArc] `(startAngle, sweepAngle)` pair that renders the
  /// arc from ([startX], [startY]) to ([endX], [endY]) around
  /// ([centerX], [centerY]) exactly matching the sketch's own CCW-in-local-
  /// space convention (see the backend's `app.sketch.models.Arc`
  /// docstring) - Flutter's angle convention (0 = +X, positive = clockwise
  /// on a Y-down canvas) is the mirror image of that (Y-up, positive =
  /// counter-clockwise), so both angles are negated here to undo
  /// [ViewTransform.sketchToScreen]'s Y-flip.
  (double, double) _arcScreenAngles(
    double centerX,
    double centerY,
    double startX,
    double startY,
    double endX,
    double endY,
  ) {
    final startAngle = math.atan2(startY - centerY, startX - centerX);
    final endAngle = math.atan2(endY - centerY, endX - centerX);
    final sweep = normalizeSketchAngle(endAngle - startAngle);
    return (-startAngle, -sweep);
  }

  /// Stage 12 item 10: renders every Constraint in [SketchController.constraints]
  /// as a render-only overlay - there is no client-side UI to create or edit
  /// a Distance/Angle value yet (the backend has no PATCH endpoint for
  /// constraint values), so these are display-only, dispatched by runtime
  /// type since [ConstraintDto] isn't a sealed hierarchy.
  void _paintDimensionOverlays(Canvas canvas) {
    final selectionSet = controller.selectionSet;
    for (final entry in controller.constraints.entries) {
      final isSelected =
          selectionSet.any((s) => s.kind == SelectionKind.constraint && s.id == entry.key);
      // Two colors sharing the same selected override - see
      // _dimensionLineColor's own doc comment for why measurements and
      // badges no longer share one unselected color.
      final dimensionColor = isSelected ? _selectedColor : _dimensionLineColor;
      final badgeColor = isSelected ? _selectedColor : _constraintBadgeColor;
      final labelOffset = controller.labelOffsetFor(entry.key);
      switch (entry.value) {
        case DistanceConstraintDto c:
          // Cardinal-point axis constraints are pure solver plumbing (see
          // SketchController.isCardinalAxisConstraint) - never drawn.
          if (controller.isCardinalAxisConstraint(c)) break;
          // Auto-created radius/diameter/axis dimensions stay hidden until
          // the user explicitly confirms one via the ghost-value flow (see
          // SketchController.isHiddenDimension's own doc comment).
          if (controller.isHiddenDimension(entry.key)) break;
          if (controller.isRadiusDistanceConstraint(c)) {
            _paintRadiusDiameterDimension(
              canvas,
              c,
              dimensionColor,
              labelOffset,
              controller.showsDiameterFor(entry.key),
            );
          } else {
            _paintDistanceDimension(canvas, c, dimensionColor, labelOffset);
          }
        case VerticalConstraintDto c:
          _paintAxisIndicator(canvas, c.pointAId, c.pointBId, 'V', badgeColor, labelOffset);
        case HorizontalConstraintDto c:
          _paintAxisIndicator(canvas, c.pointAId, c.pointBId, 'H', badgeColor, labelOffset);
        case AngleConstraintDto c:
          _paintAngleDimension(canvas, c, dimensionColor, labelOffset);
        case LineDistanceConstraintDto c:
          _paintLineDistanceDimension(canvas, c, dimensionColor, labelOffset);
        // Stage 23e: every remaining constraint type gets a small label too
        // (AtMidpointConstraintDto stays excluded - see _constraintLabelCenter).
        case CoincidentConstraintDto c:
          _paintAxisIndicator(canvas, c.pointAId, c.pointBId, 'Coinc.', badgeColor, labelOffset);
        case ParallelConstraintDto c:
          _paintTwoLineGlyph(canvas, c.line1Id, c.line2Id, '∥', badgeColor, labelOffset);
        case PerpendicularConstraintDto c:
          _paintTwoLineGlyph(canvas, c.line1Id, c.line2Id, '⟂', badgeColor, labelOffset);
        case EqualLengthConstraintDto c:
          _paintTwoLineGlyph(canvas, c.line1Id, c.line2Id, '=', badgeColor, labelOffset);
        case CollinearConstraintDto c:
          _paintTwoLineGlyph(canvas, c.line1Id, c.line2Id, 'Collin.', badgeColor, labelOffset);
        case PointLineDistanceConstraintDto c:
          _paintPointLineDistanceDimension(canvas, c, dimensionColor, labelOffset);
        default:
          break;
      }
    }
  }

  /// Traditional-drawing dimension repositioning: dragging a distance/
  /// line-distance dimension's label used to leave the dimension line
  /// itself fixed and draw a separate leader line out to the floating
  /// label - not how a real technical drawing looks, and reported as an
  /// unwanted extra line. Instead, the drag *relocates the dimension line
  /// itself* (this perpendicular offset distance), so the extension lines
  /// stretch/shrink to reach it and the label sits directly on the
  /// (now-relocated) dimension line, same as [_paintDistanceDimension]/
  /// [_paintLineDistanceDimension] already did before any drag - no
  /// separate leader line needed. [normal] must be a *unit* vector in the
  /// dimension line's offset direction; the drag offset is projected onto
  /// it so only the perpendicular component moves the line (sliding the
  /// label along the line's own direction isn't supported yet). The
  /// magnitude is floored so the dimension line can't collapse onto the
  /// geometry it measures, but the sign is free to flip - dragging the
  /// label to the other side of the measured entities moves the whole
  /// dimension there too, same as a real CAD tool allows.
  static const double _defaultDimensionOffset = 18.0;
  static const double _minDimensionOffsetMagnitude = 6.0;

  double _dimensionOffsetDistance(Offset normal, Offset labelOffset) {
    if (labelOffset == Offset.zero) return _defaultDimensionOffset;
    final projected = labelOffset.dx * normal.dx + labelOffset.dy * normal.dy;
    final raw = _defaultDimensionOffset + projected;
    if (raw.abs() < _minDimensionOffsetMagnitude) {
      return raw.isNegative ? -_minDimensionOffsetMagnitude : _minDimensionOffsetMagnitude;
    }
    return raw;
  }

  /// ISO 129/ASME Y14.5-style extension (witness) line: leaves a small gap
  /// at [from] (the actual measured Point/Line-midpoint - a witness line
  /// conventionally never touches the geometry it measures) and overshoots
  /// slightly past [to] (where it meets the dimension line), instead of
  /// running as a plain edge-to-edge connecting segment.
  static const double _extensionLineGap = 4.0;
  static const double _extensionLineOvershoot = 3.0;

  void _drawExtensionLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    final delta = to - from;
    final length = delta.distance;
    if (length < 1e-6) return;
    final direction = delta / length;
    canvas.drawLine(from + direction * _extensionLineGap, to + direction * _extensionLineOvershoot, paint);
  }

  /// ISO 129/ASME Y14.5-style dimension-line arrowhead: a small filled
  /// triangle with its tip at [tip], pointing along [direction] (a unit
  /// vector pointing outward, away from the dimension line's other end) -
  /// the two arrows on a dimension line point away from each other, tips
  /// touching the extension lines, same as every traditional technical
  /// drawing.
  static const double _arrowheadLength = 8.0;
  static const double _arrowheadHalfWidth = 2.5;

  void _drawArrowhead(Canvas canvas, Offset tip, Offset direction, Color color) {
    final normal = Offset(-direction.dy, direction.dx);
    final base = tip - direction * _arrowheadLength;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((base + normal * _arrowheadHalfWidth).dx, (base + normal * _arrowheadHalfWidth).dy)
      ..lineTo((base - normal * _arrowheadHalfWidth).dx, (base - normal * _arrowheadHalfWidth).dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  /// Draws both outward-pointing arrowheads for a dimension line running
  /// [p1] to [p2] - shared by every dimension overlay with a real
  /// two-extension-line-plus-offset-segment layout.
  void _drawDimensionArrows(Canvas canvas, Offset p1, Offset p2, Color color) {
    final delta = p2 - p1;
    final length = delta.distance;
    if (length < 1e-6) return;
    final unit = delta / length;
    _drawArrowhead(canvas, p1, -unit, color);
    _drawArrowhead(canvas, p2, unit, color);
  }

  /// Draws a small rounded-rect "chip" centered on [center] with [text] -
  /// shared by every dimension overlay below so they all read consistently
  /// against busy sketch geometry.
  ///
  /// On-device feedback: a *confirmed* dimension's value ([plainBlackText])
  /// now reads as plain black text on a near-white chip - unambiguous at a
  /// glance, matching how a real technical drawing renders dimension text -
  /// instead of white-on-[color] (still loud/legible, but read as more of a
  /// status indicator than a measurement). [color] still outlines the chip
  /// (a thin border, not a fill) so the existing orange/purple
  /// unselected/selected signal survives as a subtle cue rather than
  /// disappearing outright. A live *ghost* dimension (still being edited,
  /// not yet confirmed) keeps the original white-on-[color] fill instead -
  /// [plainBlackText] defaults to false, so [_paintGhostDimensions]'s own
  /// call site (the only other caller) is unaffected.
  /// The Unicode diameter sign (U+2300) renders visually smaller/thinner
  /// than digits at the same nominal font size in most fonts (a well-known
  /// typography mismatch) - on-device feedback confirmed it read as
  /// noticeably undersized next to the value it prefixes. Bumped by this
  /// factor whenever [text] starts with it, so the symbol reads as the same
  /// visual size as the digits that follow.
  static const double _diameterSymbolScale = 1.35;

  void _drawDimensionLabel(Canvas canvas, Offset center, String text, Color color,
      {bool plainBlackText = false}) {
    final baseStyle = TextStyle(
      color: plainBlackText ? Colors.black : Colors.white,
      fontSize: _dimensionFontSize,
      fontWeight: FontWeight.w600,
    );
    final isDiameter = text.startsWith('⌀');
    final textSpan = isDiameter
        ? TextSpan(
            children: [
              TextSpan(text: '⌀', style: baseStyle.copyWith(fontSize: _dimensionFontSize * _diameterSymbolScale)),
              TextSpan(text: text.substring(1), style: baseStyle),
            ],
          )
        : TextSpan(text: text, style: baseStyle);
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();
    const horizontalPadding = 4.0;
    const verticalPadding = 2.0;
    final chipRect = Rect.fromCenter(
      center: center,
      width: textPainter.width + horizontalPadding * 2,
      height: textPainter.height + verticalPadding * 2,
    );
    final chipRRect = RRect.fromRectAndRadius(chipRect, const Radius.circular(3));
    if (plainBlackText) {
      // On-device feedback: a numeric dimension (a measurement) no longer
      // gets a colored border at all - just the plain near-white chip, so
      // it reads unambiguously as a value rather than a status indicator.
      // Constraints (see _paintAxisIndicator/_paintTwoLineGlyph) keep the
      // solid-color-fill styling below instead, for exactly that "status
      // indicator" reading.
      canvas.drawRRect(chipRRect, Paint()..color = const Color(0xFFF5F5F5));
    } else {
      canvas.drawRRect(chipRRect, Paint()..color = color);
    }
    textPainter.paint(canvas, center - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  /// Distance dimension: a standard two-extension-line-plus-offset-segment
  /// layout, offset perpendicular to the constrained points by a fixed
  /// pixel amount (so it reads clearly regardless of zoom), labeled with
  /// the constraint's own [DistanceConstraintDto.distance] (the solved
  /// value, not a measurement of the current screen geometry). Also handles
  /// an Ellipse axis constraint (see [SketchController.
  /// ellipseAxisForDistanceConstraint]) - technical-drawing-norms pass: an
  /// Ellipse has no uniform "radius", so each axis reads as an ordinary
  /// tip-to-tip length dimension here instead of [_paintRadiusDiameterDimension]'s
  /// radial leader, with the label doubled from the underlying (still
  /// centre-based, semi-axis) constraint value - the same "double for
  /// display" trick a Circle's diameter already uses.
  void _paintDistanceDimension(Canvas canvas, DistanceConstraintDto c, Color color, Offset labelOffset) {
    final ellipseAxis = controller.ellipseAxisForDistanceConstraint(c);
    final String pointAId;
    final String pointBId;
    final double displayValue;
    if (ellipseAxis != null) {
      (pointAId, pointBId) = ellipseAxis;
      displayValue = c.distance * 2;
    } else {
      pointAId = c.pointAId;
      pointBId = c.pointBId;
      displayValue = c.distance;
    }
    final a = controller.points[pointAId];
    final b = controller.points[pointBId];
    if (a == null || b == null) return;
    final aScreen = transform.sketchToScreen(a.x, a.y);
    final bScreen = transform.sketchToScreen(b.x, b.y);

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;

    // Bug-fix: this used to always lay out as a plain linear dimension (an
    // offset line parallel to a-b), even for horizontal/vertical
    // constraints - so a horizontal dimension between two points at
    // different heights rendered as a diagonal line indistinguishable from
    // a linear one once confirmed, even though the underlying constraint
    // correctly only pinned the X separation. Mirror [_layoutGhost]'s
    // vertical/horizontal layout here so the persisted rendering matches
    // the ghost preview the user placed.
    final Offset p1;
    final Offset p2;
    switch (c.orientation) {
      case 'vertical':
        const normal = Offset(1, 0);
        final offsetX = math.max(aScreen.dx, bScreen.dx) + _dimensionOffsetDistance(normal, labelOffset);
        p1 = Offset(offsetX, aScreen.dy);
        p2 = Offset(offsetX, bScreen.dy);
      case 'horizontal':
        const normal = Offset(0, 1);
        final offsetY = math.max(aScreen.dy, bScreen.dy) + _dimensionOffsetDistance(normal, labelOffset);
        p1 = Offset(aScreen.dx, offsetY);
        p2 = Offset(bScreen.dx, offsetY);
      default:
        final delta = bScreen - aScreen;
        final length = delta.distance;
        if (length < 1e-6) return;
        final normal = Offset(-delta.dy, delta.dx) / length;
        final offsetVec = normal * _dimensionOffsetDistance(normal, labelOffset);
        p1 = aScreen + offsetVec;
        p2 = bScreen + offsetVec;
    }

    _drawExtensionLine(canvas, aScreen, p1, dimPaint);
    _drawExtensionLine(canvas, bScreen, p2, dimPaint);
    canvas.drawLine(p1, p2, dimPaint);
    _drawDimensionArrows(canvas, p1, p2, color);

    _drawDimensionLabel(canvas, (p1 + p2) / 2, displayValue.toStringAsFixed(2), color, plainBlackText: true);
  }

  /// Radial (radius/diameter) dimension for a Circle or Arc's
  /// DistanceConstraint - see [SketchController.circleForDistanceConstraint]/
  /// [SketchController.arcForDistanceConstraint]/[SketchController.showsDiameterFor].
  /// On-device feedback: the leader now points wherever the label has been
  /// dragged (see [_radialDimensionGeometry]'s own doc comment), touching
  /// the boundary's actual geometry at that angle rather than the
  /// constraint's own fixed rim/start/end Point - "a better user experience
  /// shows the dimension actually pointing to the arc or circle". A radius
  /// dimension is a single leader from the touch point (arrowhead pointing
  /// back toward centre) out to a shoulder, then a horizontal landing leg
  /// to the label; a diameter dimension spans the whole circle (touch point
  /// through centre to the diametrically-opposite point), arrowheads at
  /// both ends, same shoulder/landing leg on the near side. For an Arc
  /// whose touch angle falls outside its own drawn sweep, a dashed grey
  /// extension fills the gap - see [_paintArcExtensionIfNeeded].
  void _paintRadiusDiameterDimension(
    Canvas canvas,
    DistanceConstraintDto c,
    Color color,
    Offset labelOffset,
    bool showsDiameter,
  ) {
    final geometry = _radialDimensionGeometry(controller, transform, c, labelOffset);
    if (geometry == null) return;

    _paintArcExtensionIfNeeded(canvas, controller.arcForDistanceConstraint(c), c, geometry);

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;
    final direction = Offset(math.cos(geometry.touchCanvasAngle), math.sin(geometry.touchCanvasAngle));

    if (showsDiameter) {
      canvas.drawLine(geometry.oppositeTouchScreen, geometry.touchScreen, dimPaint);
      canvas.drawLine(geometry.touchScreen, geometry.shoulderScreen, dimPaint);
      canvas.drawLine(geometry.shoulderScreen, geometry.labelCenter, dimPaint);
      _drawArrowhead(canvas, geometry.touchScreen, direction, color);
      _drawArrowhead(canvas, geometry.oppositeTouchScreen, -direction, color);
      _drawDimensionLabel(
        canvas,
        geometry.labelCenter,
        '⌀${(c.distance * 2).toStringAsFixed(2)}',
        color,
        plainBlackText: true,
      );
    } else {
      canvas.drawLine(geometry.touchScreen, geometry.shoulderScreen, dimPaint);
      canvas.drawLine(geometry.shoulderScreen, geometry.labelCenter, dimPaint);
      // On-device feedback: the arrowhead touches the boundary either way,
      // but must point *back towards the centre* (standard radius-dimension
      // convention - the leader reads as "this far, back to the centre")
      // rather than outward, which read as a disconnected mark instead of
      // a continuation of the centre-to-rim line.
      _drawArrowhead(canvas, geometry.touchScreen, -direction, color);
      _drawDimensionLabel(
        canvas,
        geometry.labelCenter,
        'R${c.distance.toStringAsFixed(2)}',
        color,
        plainBlackText: true,
      );
    }
  }

  /// Dashed grey (arc-extension) color - visually distinct from every real
  /// entity/dimension color so it reads unambiguously as "not really
  /// there", the same role [_referenceGhostColor] plays for a reference
  /// body's own ghost wireframe.
  static const Color _arcExtensionColor = Color(0xFF999999);

  /// On-device feedback: a radius/diameter leader is free to point anywhere
  /// around the full circle (dragging the label sweeps it continuously),
  /// but an Arc only actually draws part of that circle - if [geometry]'s
  /// touch angle falls in the "missing" part, this fills the gap with a
  /// dashed grey arc from whichever of [arc]'s two ends is angularly
  /// nearer (the shorter extension), so the arrowhead still visibly lands
  /// on something rather than floating in empty space. A full Circle (or
  /// any other shape - [arc] is null) draws nothing extra, since every
  /// angle is already real geometry.
  void _paintArcExtensionIfNeeded(
    Canvas canvas,
    SketchArcView? arc,
    DistanceConstraintDto c,
    RadialDimensionGeometry geometry,
  ) {
    if (arc == null) return;
    final center = controller.points[arc.centerPointId];
    final start = controller.points[arc.startPointId];
    final end = controller.points[arc.endPointId];
    if (center == null || start == null || end == null) return;
    final startAngle = normalizeSketchAngle(math.atan2(start.y - center.y, start.x - center.x));
    final endAngle = normalizeSketchAngle(math.atan2(end.y - center.y, end.x - center.x));
    // touchCanvasAngle is in Flutter's Y-down canvas convention; negate
    // back to the sketch's Y-up/CCW convention to compare against the
    // Arc's own sweep (see _arcScreenAngles' own doc comment on this same
    // negation).
    final touchSketchAngle = normalizeSketchAngle(-geometry.touchCanvasAngle);
    if (angleWithinArcSweep(touchSketchAngle, startAngle, endAngle)) return;

    final gapSize = normalizeSketchAngle(startAngle - endAngle);
    final distFromEnd = normalizeSketchAngle(touchSketchAngle - endAngle);
    final nearEnd = distFromEnd <= gapSize - distFromEnd;

    final touchSketchX = center.x + math.cos(touchSketchAngle) * c.distance;
    final touchSketchY = center.y + math.sin(touchSketchAngle) * c.distance;

    final (dashStartAngle, dashSweepAngle) = nearEnd
        ? _arcScreenAngles(center.x, center.y, end.x, end.y, touchSketchX, touchSketchY)
        : _arcScreenAngles(center.x, center.y, touchSketchX, touchSketchY, start.x, start.y);

    final rect = Rect.fromCircle(center: geometry.centerScreen, radius: geometry.radiusPixels);
    final dashPaint = Paint()
      ..color = _arcExtensionColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = _dimensionStrokeWidth;
    _drawDashedArc(canvas, rect, dashStartAngle, dashSweepAngle, dashPaint);
  }

  /// Line-to-line distance dimension (Stage 16 item 9's `LineDistanceConstraint`):
  /// same two-extension-line-plus-offset-segment layout as
  /// [_paintDistanceDimension], but anchored at each Line's current midpoint
  /// rather than two Points, since a `LineDistanceConstraint` references
  /// Lines directly and creates no Points of its own.
  void _paintLineDistanceDimension(Canvas canvas, LineDistanceConstraintDto c, Color color, Offset labelOffset) {
    final midA = _lineMidpointScreen(c.line1Id);
    final midB = _lineMidpointScreen(c.line2Id);
    if (midA == null || midB == null) return;
    final delta = midB - midA;
    final length = delta.distance;
    if (length < 1e-6) return;
    final normal = Offset(-delta.dy, delta.dx) / length;
    final offset = normal * _dimensionOffsetDistance(normal, labelOffset);

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;
    _drawExtensionLine(canvas, midA, midA + offset, dimPaint);
    _drawExtensionLine(canvas, midB, midB + offset, dimPaint);
    canvas.drawLine(midA + offset, midB + offset, dimPaint);
    _drawDimensionArrows(canvas, midA + offset, midB + offset, color);

    _drawDimensionLabel(canvas, (midA + offset + midB + offset) / 2, c.distance.toStringAsFixed(2), color, plainBlackText: true);
  }

  /// Vertical/Horizontal glyph: just a 'V'/'H' chip at the constrained
  /// Line's midpoint - there's no "value" to dimension, only the
  /// constraint's existence. On-device feedback: a constraint glyph (also
  /// used for Coincident's 'Coinc.' label) keeps the solid-color-fill
  /// styling (white text, no separate border needed since the fill itself
  /// carries the color) rather than [_drawDimensionLabel]'s numeric-
  /// dimension styling, so a bare relationship marker reads as a status
  /// indicator, distinct from an actual measured value.
  void _paintAxisIndicator(
    Canvas canvas,
    String pointAId,
    String pointBId,
    String label,
    Color color,
    Offset labelOffset,
  ) {
    final a = controller.points[pointAId];
    final b = controller.points[pointBId];
    if (a == null || b == null) return;
    final midpoint = (transform.sketchToScreen(a.x, a.y) + transform.sketchToScreen(b.x, b.y)) / 2;
    _drawDimensionLabel(canvas, midpoint + labelOffset, label, color);
  }

  /// Angle dimension: deliberately a numeric-only label rather than a
  /// literal arc sweep - the two constrained Lines have no shared vertex in
  /// general, so there's no single well-defined arc to draw. Placed at the
  /// midpoint between each Line's own midpoint, which stays stable and
  /// roughly "between" the two Lines regardless of their actual layout.
  void _paintAngleDimension(Canvas canvas, AngleConstraintDto c, Color color, Offset labelOffset) {
    final midpoint1 = _lineMidpointScreen(c.line1Id);
    final midpoint2 = _lineMidpointScreen(c.line2Id);
    if (midpoint1 == null || midpoint2 == null) return;
    final midpoint = (midpoint1 + midpoint2) / 2;
    _drawDimensionLabel(canvas, midpoint + labelOffset, '∠${c.angleDegrees.toStringAsFixed(1)}°', color, plainBlackText: true);
  }

  /// Generic two-Line glyph (Stage 23e): a small text chip at the midpoint
  /// between each Line's own midpoint - the value-less counterpart to
  /// [_paintAngleDimension]'s anchor, used for Parallel/Perpendicular/
  /// EqualLength/Collinear, which only need to show their own existence.
  /// Solid-color-fill styling - see [_paintAxisIndicator]'s own doc comment.
  void _paintTwoLineGlyph(
    Canvas canvas,
    String line1Id,
    String line2Id,
    String label,
    Color color,
    Offset labelOffset,
  ) {
    final midpoint1 = _lineMidpointScreen(line1Id);
    final midpoint2 = _lineMidpointScreen(line2Id);
    if (midpoint1 == null || midpoint2 == null) return;
    final midpoint = (midpoint1 + midpoint2) / 2;
    _drawDimensionLabel(canvas, midpoint + labelOffset, label, color);
  }

  /// Point-to-Line distance dimension (Stage 23e, [PointLineDistanceConstraintDto]):
  /// anchored between the Point and the Line's own midpoint, with the same
  /// numeric-label convention as [_paintDistanceDimension].
  void _paintPointLineDistanceDimension(
    Canvas canvas,
    PointLineDistanceConstraintDto c,
    Color color,
    Offset labelOffset,
  ) {
    final point = controller.points[c.pointId];
    final lineMid = _lineMidpointScreen(c.lineId);
    if (point == null || lineMid == null) return;
    final pointScreen = transform.sketchToScreen(point.x, point.y);
    final midpoint = (pointScreen + lineMid) / 2;
    _drawDimensionLabel(canvas, midpoint + labelOffset, c.distance.toStringAsFixed(2), color, plainBlackText: true);
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

  /// Marks taps already picked under [LineConstructionMethod.midpoint] or
  /// [CircleConstructionMethod.threePoint] that aren't real Points yet -
  /// same deepOrange as the chain-start/circle-center "in progress"
  /// markers, since these are the same kind of transient construction aid.
  void _paintInProgressConstructionPicks(Canvas canvas) {
    final markerPaint = Paint()..color = Colors.deepOrange;
    final anchorX = controller.midpointAnchorX;
    final anchorY = controller.midpointAnchorY;
    if (anchorX != null && anchorY != null) {
      canvas.drawCircle(transform.sketchToScreen(anchorX, anchorY), 6, markerPaint);
    }
    for (final pick in controller.threePointCirclePicksSoFar) {
      canvas.drawCircle(transform.sketchToScreen(pick.$1, pick.$2), 6, markerPaint);
    }
  }

  /// New work package item 5's discoverability cue: a hollow green ring
  /// around whichever Line midpoint the cursor is currently snapped to (see
  /// [SketchController.hoveredLineMidpoint]) - otherwise a Line's midpoint
  /// is an invisible snap target until the moment it's actually tapped.
  void _paintMidpointSnapIndicator(Canvas canvas) {
    final midpoint = controller.hoveredLineMidpoint;
    if (midpoint == null) return;
    final screenPos = transform.sketchToScreen(midpoint.$1, midpoint.$2);
    canvas.drawCircle(
      screenPos,
      _midpointSnapIndicatorRadius,
      Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  /// Stage 15 item 1: the dashed live preview of whatever the next tap
  /// would commit (see [SketchController.activeDrawGhost]) - drawn in the
  /// same in-progress deepOrange family as
  /// [_paintInProgressConstructionPicks]'s markers, since it's the same
  /// "not yet real" kind of feedback, just for the shape rather than a bare
  /// construction pick.
  static const Color _drawGhostColor = Colors.deepOrange;

  /// Stage 15 item 4's snap-candidate highlight color - cyan, distinct from
  /// every other highlight/marker color this painter already uses
  /// (purple selected, amber hover, green sketching cursor, deepOrange
  /// in-progress/ghost) and readable against both this painter's light
  /// background and a dark theme's canvas chrome around it.
  static const Color _snapCandidateColor = Colors.cyan;

  /// Stage 15 item 4: highlights whichever existing Point (if any) the
  /// cursor is currently snapped onto while placing a new entity (see
  /// [SketchController.snapCandidatePointId]) - a filled circle at 2x a
  /// plain Point's render radius, plus a concentric ring outside it, so an
  /// otherwise-invisible "this tap will reuse that Point" outcome is
  /// visible before the tap happens.
  void _paintSnapCandidateHighlight(Canvas canvas) {
    final pointId = controller.snapCandidatePointId;
    if (pointId == null) return;
    final point = controller.points[pointId];
    if (point == null) return;
    final screenPos = transform.sketchToScreen(point.x, point.y);
    const highlightRadius = _snapHighlightPointRadius * 2;
    canvas.drawCircle(screenPos, highlightRadius, Paint()..color = _snapCandidateColor.withValues(alpha: 0.35));
    canvas.drawCircle(
      screenPos,
      highlightRadius + 3,
      Paint()
        ..color = _snapCandidateColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  /// Prompt B item B4: a brief highlight at the just-placed Point once it's
  /// been auto-linked to an existing Point by a CoincidentConstraint (see
  /// [SketchController.autoCoincidentIndicatorPointId]) - same cyan ring
  /// styling as [_paintSnapCandidateHighlight] (this sketcher's existing
  /// snap-feedback visual), reused here as instructed rather than inventing
  /// a new one. Cleared by the controller on the next tap.
  void _paintAutoCoincidentIndicator(Canvas canvas) {
    final pointId = controller.autoCoincidentIndicatorPointId;
    if (pointId == null) return;
    final point = controller.points[pointId];
    if (point == null) return;
    final screenPos = transform.sketchToScreen(point.x, point.y);
    const highlightRadius = _snapHighlightPointRadius * 2;
    canvas.drawCircle(screenPos, highlightRadius, Paint()..color = _snapCandidateColor.withValues(alpha: 0.35));
    canvas.drawCircle(
      screenPos,
      highlightRadius + 3,
      Paint()
        ..color = _snapCandidateColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  void _paintActiveDrawGhost(Canvas canvas) {
    final ghost = controller.activeDrawGhost;
    if (ghost == null) return;
    final paint = Paint()
      ..color = _drawGhostColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    switch (ghost) {
      case LineGhost g:
        // Phase 6.1: same green used elsewhere for an active snap (e.g.
        // [isHoveringChainStart]) - signals the tap will land exactly
        // horizontal/vertical and auto-add that constraint.
        final snapPaint = controller.activeLineSnapAxis == null
            ? paint
            : (Paint()
              ..color = Colors.green
              ..strokeWidth = 1.5
              ..style = PaintingStyle.stroke);
        _drawDashedLine(
          canvas,
          transform.sketchToScreen(g.startX, g.startY),
          transform.sketchToScreen(g.endX, g.endY),
          snapPaint,
        );
      case CircleGhost g:
        final center = transform.sketchToScreen(g.centerX, g.centerY);
        final edge = transform.sketchToScreen(g.edgeX, g.edgeY);
        final radiusPixels = (edge - center).distance;
        _drawDashedCircle(canvas, center, radiusPixels, paint);
      case ArcGhost g:
        final center = transform.sketchToScreen(g.centerX, g.centerY);
        final start = transform.sketchToScreen(g.startX, g.startY);
        final radiusPixels = (start - center).distance;
        final rect = Rect.fromCircle(center: center, radius: radiusPixels);
        final (startAngle, sweepAngle) =
            _arcScreenAngles(g.centerX, g.centerY, g.startX, g.startY, g.endX, g.endY);
        _drawDashedArc(canvas, rect, startAngle, sweepAngle, paint);
      case RectGhost g:
        final corners = [g.corner0, g.corner1, g.corner2, g.corner3]
            .map((c) => transform.sketchToScreen(c.$1, c.$2))
            .toList();
        for (var i = 0; i < corners.length; i++) {
          _drawDashedLine(canvas, corners[i], corners[(i + 1) % corners.length], paint);
        }
      case PolygonGhost g:
        final vertices = g.vertices.map((v) => transform.sketchToScreen(v.$1, v.$2)).toList();
        for (var i = 0; i < vertices.length; i++) {
          _drawDashedLine(canvas, vertices[i], vertices[(i + 1) % vertices.length], paint);
        }
        if (g.showGuideCircles && vertices.length >= 3) {
          // Feedback round: the two circles every real regular polygon's
          // vertices/edge-midpoints always land on - a lighter guide paint
          // than the polygon outline itself so the two don't visually
          // compete, toggleable via [SketchController.togglePolygonGuideCircles].
          final guidePaint = Paint()
            ..color = paint.color.withValues(alpha: 0.35)
            ..style = PaintingStyle.stroke
            ..strokeWidth = paint.strokeWidth;
          final center = transform.sketchToScreen(g.centerX, g.centerY);
          final circumradiusPixels = (vertices[0] - center).distance;
          _drawDashedCircle(canvas, center, circumradiusPixels, guidePaint);
          final firstEdgeMidpoint = Offset(
            (vertices[0].dx + vertices[1].dx) / 2,
            (vertices[0].dy + vertices[1].dy) / 2,
          );
          final inradiusPixels = (firstEdgeMidpoint - center).distance;
          _drawDashedCircle(canvas, center, inradiusPixels, guidePaint);
        }
      case SlotGhost g:
        final center1 = transform.sketchToScreen(g.center1X, g.center1Y);
        final center2 = transform.sketchToScreen(g.center2X, g.center2Y);
        final a = transform.sketchToScreen(g.a.$1, g.a.$2);
        final b = transform.sketchToScreen(g.b.$1, g.b.$2);
        final c = transform.sketchToScreen(g.c.$1, g.c.$2);
        final d = transform.sketchToScreen(g.d.$1, g.d.$2);
        final radius1 = (a - center1).distance;
        final radius2 = (c - center2).distance;
        final (startAngle1, sweepAngle1) = _arcScreenAngles(g.center1X, g.center1Y, g.a.$1, g.a.$2, g.b.$1, g.b.$2);
        final (startAngle2, sweepAngle2) = _arcScreenAngles(g.center2X, g.center2Y, g.c.$1, g.c.$2, g.d.$1, g.d.$2);
        _drawDashedArc(
          canvas,
          Rect.fromCircle(center: center1, radius: radius1),
          startAngle1,
          sweepAngle1,
          paint,
        );
        _drawDashedLine(canvas, b, c, paint);
        _drawDashedArc(
          canvas,
          Rect.fromCircle(center: center2, radius: radius2),
          startAngle2,
          sweepAngle2,
          paint,
        );
        _drawDashedLine(canvas, d, a, paint);
      case EllipseGhost g:
        final center = transform.sketchToScreen(g.centerX, g.centerY);
        final major = transform.sketchToScreen(g.majorX, g.majorY);
        final majorRadiusPixels = (major - center).distance;
        final minorRadiusPixels = g.minorRadius * transform.pixelsPerUnit;
        final rotation = math.atan2(g.majorY - g.centerY, g.majorX - g.centerX);
        final ovalRect = Rect.fromCenter(
          center: Offset.zero,
          width: majorRadiusPixels * 2,
          height: minorRadiusPixels * 2,
        );
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(-rotation);
        _drawDashedOval(canvas, ovalRect, paint);
        canvas.restore();
      case SplineGhost g:
        // See SplineGhost's own doc comment / catmullRomPolyline's own doc
        // comment: a smooth approximation of the eventual curve, not the
        // real backend-computed one.
        final sketchPoints = [...g.throughPoints, g.cursor];
        final smoothed = catmullRomPolyline(sketchPoints);
        final screenPoints = [for (final p in smoothed) transform.sketchToScreen(p.$1, p.$2)];
        for (var i = 0; i < screenPoints.length - 1; i++) {
          _drawDashedLine(canvas, screenPoints[i], screenPoints[i + 1], paint);
        }
    }
  }

  /// A soft green fill over every one of the Sketch's closed profile loops
  /// (if any), so a profile that's ready to Extrude reads as a "solid"
  /// before the user even opens the context menu.
  /// [SketchController.closedProfileFills] is empty whenever there's no
  /// usable profile at all, so this is a no-op for every sketch that
  /// doesn't have one.
  ///
  /// Bug fix: this used to only ever handle a single loop with no holes
  /// (`controller.closedProfilePointIds`, a plain `List<String>?`), so a
  /// sketch with a MultiProfile (C2, 2+ disjoint outer loops) or a hole
  /// (C1) never got any area filled at all. Now every outer loop in
  /// [SketchController.closedProfileFills] is filled independently, each
  /// with its own holes (`ProfileLoopDto.innerLoops`) punched out via an
  /// even-odd sub-path - the same convention `Path.combine` and most 2D
  /// vector tools use for "outer boundary plus holes".
  void _paintClosedProfileFill(Canvas canvas) {
    for (final loop in controller.closedProfileFills) {
      final path = _profileLoopPath(loop);
      if (path == null) continue;
      canvas.drawPath(path, Paint()..color = const Color(0xFF4CAF82).withValues(alpha: 0.15));
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF4CAF82).withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  /// One outer [loop]'s fill path, with a hole punched out for each of its
  /// `innerLoops` via [PathFillType.evenOdd] - returns null if the loop's
  /// own boundary can't be built (see [_addLoopBoundary]). A hole that
  /// can't be built is simply skipped (still shows the outer fill, just
  /// without that one hole) rather than voiding the whole loop's fill.
  Path? _profileLoopPath(ProfileLoopDto loop) {
    final path = Path()..fillType = PathFillType.evenOdd;
    if (!_addLoopBoundary(path, loop)) return null;
    for (final inner in loop.innerLoops) {
      _addLoopBoundary(path, inner);
    }
    return path;
  }

  /// Adds [loop]'s boundary to [path] as a closed sub-path, and reports
  /// whether it could: false if any of the loop's own Points are missing
  /// from [SketchController.points] (a stale/in-flight profile response
  /// racing a local edit).
  ///
  /// Bug fix: a standalone Circle profile is reported as exactly 2 Points
  /// (center, radius point - see `app.sketch.profile._circle_profile`),
  /// not an ordered polygon boundary - treating those 2 points as a
  /// (degenerate, invisible) 2-point polygon silently drew nothing for
  /// every Circle profile, both as an outer loop and as a hole. The same
  /// 2-vs-3+ point count `SketchController._refreshProfile`'s filter uses
  /// tells the two cases apart here: a real polygon loop always has 3+
  /// points, so an exact 2 is unambiguously a Circle - unless it's
  /// actually an Ellipse profile (also reported as exactly 2 Points,
  /// center + major-axis - see `app.sketch.profile._ellipse_profile`),
  /// checked first via [loop]'s own entity id so a plain circular fill
  /// isn't drawn in place of the real (possibly non-circular, rotated)
  /// ellipse shape.
  ///
  /// Known v1 gap: a Text-contour loop (`loop.pointIds` empty, `line_ids`
  /// holding just the owning Text entity's id - see
  /// `app.sketch.profile._text_profile`) has no packed-point convention
  /// this function recognizes at all, so it safely returns false (no
  /// crash, simply no green "ready to extrude" overlay drawn) for any
  /// profile that includes one - Text already renders its own filled
  /// glyph shape directly (see the dedicated Text loop in [paint]), which
  /// covers the most important "this is solid" visual signal; the
  /// additional green overlay other extrudable profiles get is deferred.
  bool _addLoopBoundary(Path path, ProfileLoopDto loop) {
    final points = <Offset>[];
    for (final id in loop.pointIds) {
      final point = controller.points[id];
      if (point == null) return false;
      points.add(transform.sketchToScreen(point.x, point.y));
    }

    final ellipseId = loop.lineIds.length == 1 ? loop.lineIds[0] : null;
    final ellipse = ellipseId == null ? null : controller.ellipses[ellipseId];
    if (ellipse != null && points.length == 2) {
      final center = points[0];
      final major = points[1];
      final majorRadiusPixels = (major - center).distance;
      final centerPoint = controller.points[ellipse.centerPointId]!;
      final minorPoint = controller.points[ellipse.minorPointId]!;
      final minorRadiusPixels = (transform.sketchToScreen(minorPoint.x, minorPoint.y) -
              transform.sketchToScreen(centerPoint.x, centerPoint.y))
          .distance;
      final rotation = math.atan2(
        controller.points[ellipse.majorPointId]!.y - centerPoint.y,
        controller.points[ellipse.majorPointId]!.x - centerPoint.x,
      );
      final ovalPath = Path()
        ..addOval(Rect.fromCenter(center: Offset.zero, width: majorRadiusPixels * 2, height: minorRadiusPixels * 2));
      final matrix = Matrix4.translationValues(center.dx, center.dy, 0)..rotateZ(-rotation);
      path.addPath(ovalPath, Offset.zero, matrix4: matrix.storage);
      return true;
    }

    final hasArc = loop.lineIds.any((id) => controller.arcs.containsKey(id));
    final hasSpline = loop.lineIds.any((id) => controller.splines.containsKey(id));
    if (!hasArc && !hasSpline) {
      if (points.length == 2) {
        final center = points[0];
        final radius = (points[1] - center).distance;
        path.addOval(Rect.fromCircle(center: center, radius: radius));
        return true;
      }
      if (points.length < 3) return false;
      path.addPolygon(points, true);
      return true;
    }

    // A Line/Arc/Spline-mixed loop (e.g. a rounded-corner rectangle, or a
    // loop with one curved edge) - at least 2 points (two Arcs alone can
    // close a full circle), each hop built as its own straight or curved
    // segment rather than blindly polygon-connecting every point, mirroring
    // app.document.extrude.wire_for_profile's identical straight-vs-curved-
    // per-hop distinction on the backend. A Spline hop's own interior
    // through-points never appear in [loop.pointIds] (only its first/last -
    // same packed convention as an Arc's or Ellipse's endpoints), so its
    // full segment list is walked from the SketchSplineView itself, in
    // through-point order or reversed to match whichever end
    // [loop.pointIds] visits first.
    if (points.length < 2) return false;
    path.moveTo(points[0].dx, points[0].dy);
    final n = points.length;
    for (var i = 0; i < n; i++) {
      final next = points[(i + 1) % n];
      final entityId = i < loop.lineIds.length ? loop.lineIds[i] : null;
      final spline = entityId == null ? null : controller.splines[entityId];
      if (spline != null) {
        var segments = spline.segments();
        if (loop.pointIds[i] == spline.throughPointIds.last) {
          segments = [for (final s in segments.reversed) (s.$4, s.$3, s.$2, s.$1)];
        }
        for (final segment in segments) {
          final c1 = controller.points[segment.$2];
          final c2 = controller.points[segment.$3];
          final end = controller.points[segment.$4];
          if (c1 == null || c2 == null || end == null) return false;
          final c1Screen = transform.sketchToScreen(c1.x, c1.y);
          final c2Screen = transform.sketchToScreen(c2.x, c2.y);
          final endScreen = transform.sketchToScreen(end.x, end.y);
          path.cubicTo(c1Screen.dx, c1Screen.dy, c2Screen.dx, c2Screen.dy, endScreen.dx, endScreen.dy);
        }
        continue;
      }
      final arc = entityId == null ? null : controller.arcs[entityId];
      final arcCenter = arc == null ? null : controller.points[arc.centerPointId];
      final arcStart = arc == null ? null : controller.points[arc.startPointId];
      final arcEnd = arc == null ? null : controller.points[arc.endPointId];
      if (arc == null || arcCenter == null || arcStart == null || arcEnd == null) {
        path.lineTo(next.dx, next.dy);
        continue;
      }
      final centerScreen = transform.sketchToScreen(arcCenter.x, arcCenter.y);
      final radiusPixels = (transform.sketchToScreen(arcStart.x, arcStart.y) - centerScreen).distance;
      final rect = Rect.fromCircle(center: centerScreen, radius: radiusPixels);
      final (startAngle, sweepAngle) = _arcScreenAngles(
        arcCenter.x,
        arcCenter.y,
        arcStart.x,
        arcStart.y,
        arcEnd.x,
        arcEnd.y,
      );
      // loop.pointIds[i] may be the Arc's own start or end Point,
      // depending on which direction profile.py's graph walk traced this
      // loop in - trace the identical physical arc backward (from the end
      // angle, by the negative sweep) when it's the latter, so the fill
      // always follows the real curve regardless of trace direction (same
      // resolution as extrude.py's wire_for_profile).
      if (loop.pointIds[i] == arc.startPointId) {
        path.arcTo(rect, startAngle, sweepAngle, false);
      } else {
        path.arcTo(rect, startAngle + sweepAngle, -sweepAngle, false);
      }
    }
    path.close();
    return true;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = canvasColor.withValues(alpha: canvasOpacity));

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

    // Sketcher-roadmap Phase 4.3 v1: the reference body's own pick targets
    // for body-vertex dimensioning (see SketchController.
    // pickReferenceGhostVertex) - small, solid dots (distinct from the
    // dashed wireframe above) so they read as tappable rather than just
    // more outline. Only in SketchMode.dimension - a select-mode/draw-mode
    // canvas has nothing to do with them, and drawing them unconditionally
    // would just be visual clutter on every other body corner.
    if (!referenceBodyHidden &&
        referenceGhostVertices.isNotEmpty &&
        controller.mode == SketchMode.dimension) {
      final vertexPaint = Paint()..color = _referenceGhostColor;
      for (final (_, _, x, y) in referenceGhostVertices) {
        canvas.drawCircle(transform.sketchToScreen(x, y), 3.5, vertexPaint);
      }
    }

    _paintClosedProfileFill(canvas);

    final hovered = controller.hoveredEntity(transform.pixelsPerUnit);
    final selectionSet = controller.selectionSet;
    bool isSelected(SelectionKind kind, String id) =>
        selectionSet.any((s) => s.kind == kind && s.id == id);

    for (final line in controller.lines.values) {
      final start = controller.points[line.startPointId];
      final end = controller.points[line.endPointId];
      if (start == null || end == null) continue;
      final lineIsGrabbed = controller.draggingLineId == line.id;
      final lineIsSelected = isSelected(SelectionKind.line, line.id);
      final isHovered = hovered?.kind == SelectionKind.line && hovered!.id == line.id;
      // Phase 3: per-entity structural DOF preview (dof_analysis.dart) plus
      // the two backend-derived red sources and the whole-sketch green
      // override (see SketchController.isFullyConstrained/
      // backendFlaggedOverConstrainedPointIds/degenerateConstraintPointIds'
      // doc comments for why [rigidity] alone can't produce either) -
      // superseding Prompt B item B5's sketch-wide-only black/grey signal
      // now that per-entity colouring exists. Over-constrained takes
      // priority over construction (a warning that matters regardless of
      // whether the Line is construction geometry), fully-constrained does
      // not (construction's own color stays the stronger signal there).
      final lineIsOverConstrained =
          controller.rigidity.isSegmentOverConstrained(line.startPointId, line.endPointId) ||
              controller.isPointForcedOverConstrained(line.startPointId) ||
              controller.isPointForcedOverConstrained(line.endPointId);
      final lineIsFullyConstrained = controller.isFullyConstrained ||
          controller.rigidity.isSegmentFullyConstrained(line.startPointId, line.endPointId);
      final linePaint = Paint()
        ..color = lineIsGrabbed
            ? _grabbedColor
            : lineIsSelected
                ? _selectedColor
                : isHovered
                    ? _hoverColor
                    : lineIsOverConstrained
                        ? _overConstrainedColor
                        : line.construction
                            ? _constructionColor
                            : lineIsFullyConstrained
                                ? _fullyConstrainedColor
                                : _unconstrainedColor
        ..strokeWidth = lineIsGrabbed || lineIsSelected || isHovered ? _lineStrokeWidthEmphasis : _lineStrokeWidth;
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
      // Phase 3: same per-entity DOF preview (plus the same backend-derived
      // red/whole-sketch-green sources) as the Line loop above, treating a
      // Circle's center/radius Points as its defining pair.
      final circleIsOverConstrained =
          controller.rigidity.isSegmentOverConstrained(circle.centerPointId, circle.radiusPointId) ||
              controller.isPointForcedOverConstrained(circle.centerPointId) ||
              controller.isPointForcedOverConstrained(circle.radiusPointId);
      final circleIsFullyConstrained = controller.isFullyConstrained ||
          controller.rigidity.isSegmentFullyConstrained(circle.centerPointId, circle.radiusPointId);
      final circlePaint = Paint()
        ..color = circleIsSelected
            ? _selectedColor
            : isHovered
                ? _hoverColor
                : circleIsOverConstrained
                    ? _overConstrainedColor
                    : circle.construction
                        ? _constructionColor
                        : circleIsFullyConstrained
                            ? _fullyConstrainedColor
                            : _unconstrainedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = circleIsSelected || isHovered ? _lineStrokeWidthEmphasis : _lineStrokeWidth;
      final centerScreen = transform.sketchToScreen(center.x, center.y);
      final radiusPixels = radius * transform.pixelsPerUnit;
      if (circle.construction) {
        _drawDashedCircle(canvas, centerScreen, radiusPixels, circlePaint);
      } else {
        canvas.drawCircle(centerScreen, radiusPixels, circlePaint);
      }
    }

    for (final arc in controller.arcs.values) {
      final center = controller.points[arc.centerPointId];
      final start = controller.points[arc.startPointId];
      final end = controller.points[arc.endPointId];
      if (center == null || start == null || end == null) continue;
      final radius = math.sqrt(math.pow(start.x - center.x, 2) + math.pow(start.y - center.y, 2));
      final arcIsSelected = isSelected(SelectionKind.arc, arc.id);
      final isHovered = hovered?.kind == SelectionKind.arc && hovered!.id == arc.id;
      // Same per-entity DOF preview as Circle above, treating an Arc's
      // center/start pair and center/end pair as its two defining
      // segments - over-constrained if either is, fully constrained only
      // if both are (the two DistanceConstraints are independent - see
      // the backend's `app.sketch.models.Arc` docstring).
      final arcIsOverConstrained =
          controller.rigidity.isSegmentOverConstrained(arc.centerPointId, arc.startPointId) ||
              controller.rigidity.isSegmentOverConstrained(arc.centerPointId, arc.endPointId) ||
              controller.isPointForcedOverConstrained(arc.centerPointId) ||
              controller.isPointForcedOverConstrained(arc.startPointId) ||
              controller.isPointForcedOverConstrained(arc.endPointId);
      final arcIsFullyConstrained = controller.isFullyConstrained ||
          (controller.rigidity.isSegmentFullyConstrained(arc.centerPointId, arc.startPointId) &&
              controller.rigidity.isSegmentFullyConstrained(arc.centerPointId, arc.endPointId));
      final arcPaint = Paint()
        ..color = arcIsSelected
            ? _selectedColor
            : isHovered
                ? _hoverColor
                : arcIsOverConstrained
                    ? _overConstrainedColor
                    : arc.construction
                        ? _constructionColor
                        : arcIsFullyConstrained
                            ? _fullyConstrainedColor
                            : _unconstrainedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = arcIsSelected || isHovered ? _lineStrokeWidthEmphasis : _lineStrokeWidth;
      final centerScreen = transform.sketchToScreen(center.x, center.y);
      final radiusPixels = radius * transform.pixelsPerUnit;
      final rect = Rect.fromCircle(center: centerScreen, radius: radiusPixels);
      final (startAngle, sweepAngle) =
          _arcScreenAngles(center.x, center.y, start.x, start.y, end.x, end.y);
      if (arc.construction) {
        _drawDashedArc(canvas, rect, startAngle, sweepAngle, arcPaint);
      } else {
        canvas.drawArc(rect, startAngle, sweepAngle, false, arcPaint);
      }
    }

    for (final ellipse in controller.ellipses.values) {
      final center = controller.points[ellipse.centerPointId];
      final major = controller.points[ellipse.majorPointId];
      if (center == null || major == null) continue;
      final minor = controller.points[ellipse.minorPointId];
      if (minor == null) continue;
      final majorRadius = math.sqrt(math.pow(major.x - center.x, 2) + math.pow(major.y - center.y, 2));
      final minorRadius = math.sqrt(math.pow(minor.x - center.x, 2) + math.pow(minor.y - center.y, 2));
      final rotation = math.atan2(major.y - center.y, major.x - center.x);
      final ellipseIsSelected = isSelected(SelectionKind.ellipse, ellipse.id);
      final isHovered = hovered?.kind == SelectionKind.ellipse && hovered!.id == ellipse.id;
      // Same per-entity DOF preview as Circle above, now checking both the
      // major-axis AND minor-axis segments (feedback round: the minor axis
      // is real, solver-tracked geometry too, see the Ellipse class's
      // docstring - it's no longer excluded from this coloring).
      final ellipseIsOverConstrained =
          controller.rigidity.isSegmentOverConstrained(ellipse.centerPointId, ellipse.majorPointId) ||
              controller.rigidity.isSegmentOverConstrained(ellipse.centerPointId, ellipse.minorPointId) ||
              controller.isPointForcedOverConstrained(ellipse.centerPointId) ||
              controller.isPointForcedOverConstrained(ellipse.majorPointId) ||
              controller.isPointForcedOverConstrained(ellipse.minorPointId);
      final ellipseIsFullyConstrained = controller.isFullyConstrained ||
          (controller.rigidity.isSegmentFullyConstrained(ellipse.centerPointId, ellipse.majorPointId) &&
              controller.rigidity.isSegmentFullyConstrained(ellipse.centerPointId, ellipse.minorPointId));
      final ellipsePaint = Paint()
        ..color = ellipseIsSelected
            ? _selectedColor
            : isHovered
                ? _hoverColor
                : ellipseIsOverConstrained
                    ? _overConstrainedColor
                    : ellipse.construction
                        ? _constructionColor
                        : ellipseIsFullyConstrained
                            ? _fullyConstrainedColor
                            : _unconstrainedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = ellipseIsSelected || isHovered ? _lineStrokeWidthEmphasis : _lineStrokeWidth;
      final centerScreen = transform.sketchToScreen(center.x, center.y);
      final majorRadiusPixels = majorRadius * transform.pixelsPerUnit;
      final minorRadiusPixels = minorRadius * transform.pixelsPerUnit;
      final ovalRect = Rect.fromCenter(
        center: Offset.zero,
        width: majorRadiusPixels * 2,
        height: minorRadiusPixels * 2,
      );
      canvas.save();
      canvas.translate(centerScreen.dx, centerScreen.dy);
      // Undoes ViewTransform.sketchToScreen's Y-flip, same reasoning as
      // [_arcScreenAngles]'s own negation.
      canvas.rotate(-rotation);
      if (ellipse.construction) {
        _drawDashedOval(canvas, ovalRect, ellipsePaint);
      } else {
        canvas.drawOval(ovalRect, ellipsePaint);
      }
      canvas.restore();
    }

    for (final spline in controller.splines.values) {
      final segments = spline.segments();
      final screenPoints = <Offset>[];
      for (final segment in segments) {
        final p0 = controller.points[segment.$1];
        final p1 = controller.points[segment.$2];
        final p2 = controller.points[segment.$3];
        final p3 = controller.points[segment.$4];
        if (p0 == null || p1 == null || p2 == null || p3 == null) {
          screenPoints.clear();
          break;
        }
        if (screenPoints.isEmpty) screenPoints.add(transform.sketchToScreen(p0.x, p0.y));
        screenPoints.add(transform.sketchToScreen(p1.x, p1.y));
        screenPoints.add(transform.sketchToScreen(p2.x, p2.y));
        screenPoints.add(transform.sketchToScreen(p3.x, p3.y));
      }
      if (screenPoints.isEmpty) continue;

      final splineIsSelected = isSelected(SelectionKind.spline, spline.id);
      final isHovered = hovered?.kind == SelectionKind.spline && hovered!.id == spline.id;
      // Same per-entity DOF preview as the other curved entities above,
      // generalized from a single defining pair to every consecutive
      // through-point pair - over-constrained if any segment is, fully
      // constrained only if every segment is (mirrors Arc's own
      // "both segments must agree" reasoning, generalized to N-1
      // segments instead of a fixed 2).
      var splineIsOverConstrained = false;
      var splineIsFullyConstrained = true;
      for (var i = 0; i < spline.throughPointIds.length; i++) {
        if (controller.isPointForcedOverConstrained(spline.throughPointIds[i])) {
          splineIsOverConstrained = true;
        }
      }
      for (var i = 0; i < spline.throughPointIds.length - 1; i++) {
        final a = spline.throughPointIds[i];
        final b = spline.throughPointIds[i + 1];
        if (controller.rigidity.isSegmentOverConstrained(a, b)) splineIsOverConstrained = true;
        if (!controller.rigidity.isSegmentFullyConstrained(a, b)) splineIsFullyConstrained = false;
      }
      splineIsFullyConstrained = controller.isFullyConstrained || splineIsFullyConstrained;

      final splinePaint = Paint()
        ..color = splineIsSelected
            ? _selectedColor
            : isHovered
                ? _hoverColor
                : splineIsOverConstrained
                    ? _overConstrainedColor
                    : spline.construction
                        ? _constructionColor
                        : splineIsFullyConstrained
                            ? _fullyConstrainedColor
                            : _unconstrainedColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = splineIsSelected || isHovered ? _lineStrokeWidthEmphasis : _lineStrokeWidth;

      final path = Path()..moveTo(screenPoints[0].dx, screenPoints[0].dy);
      for (var i = 1; i < screenPoints.length; i += 3) {
        path.cubicTo(
          screenPoints[i].dx,
          screenPoints[i].dy,
          screenPoints[i + 1].dx,
          screenPoints[i + 1].dy,
          screenPoints[i + 2].dx,
          screenPoints[i + 2].dy,
        );
      }
      if (spline.construction) {
        _drawDashedPath(canvas, path, splinePaint);
      } else {
        canvas.drawPath(path, splinePaint);
      }
    }

    for (final text in controller.texts.values) {
      final contours = controller.textAbsoluteContours(text);
      if (contours == null) continue;

      final path = Path()..fillType = PathFillType.evenOdd;
      for (final contour in contours) {
        final outerScreen = [for (final p in contour.outer) transform.sketchToScreen(p.$1, p.$2)];
        if (outerScreen.isEmpty) continue;
        path.moveTo(outerScreen[0].dx, outerScreen[0].dy);
        for (var i = 1; i < outerScreen.length; i++) {
          path.lineTo(outerScreen[i].dx, outerScreen[i].dy);
        }
        path.close();
        for (final hole in contour.holes) {
          final holeScreen = [for (final p in hole) transform.sketchToScreen(p.$1, p.$2)];
          if (holeScreen.isEmpty) continue;
          path.moveTo(holeScreen[0].dx, holeScreen[0].dy);
          for (var i = 1; i < holeScreen.length; i++) {
            path.lineTo(holeScreen[i].dx, holeScreen[i].dy);
          }
          path.close();
        }
      }

      final textIsSelected = isSelected(SelectionKind.text, text.id);
      final isHovered = hovered?.kind == SelectionKind.text && hovered!.id == text.id;
      // Text's only defining Point is its anchor (see SketchTextView's own
      // doc comment - glyph geometry is never decomposed into Points), so
      // its DOF preview is the same plain single-Point check the origin's
      // own marker below uses, rather than the per-segment checks every
      // other curved entity above needs.
      final textIsOverConstrained = controller.isPointForcedOverConstrained(text.anchorPointId);
      final textIsFullyConstrained =
          controller.isFullyConstrained || controller.rigidity.isPointFullyConstrained(text.anchorPointId);
      final textColor = textIsSelected
          ? _selectedColor
          : isHovered
              ? _hoverColor
              : textIsOverConstrained
                  ? _overConstrainedColor
                  : text.construction
                      ? _constructionColor
                      : textIsFullyConstrained
                          ? _fullyConstrainedColor
                          : _unconstrainedColor;

      // Unlike every other entity here, Text is rendered as a filled
      // shape (a translucent preview of the material that will actually
      // be cut/embossed - see the profile-fill rendering above, the only
      // other filled rendering in this file) rather than a bare outline -
      // a stroke-only "T" would be much harder to read as a solid letter.
      // Dashing (this file's usual construction-geometry cue) has no
      // meaningful analogue for a fill, so construction status here is
      // signalled by color alone, same as every other entity's own color
      // ternary above.
      canvas.drawPath(path, Paint()..color = textColor.withValues(alpha: 0.55)..style = PaintingStyle.fill);
      canvas.drawPath(
        path,
        Paint()
          ..color = textColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = textIsSelected || isHovered ? _lineStrokeWidthEmphasis : _lineStrokeWidth,
      );
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
          ..strokeWidth = 1.5;
        final halfSize = isSnappingToOrigin ? _originHalfSizeSnapping : _originHalfSize;
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
    final arcCenterId = controller.arcCenterPointId;
    final arcStartId = controller.arcStartPointId;
    final polygonCenterId = controller.polygonCenterPointId;
    final slotCenter1Id = controller.slotCenter1PointId;
    final slotCenter2Id = controller.slotCenter2PointId;
    final ellipseCenterId = controller.ellipseCenterPointId;
    final ellipseMajorId = controller.ellipseMajorPointId;
    final splineThroughIds = controller.splineInProgress ? controller.splineThroughPointIds : const <String>[];
    for (final point in controller.points.values) {
      if (point.id == originId) continue; // Drawn separately above, as a square marker.
      final isChainStart = controller.chainInProgress && point.id == chainFirstId;
      final isCircleCenter = controller.circleInProgress && point.id == circleCenterId;
      final isArcAnchor = controller.arcInProgress && (point.id == arcCenterId || point.id == arcStartId);
      final isPolygonCenter = controller.polygonInProgress && point.id == polygonCenterId;
      final isSlotAnchor =
          controller.slotInProgress && (point.id == slotCenter1Id || point.id == slotCenter2Id);
      final isEllipseAnchor = controller.ellipseInProgress &&
          (point.id == ellipseCenterId || point.id == ellipseMajorId);
      final isSplineThroughPoint = splineThroughIds.contains(point.id);
      final pointIsGrabbed = controller.draggingPointId == point.id;
      final pointIsSelected = isSelected(SelectionKind.point, point.id);
      final isHovered = hovered?.kind == SelectionKind.point && hovered!.id == point.id;
      final screenPos = transform.sketchToScreen(point.x, point.y);
      Color color = _unconstrainedColor;
      double radius = _pointRadius;
      if (pointIsGrabbed) {
        color = _grabbedColor;
        radius = _pointRadiusSelected;
      } else if (isChainStart) {
        color = isSnapping ? Colors.green : Colors.deepOrange;
        radius = isSnapping ? _pointRadiusSnapping : _pointRadiusEmphasis;
      } else if (isCircleCenter ||
          isArcAnchor ||
          isPolygonCenter ||
          isSlotAnchor ||
          isEllipseAnchor ||
          isSplineThroughPoint) {
        color = Colors.deepOrange;
        radius = _pointRadiusEmphasis;
      } else if (controller.isPointForcedOverConstrained(point.id)) {
        // Phase 3 (3.2): flags exactly the Points [beginPointDrag]/
        // [beginLineDrag] refuse to grab - see those methods' own doc
        // comments in sketch_controller.dart.
        color = _overConstrainedColor;
        radius = _pointRadiusEmphasis;
      } else if (pointIsSelected) {
        color = _selectedColor;
        radius = _pointRadiusSelected;
      } else if (isHovered) {
        color = _hoverColor;
        radius = _pointRadiusEmphasis;
      } else if (controller.isFullyConstrained || controller.rigidity.isPointFullyConstrained(point.id)) {
        // Phase 3 (3.1): same whole-sketch-or-per-cluster verdict as the
        // Line/Circle loops above, applied to a standalone Point too.
        color = _fullyConstrainedColor;
      }
      canvas.drawCircle(screenPos, radius, Paint()..color = color);
    }

    if (labelsVisible) _paintDimensionOverlays(canvas);
    _paintGhosts(canvas);
    _paintInProgressConstructionPicks(canvas);
    _paintMidpointSnapIndicator(canvas);
    _paintSnapCandidateHighlight(canvas);
    _paintAutoCoincidentIndicator(canvas);
    _paintActiveDrawGhost(canvas);

    // Bug-fix round: the cursor's sketch-space position is never itself
    // touched by panning/zooming (see SketchController's class doc
    // comment), so it can end up off-canvas once the view has panned/
    // zoomed away from it - rather than force it back on-screen (which is
    // what used to cause the reported "jumps to the middle" glitch), it
    // simply stops rendering until the next cursor-moving interaction
    // (see SketchController.isCursorVisible/moveCursorRelative).
    //
    // Also hidden entirely while something is grabbed via drag mode (see
    // SketchController.isEntityGrabbed) - the grabbed entity's own
    // highlight (see _grabbedColor above) *is* the cursor at that point,
    // showing both would be redundant/confusing.
    if (controller.isCursorVisible(size, transform) && !controller.isEntityGrabbed) {
      final cursorScreen = transform.sketchToScreen(controller.cursorX, controller.cursorY);
      final crosshairPaint = Paint()
        ..color = controller.mode == SketchMode.draw ? _sketchingCursorColor : _selectCursorColor
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
  }

  @override
  bool shouldRepaint(covariant _SketchPainter oldDelegate) => true;
}
