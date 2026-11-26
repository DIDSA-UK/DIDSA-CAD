import 'dart:async';

import '../api/document_api_client.dart' show AssemblyOccurrenceInstanceDto, BodyMeshDto;
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

/// C4 (#12): [keys] without the placed instances [instances] say are hidden. A hidden part is not drawn, so a hover must not light a ghost
/// of it; an instance the list does not know stays in (it lights nothing either, there is nothing to find). The list the viewport is given
/// marks every descendant of a hidden sub-assembly hidden itself (the host's display list does), so no ancestor check is needed here.
Set<String> shownInstanceKeys(Set<String> keys, List<AssemblyOccurrenceInstanceDto> instances) {
  final hidden = {
    for (final i in instances)
      if (i.hidden) i.occurrencePath.join('/'),
  };
  return hidden.isEmpty ? keys : keys.difference(hidden);
}

/// C10 (C4-3): whether the bodies a tree hover lights changed between two lists of the viewport's bodies. The host hands over a fresh list
/// on every rebuild, holding the same body objects: only a body the hover's entities name that is another object (or is gone, or came) counts.
/// A hover of placed instances alone lights no body of this list.
bool treeHoverBodiesChanged(ViewportTreeHover hover, List<BodyMeshDto> before, List<BodyMeshDto> after) {
  if (identical(before, after) || hover.entities.isEmpty) return false;
  BodyMeshDto? find(List<BodyMeshDto> list, String id) {
    for (final b in list) {
      if (b.bodyId == id) return b;
    }
    return null;
  }

  for (final e in hover.entities) {
    if (e.bodyId.isEmpty) continue;
    if (!identical(find(before, e.bodyId), find(after, e.bodyId))) return true;
  }
  return false;
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

  bool _disposed = false;

  void push(T value) {
    if (_disposed) return;
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
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _hasPending = false;
  }
}
