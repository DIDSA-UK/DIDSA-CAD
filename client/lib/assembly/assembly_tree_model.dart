import '../api/document_api_client.dart';
import '../viewport3d/feature_tree_panel.dart' show featureDisplayName;

/// The assembly tree's logic: no widgets, no network. It turns an [AssemblyTreeResponseDto]
/// (`GET /parts/{id}/assembly-tree`) into the flat list of rows a tree draws, following `docs/assembly-tree/spec.md`
/// (sections 3 to 8) rule for rule; `docs/assembly-tree/vectors.json` pins the results.
///
/// Everything is linear in the number of nodes: the names, groups and keys are worked out once per load, and
/// [visibleRows] walks only what is open (the unsaved counts below each node are cached until the unsaved set changes).
/// Two ids are involved: a row *key* (spec section 8) names a row and survives a refresh; `resolvedPartId` is session-local and
/// never part of a key.

/// The state slot of a row (spec section 5), most severe first. [wire] is the spelling in the spec and the vectors.
enum AssemblyRowState {
  missing('missing'),
  cycle('cycle'),
  broken('broken'),
  overConstrained('over_constrained'),
  near('near'),
  unsaved('unsaved'),
  underConstrained('under_constrained'),
  fixed('fixed'),
  fullyConstrained('fully_constrained'),
  none('none');

  final String wire;
  const AssemblyRowState(this.wire);
}

/// What a row is (spec section 7).
enum AssemblyRowKind {
  root('root'),
  assembly('assembly'),
  part('part'),
  missing('missing'),
  group('group'),
  feature('feature'),
  matesFolder('mates_folder'),
  patternsFolder('patterns_folder');

  final String wire;
  const AssemblyRowKind(this.wire);
}

enum AssemblyBubbleLevel { error, warning, unsaved }

/// The count a collapsed row shows (spec section 6): at most one per row, the most severe level that has anything.
class AssemblyBubble {
  final AssemblyBubbleLevel level;
  final int count;
  const AssemblyBubble(this.level, this.count);

  @override
  bool operator ==(Object other) => other is AssemblyBubble && other.level == level && other.count == count;

  @override
  int get hashCode => Object.hash(level, count);

  @override
  String toString() => 'AssemblyBubble(${level.name}, $count)';
}

/// A Feature under a part row: its id (kept in the file, so it is a stable key part) and the label the tree shows.
class AssemblyFeature {
  final String id;
  final String label;
  const AssemblyFeature(this.id, this.label);
}

/// One line of the tree (spec section 7).
class AssemblyTreeRow {
  /// The row key (spec section 8). Unique among the rows of one list.
  final String key;
  final AssemblyRowKind kind;
  final int depth;
  final String label;
  final AssemblyRowState state;
  final AssemblyBubble? bubble;

  /// Whether the row can open (a chevron). An open key on a row that cannot open is ignored: [open] is false.
  final bool expandable;
  final bool open;

  /// Members of a group, items in a folder; null for other rows.
  final int? count;

  /// The node's path for an occurrence row (`[]` for the root); null for group, feature and folder rows.
  /// Map it back to the node with [AssemblyTreeModel.nodeAtPath] for `dof`, `rigid_set`, `color`, `placements`...
  final List<String>? path;
  final bool hidden;
  final bool suppressed;

  /// With `status`: this assembly level's status could not be worked out (spec section 2), which is not the same as status not
  /// being asked for. Show "status unavailable", not healthy.
  final bool statusFailed;

  /// The Feature id of a feature row; null otherwise.
  final String? featureId;

  const AssemblyTreeRow({
    required this.key,
    required this.kind,
    required this.depth,
    required this.label,
    required this.state,
    this.bubble,
    this.expandable = false,
    this.open = false,
    this.count,
    this.path,
    this.hidden = false,
    this.suppressed = false,
    this.statusFailed = false,
    this.featureId,
  });

  @override
  String toString() => 'AssemblyTreeRow($key, ${kind.wire}, depth $depth, "$label", ${state.wire})';
}

/// The display-name rules (spec section 3), exposed for the pieces that need one of them alone. Static members of a class so they do not
/// collide with the older `occurrenceDisplayName` / `looksGeneratedName` the existing panel still uses.
class AssemblyTreeNaming {
  AssemblyTreeNaming._();

