import 'dart:async';

import 'selection_hit_test.dart' show SelectionEntityRef;

/// C4 (#12): what hovering a tree row lights in the viewport, separate from the Select Other override ([PartViewport.highlightOverride] dims
/// everything else; this only lights). [instanceKeys] are placed instances (joined full `occurrencePath`s), each lit whole; [entities] are
/// what a live feature row made (bodies, surfaces, curves). Equal when both sets are equal, so a row that reports the same hover twice
/// changes nothing.
class ViewportTreeHover {
  final Set<String> instanceKeys;
  final Set<SelectionEntityRef> entities;
  const ViewportTreeHover({this.instanceKeys = const {}, this.entities = const {}});

  bool get isEmpty => instanceKeys.isEmpty && entities.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ViewportTreeHover && _setEq(instanceKeys, other.instanceKeys) && _setEq(entities, other.entities);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(instanceKeys), Object.hashAllUnordered(entities));

  static bool _setEq<T>(Set<T> a, Set<T> b) => identical(a, b) || (a.length == b.length && a.containsAll(b));
}

/// C4 (#12): passes a value on at most once per [window], the newest one last, so a pointer moving over the viewport does not rebuild the
/// tree on every frame. The first value goes through at once; later ones wait for the window to end (only the newest is kept), and a value
/// equal to the one last passed on is dropped.
class HoverThrottle<T> {
  HoverThrottle(this.sink, {this.window = const Duration(milliseconds: 60)});

  final void Function(T value) sink;
  final Duration window;

  Timer? _timer;
  bool _hasLast = false;
  T? _last;
  bool _hasPending = false;
  T? _pending;

  void push(T value) {
    if (_timer == null) {
      _emit(value);
      _timer = Timer(window, _windowEnded);
    } else {
      _hasPending = true;
      _pending = value;
    }
  }

  void _windowEnded() {
    _timer = null;
    if (!_hasPending) return;
    final value = _pending as T;
    _hasPending = false;
    _pending = null;
    if (!_hasLast || _last != value) {
      _emit(value);
      _timer = Timer(window, _windowEnded);
    }
  }

  void _emit(T value) {
    if (_hasLast && _last == value) return;
    _hasLast = true;
    _last = value;
    sink(value);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _hasPending = false;
  }
}
