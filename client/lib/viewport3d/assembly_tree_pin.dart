import 'dart:math' as math;

/// B5 (`docs/assembly-tree-overhaul-scope.md` 10.6, section 5 "Phone, deep trees"): which ancestors the phone sheet pins to the top of its
/// list while it scrolls, as in a contact list's section headers.
///
/// Pure arithmetic over the rows' depths (the rows are in the visible-rows order, so a row's subtree is the rows after it that are deeper).
/// A row is *pinned* when it has listed children, its natural place has scrolled above the slot it would stack at, and some of its subtree
/// still shows below the stack. Its slot is its level (the number of ancestors it has) times the row height, so the pinned rows are always
/// one unbroken chain: every ancestor of a pinned row is pinned too.
class AssemblyTreePinIndex {
  /// [depths] are the listed rows' depths in order (the root row, when it is listed, included: only the differences matter).
  AssemblyTreePinIndex(List<int> depths)
      : _level = List<int>.filled(depths.length, 0),
        _parent = List<int>.filled(depths.length, -1),
        _end = List<int>.filled(depths.length, 0) {
    final stack = <int>[]; // indices of the open ancestors, shallowest first
    for (var i = 0; i < depths.length; i++) {
      while (stack.isNotEmpty && depths[stack.last] >= depths[i]) {
        _end[stack.removeLast()] = i;
      }
      _parent[i] = stack.isEmpty ? -1 : stack.last;
      _level[i] = stack.length;
      stack.add(i);
    }
    for (final i in stack) {
      _end[i] = depths.length;
    }
  }

  final List<int> _level;
  final List<int> _parent;
  final List<int> _end;

  int get length => _level.length;

  /// The number of rows above [index] it hangs from (0 for a top-level row).
  int levelOf(int index) => _level[index];

  /// The index of [index]'s parent row, or -1.
  int parentOf(int index) => _parent[index];

  /// The index after the last row of [index]'s subtree.
  int endOf(int index) => _end[index];

  /// Whether the row after [index] is below it (it has listed children).
  bool hasChildren(int index) => _end[index] > index + 1;

  /// The indices of the pinned rows for a list scrolled by [offset] px, outermost first, at most [maxPinned] of them (the deepest when there
  /// are more: they are the ones that say where you are). Row `i` is drawn at slot `k` (`k * rowHeight` from the top) for its place `k` in the
  /// returned list.
  List<int> pinnedAt(double offset, double rowHeight, {int maxPinned = 1 << 20}) {
    final n = _level.length;
    if (n == 0 || rowHeight <= 0 || maxPinned <= 0) return const [];
    final s = math.max(0.0, offset) / rowHeight;
    final chain = <int>[];
    for (var level = 0;; level++) {
      // The last row whose top is strictly above this level's slot: the one a row for the slot would be the ancestor (or self) of.
      final q = math.min((s + level).ceil() - 1, n - 1);
      if (q < 0 || _level[q] < level) break;
      var e = q;
      while (_level[e] > level) {
        e = _parent[e];
      }
      // Its subtree must still show below the stack (below this slot and the row itself).
      if (!hasChildren(e) || _end[e] <= s + level + 1) break;
      chain.add(e);
    }
    return chain.length <= maxPinned ? chain : chain.sublist(chain.length - maxPinned);
  }
}