  static final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$');
  static final RegExp _prefixedHex = RegExp(r'^(?:[A-Za-z]{1,6}[-_])?[0-9a-fA-F]{16,}$');

  /// Empty or only spaces; a UUID (dashes or not); or 16+ hex digits with an optional 1-6 letter prefix and `-` / `_`.
  static bool looksGenerated(String? name) {
    if (name == null) return true;
    final t = name.trim();
    return t.isEmpty || _uuid.hasMatch(t) || _prefixedHex.hasMatch(t);
  }

  /// The last `/` segment of [externalRef] without its last extension (a leading dot is not an extension: `.washer`); null when there is
  /// no ref. Not checked for looking generated.
  static String? fileBaseName(String? externalRef) {
    if (externalRef == null) return null;
    final slash = externalRef.lastIndexOf('/');
    final file = slash < 0 ? externalRef : externalRef.substring(slash + 1);
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  static bool hasOverride(String? nameOverride) => nameOverride != null && nameOverride.trim().isNotEmpty;
}

// Internal: one node plus everything worked out about it once per load.
class _N {
  final AssemblyTreeNodeDto dto;
  final String key;
  final List<_N> children = [];
  String label = '';

  /// Rows at this node's child level with grouping on: [_N] or [_G], in order. Filled in after the names.
  List<Object> layout = const [];
  _G? group;

  /// Rows below (not suppressed, not under a suppressed row, not missing) whose Part is unsaved. Depends on the unsaved set.
  int unsavedBelow = 0;

  _N(this.dto, this.key);

  bool get missing => dto.kind == 'missing';
}

class _G {
  final String key;
  final String base;
  final List<_N> members = [];
  _G(this.key, this.base);
}

class AssemblyTreeModel {
  AssemblyTreeModel({AssemblyTreeResponseDto? tree, bool grouping = true, Set<String> unsavedPartIds = const {}})
      : _grouping = grouping,
        _unsaved = {...unsavedPartIds} {
    if (tree != null) _load(tree);
  }

  AssemblyTreeResponseDto? _tree;
  bool _grouping;
  Set<String> _unsaved;
  final Set<String> _open = {};
  final Map<String, List<AssemblyFeature>> _features = {};

  // Load products.
  List<_N> _top = const [];
  List<Object> _topLayout = const [];
  final Map<String, _N> _byKey = {};
  final Map<String, _G> _groupsByKey = {};
  List<_N> _preorder = const [];

  List<AssemblyTreeRow>? _rows;
  Map<String, int>? _index;

  // ----- State in -----

  AssemblyTreeResponseDto? get tree => _tree;
  bool get hasTree => _tree != null;

  /// Repeats of 4 or more identical siblings are one group row (spec section 4). On by default.
  bool get grouping => _grouping;
  set grouping(bool value) {
    if (value == _grouping) return;
    _grouping = value;
    _invalidate();
  }

  /// Part ids (the nodes' `resolvedPartId`) the client has unsaved changes to.
  Set<String> get unsavedPartIds => Set.unmodifiable(_unsaved);
  void setUnsavedPartIds(Iterable<String> ids) {
    final next = ids.toSet();
    if (next.length == _unsaved.length && next.containsAll(_unsaved)) return;
    _unsaved = next;
    _countUnsaved();
    _invalidate();
  }

  /// Whether the last response asked for `status=true`. False means status has not been fetched (yet): every status-dependent state is
  /// then just absent. See [statusIncomplete] for the failed case.
  bool get statusIncluded => _tree?.statusIncluded ?? false;

  /// Status was asked for but some level could not be worked out (its rows have [AssemblyTreeRow.statusFailed]).
  bool get statusIncomplete => _tree?.statusIncomplete ?? false;

  /// A depth or node cap was hit: the tree and its problem counts are incomplete.
  bool get truncated => (_tree?.truncatedDepth ?? false) || (_tree?.truncatedNodes ?? false);

  // ----- Open rows and selection -----

  Set<String> get openKeys => Set.unmodifiable(_open);
  bool isOpen(String key) => _open.contains(key);

  void setOpen(String key, bool open) {
    if (open ? !_open.add(key) : !_open.remove(key)) return;
    _invalidate();
  }

  void toggle(String key) => setOpen(key, !_open.contains(key));

  void openAll(Iterable<String> keys) {
    var changed = false;
    for (final k in keys) {
      changed = _open.add(k) || changed;
    }
    if (changed) _invalidate();
  }

  void closeAll() {
    if (_open.isEmpty) return;
    _open.clear();
    _invalidate();
  }

  /// The selected row key (any row: occurrence, group, feature, folder) or null. Kept across [merge] while the row still exists.
  String? selectedKey;

  /// The selected node's path, when the selection is an occurrence row.
  List<String>? get selectedPath => selectedKey == null ? null : _byKey[selectedKey]?.dto.path;

  // ----- Features (lazy, under a part row) -----

  /// Sets the Features listed under the row at [path] (`[]` is the root Part). They show when that row is open. [features]' labels are
  /// whatever the caller names them; [setFeatureDtos] uses the existing `featureDisplayName`.
  void setFeatures(List<String> path, List<AssemblyFeature> features) {
    _features[_keyOf(path)] = List.unmodifiable(features);
    _invalidate();
  }

  /// Like [setFeatures] from the backend's Feature list, named with `featureDisplayName` (the same names the feature tree uses).
  void setFeatureDtos(List<String> path, List<FeatureDto> features) => setFeatures(path, [
        for (var i = 0; i < features.length; i++) AssemblyFeature(features[i].id, featureDisplayName(features, i)),
      ]);

  void clearFeatures(List<String> path) {
    if (_features.remove(_keyOf(path)) != null) _invalidate();
  }

  /// Whether the row at [path] already has its features (an open part row without them lists nothing under it; show progress on it).
  bool hasFeatures(List<String> path) => _features.containsKey(_keyOf(path));

  // ----- Lookups -----

  AssemblyTreeNodeDto? nodeAtPath(List<String> path) => _byKey[_keyOf(path)]?.dto;
  AssemblyTreeNodeDto? nodeForKey(String key) => _byKey[key]?.dto;

  /// The display name of the node at [path] (spec section 3), or null.
  String? labelAtPath(List<String> path) => _byKey[_keyOf(path)]?.label;

  // ----- Rows -----

  /// The flat list of rows for the open keys, the grouping switch, the unsaved set and the fetched features (spec section 7). The list
  /// is cached until something changes and must not be modified.
  List<AssemblyTreeRow> visibleRows() => _rows ??= _buildRows();

  /// The position of the row [key] in [visibleRows], or -1 when it is not listed.
  int indexOf(String key) {
    final rows = visibleRows();
    var index = _index;
    if (index == null) {
      index = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
      _index = index;
    }
    return index[key] ?? -1;
  }

  /// The keys to open (in order) so the row at [path] is listed: each ancestor, and with grouping on the group row any node of the path
  /// sits in (spec section 8). Empty when nothing is needed or the path is unknown. Does not change the open set: see [revealAndOpen].
  List<String> reveal(List<String> path) {
    final keys = <String>[];
    for (var i = 0; i < path.length; i++) {
      final n = _byKey[_keyOf(path.sublist(0, i + 1))];
      if (n == null) return const [];
      final g = n.group;
      if (_grouping && g != null) keys.add(g.key);
      if (i < path.length - 1) keys.add(n.key);
    }
    return keys;
  }

  /// Opens what [reveal] returns.
  void revealAndOpen(List<String> path) => openAll(reveal(path));

  // ----- Refresh -----

  /// Loads the first response, or replaces the tree with a newer one (a structure refresh, or the `status=true` answer arriving after the
  /// structure) and keeps what the person had: the open keys, the selection and the fetched features, dropping those whose rows no longer
  /// exist (spec section 8). A group key changes when its first member is deleted, so that group starts collapsed.
  void merge(AssemblyTreeResponseDto newTree) {
    _load(newTree);
    _open.removeWhere((k) => !_rowKeyExists(k));
    _features.removeWhere((k, _) => !_ownerExists(k));
    final sel = selectedKey;
    if (sel != null && !_selectionExists(sel)) selectedKey = null;
    _invalidate();
  }

  // ----- Internals -----

  static String _keyOf(List<String> path) => path.join('/');

  void _invalidate() {
    _rows = null;
    _index = null;
  }

  bool _ownerExists(String key) => key.isEmpty || _byKey.containsKey(key);

  bool _rowKeyExists(String key) {
    if (_byKey.containsKey(key)) return true;
    if (_grouping && _groupsByKey.containsKey(key)) return true;
    final t = _tree;
    if (t == null) return false;
    if (key == '#mates') return (t.mates?.count ?? 0) > 0;
    if (key == '#patterns') return (t.patterns?.count ?? 0) > 0;
    return false;
  }

  bool _selectionExists(String key) {
    if (key.isEmpty || _rowKeyExists(key)) return true;
    final i = key.indexOf('#feature:');
    if (i < 0) return false;
    final owner = key.substring(0, i);
    final id = key.substring(i + '#feature:'.length);
    final fs = _features[owner];
    return fs != null && _ownerExists(owner) && fs.any((f) => f.id == id);
  }

  void _load(AssemblyTreeResponseDto tree) {
    _tree = tree;
    _byKey.clear();
    _groupsByKey.clear();
    final pre = <_N>[];
    _top = _loadLevel(tree.children, null, pre);
    _preorder = pre;
    _topLayout = _layoutOf(_top);
    for (final n in pre) {
      n.layout = _layoutOf(n.children);
    }
    _countUnsaved();
  }

  List<_N> _loadLevel(List<AssemblyTreeNodeDto> dtos, _N? parent, List<_N> pre) {
    final nodes = <_N>[];
    for (final d in dtos) {
      final n = _N(d, _keyOf(d.path));
      nodes.add(n);
      _byKey[n.key] = n;
      pre.add(n);
      if (d.children.isNotEmpty) n.children.addAll(_loadLevel(d.children, n, pre));
    }
    _nameLevel(nodes);
    return nodes;
  }

  /// Spec section 3: base names, instance groups and `<n>` numbers among one set of siblings. Sets each node's label and, for groups of
  /// 4 or more (whether or not grouping is on), the node's group.
  void _nameLevel(List<_N> siblings) {
    // Instance groups: non-renamed siblings that place the same Part (missing: the same file).
    final byInstance = <String, List<_N>>{};
    for (final n in siblings) {
      if (AssemblyTreeNaming.hasOverride(n.dto.nameOverride)) continue;
      final k = _instanceKey(n.dto);
      if (k != null) (byInstance[k] ??= []).add(n);
    }
    final baseOf = <String, String?>{};
    for (final e in byInstance.entries) {
      baseOf[e.key] = _groupBase(e.value);
    }
    final numbered = <String, int>{};
    for (var i = 0; i < siblings.length; i++) {
      final n = siblings[i];
      final d = n.dto;
      if (AssemblyTreeNaming.hasOverride(d.nameOverride)) {
        n.label = d.nameOverride!;
        continue;
      }
      final k = _instanceKey(d);
      final base = k == null ? null : baseOf[k];
      if (base == null) {
        n.label = 'Component ${i + 1}';
        continue;
      }
      final size = byInstance[k]!.length;
      if (size >= 2) {
        final next = (numbered[k!] ?? 0) + 1;
        numbered[k] = next;
        n.label = '$base <$next>';
      } else {
        n.label = base;
      }
    }
    // Group rows: 4 or more members with a name. Keyed by the first member.
    for (final e in byInstance.entries) {
      final base = baseOf[e.key];
      final members = e.value;
      if (base == null || members.length < 4) continue;
      final first = members.first;
      final parentKey = first.dto.path.length > 1 ? _keyOf(first.dto.path.sublist(0, first.dto.path.length - 1)) : '';
      final gk = parentKey.isEmpty ? '#group:${first.dto.occurrenceId}' : '$parentKey/#group:${first.dto.occurrenceId}';
      final g = _G(gk, base)..members.addAll(members);
      _groupsByKey[gk] = g;
      for (final m in members) {
        m.group = g;
      }
    }
  }

  static String? _instanceKey(AssemblyTreeNodeDto d) {
    if (d.kind == 'missing') return d.externalRef == null ? null : 'f:${d.externalRef}';
    return d.resolvedPartId == null ? null : 'p:${d.resolvedPartId}';
  }

  /// The group's shared base name: the Part's name unless it looks generated, else the first member's usable file name; null for none.
  static String? _groupBase(List<_N> members) {
    final partName = members.first.dto.partName;
    if (!AssemblyTreeNaming.looksGenerated(partName)) return partName;
    for (final m in members) {
      final f = AssemblyTreeNaming.fileBaseName(m.dto.externalRef);
      if (!AssemblyTreeNaming.looksGenerated(f)) return f;
    }
    return null;
  }

  /// A level's rows with grouping on: each node, with a group's members replaced (at the first member) by the group.
  List<Object> _layoutOf(List<_N> nodes) {
    final out = <Object>[];
    for (final n in nodes) {
      final g = n.group;
      if (g == null) {
        out.add(n);
      } else if (identical(g.members.first, n)) {
        out.add(g);
      }
    }
    return out;
  }

  /// `unsavedBelow` for every node, children before parents (the pre-order list reversed).
  void _countUnsaved() {
    for (final n in _preorder) {
      n.unsavedBelow = 0;
    }
    for (var i = _preorder.length - 1; i >= 0; i--) {
      final n = _preorder[i];
      var sum = 0;
      for (final c in n.children) {
        if (c.dto.suppressed) continue;
        sum += c.unsavedBelow + (_nodeUnsaved(c) ? 1 : 0);
      }
      n.unsavedBelow = sum;
    }
  }

  bool _nodeUnsaved(_N n) => !n.missing && n.dto.resolvedPartId != null && _unsaved.contains(n.dto.resolvedPartId);

  AssemblyRowState _stateOf(_N n) {
    final d = n.dto;
    if (d.kind == 'missing') return AssemblyRowState.missing;
    if (d.cycle) return AssemblyRowState.cycle;
    final c = d.constraint;
    if (c != null) {
      if (c.brokenMates > 0) return AssemblyRowState.broken;
      if (c.status == ConstraintState.overConstrained) {
        return c.nearMates > 0 ? AssemblyRowState.near : AssemblyRowState.overConstrained;
      }
    }
    if (_nodeUnsaved(n)) return AssemblyRowState.unsaved;
    if (c != null) {
      switch (c.status) {
        case ConstraintState.underConstrained:
          return AssemblyRowState.underConstrained;
        case ConstraintState.fixed:
          return AssemblyRowState.fixed;
        case ConstraintState.fullyConstrained:
          return AssemblyRowState.fullyConstrained;
        case ConstraintState.overConstrained:
          break;
      }
    } else if (d.fixed) {
      return AssemblyRowState.fixed;
    }
    return AssemblyRowState.none;
  }

  bool _canOpen(_N n) => !n.missing && (n.children.isNotEmpty || (n.dto.featureCount ?? 0) > 0);

  AssemblyBubble? _bubbleFrom(int error, int warning, int unsaved) {
    if (error > 0) return AssemblyBubble(AssemblyBubbleLevel.error, error);
    if (warning > 0) return AssemblyBubble(AssemblyBubbleLevel.warning, warning);
    if (unsaved > 0) return AssemblyBubble(AssemblyBubbleLevel.unsaved, unsaved);
    return null;
  }

  static int _problemErrors(AssemblyTreeProblemsDto? p) =>
      p == null ? 0 : p.missing + p.cycles + (p.broken ?? 0) + (p.overConstrained ?? 0);

  List<AssemblyTreeRow> _buildRows() {
    final t = _tree;
    if (t == null) return const [];
    final rows = <AssemblyTreeRow>[];
    rows.add(AssemblyTreeRow(
      key: '',
      kind: AssemblyRowKind.root,
      depth: 0,
      label: t.partName,
      state: _unsaved.contains(t.partId) ? AssemblyRowState.unsaved : AssemblyRowState.none,
      open: true,
      path: const [],
      statusFailed: t.statusFailed,
    ));
    _emitLevel(_grouping ? _topLayout : _top, 1, rows);
    final mates = t.mates;
    if (mates != null && mates.count > 0) {
      rows.add(AssemblyTreeRow(
        key: '#mates',
        kind: AssemblyRowKind.matesFolder,
        depth: 1,
        label: 'Mates',
        state: AssemblyRowState.none,
        bubble: _bubbleFrom(mates.broken ?? 0, mates.near ?? 0, 0),
        expandable: true,
        open: _open.contains('#mates'),
        count: mates.count,
        statusFailed: t.statusFailed,
      ));
    }
    final patterns = t.patterns;
    if (patterns != null && patterns.count > 0) {
      rows.add(AssemblyTreeRow(
        key: '#patterns',
        kind: AssemblyRowKind.patternsFolder,
        depth: 1,
        label: 'Patterns',
        state: AssemblyRowState.none,
        expandable: true,
        open: _open.contains('#patterns'),
        count: patterns.count,
      ));
    }
    _emitFeatures('', 1, rows);
    return List.unmodifiable(rows);
  }

  void _emitLevel(List<Object> items, int depth, List<AssemblyTreeRow> rows) {
    for (final item in items) {
      if (item is _G) {
        _emitGroup(item, depth, rows);
      } else {
        _emitNode(item as _N, depth, rows);
      }
    }
  }

  void _emitNode(_N n, int depth, List<AssemblyTreeRow> rows) {
    final d = n.dto;
    final expandable = _canOpen(n);
    final open = expandable && _open.contains(n.key);
    AssemblyBubble? bubble;
    if (expandable) {
      bubble = open
          ? _bubbleFrom(d.mates?.broken ?? 0, d.mates?.near ?? 0, 0)
          : _bubbleFrom(_problemErrors(d.problems), d.problems?.near ?? 0, n.unsavedBelow);
    }
    rows.add(AssemblyTreeRow(
      key: n.key,
      kind: switch (d.kind) {
        'assembly' => AssemblyRowKind.assembly,
        'missing' => AssemblyRowKind.missing,
        _ => AssemblyRowKind.part,
      },
      depth: depth,
      label: n.label,
      state: _stateOf(n),
      bubble: bubble,
      expandable: expandable,
      open: open,
      path: d.path,
      hidden: d.hidden,
      suppressed: d.suppressed,
      statusFailed: d.statusFailed,
    ));
    if (!open) return;
    _emitLevel(_grouping ? n.layout : n.children, depth + 1, rows);
    _emitFeatures(n.key, depth + 1, rows);
  }

  void _emitGroup(_G g, int depth, List<AssemblyTreeRow> rows) {
    final open = _open.contains(g.key);
    final live = [for (final m in g.members) if (!m.dto.suppressed) m];
    final stateMembers = live.isEmpty ? g.members : live;
    var state = AssemblyRowState.none;
    var hidden = true;
    var suppressed = true;
    var first = true;
    for (final m in stateMembers) {
      final s = _stateOf(m);
      if (first || s.index < state.index) state = s;
      first = false;
    }
    for (final m in g.members) {
      hidden = hidden && m.dto.hidden;
      suppressed = suppressed && m.dto.suppressed;
    }
    AssemblyBubble? bubble;
    if (!open) {
      var error = 0, warning = 0, unsaved = 0;
      for (final m in live) {
        final s = _stateOf(m);
        if (s == AssemblyRowState.missing || s == AssemblyRowState.cycle || s == AssemblyRowState.overConstrained) error++;
        if (_nodeUnsaved(m)) unsaved++;
        error += _problemErrors(m.dto.problems);
        warning += m.dto.problems?.near ?? 0;
        unsaved += m.unsavedBelow;
      }
      bubble = _bubbleFrom(error, warning, unsaved);
    }
    rows.add(AssemblyTreeRow(
      key: g.key,
      kind: AssemblyRowKind.group,
      depth: depth,
      label: '${g.base} x${g.members.length}',
      state: state,
      bubble: bubble,
      expandable: true,
      open: open,
      count: g.members.length,
      hidden: hidden,
      suppressed: suppressed,
    ));
    if (!open) return;
    for (final m in g.members) {
      _emitNode(m, depth + 1, rows);
    }
  }

  void _emitFeatures(String ownerKey, int depth, List<AssemblyTreeRow> rows) {
    final fs = _features[ownerKey];
    if (fs == null) return;
    for (final f in fs) {
      rows.add(AssemblyTreeRow(
        key: '$ownerKey#feature:${f.id}',
        kind: AssemblyRowKind.feature,
        depth: depth,
        label: f.label,
        state: AssemblyRowState.none,
        featureId: f.id,
      ));
    }
  }
}
