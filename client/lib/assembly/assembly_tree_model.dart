import '../api/document_api_client.dart';
import '../viewport3d/feature_tree_panel.dart' show featureDisplayName;
import '../viewport3d/tree_multi_select_controller.dart' show TreeMultiSelectKeys;

/// The assembly tree's logic: no widgets, no network. It turns an [AssemblyTreeResponseDto]
/// (`GET /parts/{id}/assembly-tree`) into the flat list of rows a tree draws, following `docs/assembly-tree/spec.md`
/// (sections 3 to 8) rule for rule; `docs/assembly-tree/vectors.json` pins the results.
///
/// Everything is linear in the number of nodes: the names, groups and keys are worked out once per load, and
/// [visibleRows] walks only what is open (the unsaved counts below each node are cached until the unsaved set changes).
/// Two ids are involved: a row *key* (spec section 8) names a row and survives a refresh; `resolvedPartId` is session-local and
/// never part of a key.

/// The one state slot of a row, most severe first within each of its two scales. [wire] is the spelling in the spec and the vectors.
///
/// An occurrence or group row (spec section 5) shows one of `missing` ... `fullyConstrained`. A row of the live part (spec section 13) shows one
/// of `lostReference` ... `hidden`: a feature the first that applies, a body, surface, curve or default plane [hidden] or nothing; a folder never
/// has one. Both scales end in [none]. [isLiveState] tells them apart; [occurrenceStates] is section 5's list in its order.
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

  /// The live part's scale (spec section 13), most severe first.
  lostReference('lost_reference'),
  movedReference('moved_reference'),
  pendingDetail('pending_detail'),
  rolledBack('rolled_back'),
  hidden('hidden'),
  none('none');

  final String wire;
  const AssemblyRowState(this.wire);

  /// One of the live part's states (spec section 13), not section 5's.
  bool get isLiveState => index >= lostReference.index && this != none;

  /// Spec section 5's states, in its order (what the vectors' `states` list).
  static List<AssemblyRowState> get occurrenceStates => [
        for (final s in values)
          if (!s.isLiveState) s
      ];
}

/// What a row is (spec sections 7 and 13). [wire] is the spelling in the spec and the vectors.
enum AssemblyRowKind {
  root('root'),
  assembly('assembly'),
  part('part'),
  missing('missing'),
  group('group'),

  /// A feature: a fetched feature under a part row (read-only, spec section 7), or a feature of the live part ([AssemblyTreeRow.live]: its
  /// `type`, state slot and actions; spec section 13).
  feature('feature'),
  matesFolder('mates_folder'),
  patternsFolder('patterns_folder'),

  /// A mate or a pattern listed under its root folder (A4: supplied by the host with [AssemblyTreeModel.setFolderItems]; the spec's
  /// rows, vectors and keys do not include them).
  mate('mate'),
  pattern('pattern'),

  /// The live part's folders (spec section 13): they open like a group and never match a filter.
  bodiesFolder('bodies_folder'),
  planesFolder('planes_folder'),
  surfacesFolder('surfaces_folder'),
  curvesFolder('curves_folder'),

  /// What the live part's folders hold: its bodies, surfaces and curves (from `GET /mesh`), and the three default planes.
  body('body'),
  surface('surface'),
  curve('curve'),
  defaultPlane('default_plane');

  final String wire;
  const AssemblyRowKind(this.wire);

  /// One of the live part's four folders.
  bool get isLiveFolder => this == bodiesFolder || this == planesFolder || this == surfacesFolder || this == curvesFolder;

  /// A body, surface or curve row (the bar: Hide / Show, Zoom, More).
  bool get isLiveItem => this == body || this == surface || this == curve;
}

/// What a picker says about a row ([AssemblyPicker]).
enum AssemblyPickState { none, pickable, picked, locked }

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

/// How a mate / pattern item row reads: the colour of its icon and note.
enum AssemblyItemTone { error, warning, info }

/// A mate or a pattern under its root folder (A4). The host names it and says how it reads; the model only keeps and lists it. [note] is the
/// second line (a phone row) or the dimmed text after the label (a desktop row); [tone] colours the row; [suppressed] draws it dimmed.
class AssemblyFolderItem {
  final String id;
  final String label;
  final String? note;
  final AssemblyItemTone? tone;
  final bool suppressed;
  const AssemblyFolderItem(this.id, this.label, {this.note, this.tone, this.suppressed = false});
}

/// A feature of the live part (spec section 13): what the tree needs to draw its row. [lostReference] is the reason, or null when no reference is
/// lost; the other flags are false when absent.
class AssemblyLiveFeature {
  final String id;
  final String label;

  /// The backend's feature `type` (`sketch`, `extrude`, `create_plane`...).
  final String type;
  final String? lostReference;
  final bool movedReference;
  final bool pendingDetail;
  final bool rolledBack;
  final bool hidden;

  const AssemblyLiveFeature({
    required this.id,
    required this.label,
    required this.type,
    this.lostReference,
    this.movedReference = false,
    this.pendingDetail = false,
    this.rolledBack = false,
    this.hidden = false,
  });

  factory AssemblyLiveFeature.fromJson(Map<String, dynamic> j) => AssemblyLiveFeature(
        id: j['id'] as String,
        label: j['label'] as String,
        type: j['type'] as String,
        lostReference: j['lost_reference'] as String?,
        movedReference: j['moved_reference'] == true,
        pendingDetail: j['pending_detail'] == true,
        rolledBack: j['rolled_back'] == true,
        hidden: j['hidden'] == true,
      );

  /// The one state the row shows: the most severe that applies (spec section 13).
  AssemblyRowState get state {
    if (lostReference != null) return AssemblyRowState.lostReference;
    if (movedReference) return AssemblyRowState.movedReference;
    if (pendingDetail) return AssemblyRowState.pendingDetail;
    if (rolledBack) return AssemblyRowState.rolledBack;
    if (hidden) return AssemblyRowState.hidden;
    return AssemblyRowState.none;
  }
}

/// A body, surface or curve of the live part.
class AssemblyLiveItem {
  final String id;
  final String label;
  final bool hidden;
  const AssemblyLiveItem(this.id, this.label, {this.hidden = false});

  factory AssemblyLiveItem.fromJson(Map<String, dynamic> j) =>
      AssemblyLiveItem(j['id'] as String, j['label'] as String, hidden: j['hidden'] == true);
}

/// The live part's inputs (spec section 13): the row that is live, its features in build order, and what its folders hold.
class AssemblyLivePart {
  /// The live row's key: `""` for a part opened on its own.
  final String key;
  final List<AssemblyLiveFeature> features;
  final List<AssemblyLiveItem> bodies;
  final List<AssemblyLiveItem> surfaces;
  final List<AssemblyLiveItem> curves;

  /// Which of the three default planes (`xy`, `xz`, `yz`) are hidden.
  final Set<String> hiddenDefaultPlanes;

  AssemblyLivePart(
    this.key, {
    List<AssemblyLiveFeature> features = const [],
    List<AssemblyLiveItem> bodies = const [],
    List<AssemblyLiveItem> surfaces = const [],
    List<AssemblyLiveItem> curves = const [],
    Set<String> hiddenDefaultPlanes = const {},
  })  : features = List.unmodifiable(features),
        bodies = List.unmodifiable(bodies),
        surfaces = List.unmodifiable(surfaces),
        curves = List.unmodifiable(curves),
        hiddenDefaultPlanes = Set.unmodifiable(hiddenDefaultPlanes);

  /// The vectors' `live` object.
  factory AssemblyLivePart.fromJson(Map<String, dynamic> j) {
    List<T> list<T>(String k, T Function(Map<String, dynamic>) f) =>
        [for (final e in (j[k] as List? ?? const [])) f(e as Map<String, dynamic>)];
    final planes = (j['default_planes_hidden'] as Map<String, dynamic>?) ?? const {};
    return AssemblyLivePart(
      j['key'] as String,
      features: list('features', AssemblyLiveFeature.fromJson),
      bodies: list('bodies', AssemblyLiveItem.fromJson),
      surfaces: list('surfaces', AssemblyLiveItem.fromJson),
      curves: list('curves', AssemblyLiveItem.fromJson),
      hiddenDefaultPlanes: {
        for (final e in planes.entries)
          if (e.value == true) e.key
      },
    );
  }

  List<AssemblyLiveFeature> get planeFeatures => [
        for (final f in features)
          if (f.type == 'create_plane') f
      ];
}

/// The picker modes of the build tree as rules (P1; the old panel had one widget flag each). While a picker is set on the model
/// ([AssemblyTreeModel.setPicker]) every feature, body, surface, curve and default-plane row carries a pick state ([AssemblyTreeRow.pick]):
/// pickable, picked, or locked with a reason ([AssemblyTreeRow.pickReason]). Folders and occurrence rows are not touched (a tree must still open).
/// The sets hold [TreeMultiSelectKeys] (`feature:<id>`, `body:<id>`...), because a single-body feature's body id is its feature id.
class AssemblyPicker {
  /// The banner that replaces the selection bar while the picker is open; null for a lock with nothing to pick.
  final String? banner;

  /// Several rows can be picked (they tick) rather than one.
  final bool multi;
  final Set<String> pickable;
  final Set<String> picked;

  /// Rows that say why they cannot be picked (a convert pick's later sketches).
  final Map<String, String> lockedReasons;

  /// Why every other row of those kinds is locked; null leaves them untouched.
  final String? otherReason;

  const AssemblyPicker({
    this.banner,
    this.multi = false,
    this.pickable = const {},
    this.picked = const {},
    this.lockedReasons = const {},
    this.otherReason,
  });

  /// The sketch picker of a pending Extrude: only the eligible sketches are pickable, one pick.
  factory AssemblyPicker.sketch({
    required Iterable<String> eligibleSketchIds,
    String banner = 'Select a sketch to extrude',
    String ineligibleReason = 'Pick a sketch with a closed profile',
  }) =>
      AssemblyPicker(
        banner: banner,
        pickable: {for (final id in eligibleSketchIds) TreeMultiSelectKeys.feature(id)},
        otherReason: ineligibleReason,
      );

  /// The Mirror / Pattern source multi-picker: the eligible features tick.
  factory AssemblyPicker.sources({
    required Iterable<String> pickableFeatureIds,
    Iterable<String> pickedFeatureIds = const [],
    String banner = 'Select the source features',
    String ineligibleReason = 'This feature cannot be a source',
  }) =>
      AssemblyPicker(
        banner: banner,
        multi: true,
        pickable: {for (final id in pickableFeatureIds) TreeMultiSelectKeys.feature(id)},
        picked: {for (final id in pickedFeatureIds) TreeMultiSelectKeys.feature(id)},
        otherReason: ineligibleReason,
      );

  /// Convert Entities in the sketcher: the earlier sketches are pickable, the later ones locked with [laterReason], the rest with [lockedReason].
  factory AssemblyPicker.convert({
    required Iterable<String> pickableSketchIds,
    Iterable<String> pickedSketchIds = const [],
    Iterable<String> laterSketchIds = const [],
    String laterReason = 'This sketch comes after the one being edited',
    String lockedReason = 'Exit the sketch first',
    String banner = 'Pick a sketch to convert',
  }) =>
      AssemblyPicker(
        banner: banner,
        multi: true,
        pickable: {for (final id in pickableSketchIds) TreeMultiSelectKeys.feature(id)},
        picked: {for (final id in pickedSketchIds) TreeMultiSelectKeys.feature(id)},
        lockedReasons: {for (final id in laterSketchIds) TreeMultiSelectKeys.feature(id): laterReason},
        otherReason: lockedReason,
      );

  /// The sketcher's read-mostly lock: every row says [reason]; there is no banner.
  factory AssemblyPicker.locked(String reason) => AssemblyPicker(otherReason: reason);
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

  /// A mate or pattern item row (see [AssemblyFolderItem]): its id, note and tone; null otherwise.
  final String? itemId;
  final String? note;
  final AssemblyItemTone? tone;

  /// With a filter on (spec section 11): this row is a match, not just an ancestor listed to show where the match is. Always false
  /// without a filter, and for the root.
  final bool match;

  /// A row of the live part (spec section 13): its folders, features, bodies, surfaces, curves and default planes. Only these are editable and
  /// pickable; a feature row under another part has the same [kind] and is read-only.
  final bool live;

  /// The feature's `type` on a live feature row; null otherwise.
  final String? type;

  /// The reason a live feature's reference is lost (its tooltip and the bar's text); null otherwise.
  final String? lostReason;

  /// What the model's picker says about this row ([AssemblyTreeModel.setPicker]) and, when it is locked, why.
  final AssemblyPickState pick;
  final String? pickReason;

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
    this.itemId,
    this.note,
    this.tone,
    this.match = false,
    this.live = false,
    this.type,
    this.lostReason,
    this.pick = AssemblyPickState.none,
    this.pickReason,
  });

  /// A feature row of the live part (the build-order row or a plane feature in the Planes folder).
  bool get isLiveFeature => live && kind == AssemblyRowKind.feature;

  /// This row with [match] set (the filter's output; rows are immutable).
  AssemblyTreeRow withMatch(bool value) => _copy(match: value);

  /// This row with a picker's verdict.
  AssemblyTreeRow withPick(AssemblyPickState state, String? reason) => _copy(match: match, pick: state, pickReason: reason);

  AssemblyTreeRow _copy({required bool match, AssemblyPickState? pick, String? pickReason}) => AssemblyTreeRow(
        key: key,
        kind: kind,
        depth: depth,
        label: label,
        state: state,
        bubble: bubble,
        expandable: expandable,
        open: open,
        count: count,
        path: path,
        hidden: hidden,
        suppressed: suppressed,
        statusFailed: statusFailed,
        featureId: featureId,
        itemId: itemId,
        note: note,
        tone: tone,
        match: match,
        live: live,
        type: type,
        lostReason: lostReason,
        pick: pick ?? this.pick,
        pickReason: pick == null ? this.pickReason : pickReason,
      );

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

/// The result of [AssemblyTreeModel.filteredRows] (spec section 11): the rows to draw, and the tokens the query used that no filter knows.
class AssemblyFilterResult {
  /// With no filter (an empty query) these are the ordinary [AssemblyTreeModel.visibleRows], every `match` false.
  final List<AssemblyTreeRow> rows;

  /// Unknown `:tokens`, lower case, once each, in query order ("unknown filter :foo").
  final List<String> unknown;

  /// Whether the query held anything: false for an empty or all-space query.
  final bool active;

  /// Some part has features that were not read (it was never opened), so the filter could not look at them (spec section 11: say so).
  final bool featuresNotRead;

  const AssemblyFilterResult(this.rows, this.unknown, {required this.active, this.featuresNotRead = false});
}

/// At most this many open keys are remembered per document (spec section 12).
const int kAssemblyTreeMaxStoredKeys = 2000;

/// What a filter token tests (spec section 11): the row, and whether its occurrence is `fixed` whatever its state.
typedef _TokenTest = bool Function(AssemblyTreeRow row, bool fixed);

const _errorStates = {AssemblyRowState.missing, AssemblyRowState.cycle, AssemblyRowState.broken, AssemblyRowState.overConstrained};

// Written out one by one, in the spec's order, so the two can be compared line by line. `:sketches` needs a feature's `type`, which rows have
// only with the live part (spec section 13).
final Map<String, _TokenTest> _filterTokens = {
  ':missing': (r, f) => r.state == AssemblyRowState.missing,
  ':errors': (r, f) => _errorStates.contains(r.state) || r.state == AssemblyRowState.lostReference,
  ':warnings': (r, f) => r.state == AssemblyRowState.near || r.state == AssemblyRowState.movedReference,
  ':unsaved': (r, f) => r.state == AssemblyRowState.unsaved,
  ':fixed': (r, f) => f,
  ':hidden': (r, f) => r.hidden,
  ':suppressed': (r, f) => r.suppressed,
  ':parts': (r, f) => r.kind == AssemblyRowKind.part,
  ':assemblies': (r, f) => r.kind == AssemblyRowKind.assembly,
  ':features': (r, f) => r.kind == AssemblyRowKind.feature,
  ':sketches': (r, f) => r.type == 'sketch',
};

/// Rows that never match themselves (spec section 11). Mate and pattern item rows are not in the spec's rows; they are never listed
/// by a filter either (the folders are not listed).
const _nonMatchingKinds = {
  AssemblyRowKind.root,
  AssemblyRowKind.group,
  AssemblyRowKind.matesFolder,
  AssemblyRowKind.patternsFolder,
  AssemblyRowKind.mate,
  AssemblyRowKind.pattern,
  AssemblyRowKind.bodiesFolder,
  AssemblyRowKind.planesFolder,
  AssemblyRowKind.surfacesFolder,
  AssemblyRowKind.curvesFolder,
};

/// What a row walk records about each row it emits: its parent's key (null for the root) and its occurrence's `fixed` flag.
class _Trace {
  final String? parent;
  final bool fixed;
  const _Trace(this.parent, this.fixed);
}

/// A row of the live part: its parent's key (the live row or one of its folders) and its [TreeMultiSelectKeys] key when it has one.
class _LiveRef {
  final String parent;
  final String? ms;
  const _LiveRef(this.parent, this.ms);
}

/// One walk of the rows (spec section 7): which keys are open, whether grouping is on, and, for the filter, which keys are listed. The
/// ordinary [AssemblyTreeModel.visibleRows] is the walk of the model's own open keys; the filter and restore walk with everything open.
class _Walk {
  final List<AssemblyTreeRow> rows = [];
  final Set<String> open;
  final bool openAll;
  final bool grouping;

  /// When set, only these keys are emitted (a row that is not listed is skipped with everything below it).
  final Set<String>? listed;
  final Map<String, _Trace>? trace;

  /// List the live part's rows even while it is hidden ([AssemblyTreeModel.livePartShown] false): the restore walk.
  final bool liveHidden;

  _Walk({required this.open, required this.grouping, this.openAll = false, this.listed, this.trace, this.liveHidden = false});

  bool isOpen(String key) => openAll || open.contains(key);

  /// Emits [row] under [parent]; false when a filter does not list it.
  bool add(AssemblyTreeRow row, String? parent, {bool fixed = false}) {
    if (listed != null && !listed!.contains(row.key)) return false;
    rows.add(row);
    trace?[row.key] = _Trace(parent, fixed);
    return true;
  }
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
  final Map<String, List<AssemblyFolderItem>> _folderItems = {};
  Set<String> _sessionHidden = const {};
  AssemblyLivePart? _live;

  /// The live key whose row was last opened because it became live (so closing it again is the person's choice).
  String? _liveOpenedFor;

  /// Rows open only because they became live (nobody opened them): kept out of [keysToStore] until the person opens or closes them, or a
  /// restore of stored keys opens them (then they are the person's). A set: when the live row moves, the row it left stays open and still
  /// is not the person's. Pruned with the open keys.
  final Set<String> _autoOpen = {};
  AssemblyPicker? _picker;
  Map<String, _LiveRef>? _liveRefs;
  Map<String, String>? _liveMs;

  // Load products.
  List<_N> _top = const [];
  List<Object> _topLayout = const [];
  final Map<String, _N> _byKey = {};
  final Map<String, _G> _groupsByKey = {};
  List<_N> _preorder = const [];

  List<AssemblyTreeRow>? _rows;
  Map<String, int>? _index;

  /// The filter's working copy: every row with everything open (and what each row's parent is), and the results by query. Cleared by anything
  /// that changes a row.
  _Walk? _everything;
  final Map<String, AssemblyFilterResult> _filtered = {};

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

  /// Called after the open keys were changed by [setOpen], [toggle], [openAll] or [closeAll] (not by [merge] dropping keys of rows that are
  /// gone, nor by an [openAll] with `remember: false`). The host stores the keys (spec section 12).
  void Function()? onOpenKeysChanged;

  /// Whether the person changed the open keys since this model was made: a change that opened or closed something, or a collapse all (even of
  /// nothing: that is still the person asking for it collapsed). An open of what was open already (an expand to selection with nothing to
  /// open) is not. A restore of stored keys is skipped when it is true: the person's own change comes first (spec section 12).
  bool get openKeysTouched => _openTouched;
  bool _openTouched = false;

  void _opened(bool changed, {bool remember = true, bool deliberate = false}) {
    if (!remember) {
      if (changed) _invalidate();
      return;
    }
    if (changed || deliberate) _openTouched = true;
    if (changed) {
      _invalidate();
      onOpenKeysChanged?.call();
    }
  }

  void setOpen(String key, bool open) {
    _autoOpen.remove(key); // the person's own choice from here on
    _opened(open ? _open.add(key) : _open.remove(key));
  }

  void toggle(String key) => setOpen(key, !_open.contains(key));

  /// Opens [keys]. With `remember: false` this is a restore (or the like), not a change the person made: it is not stored and does not
  /// count as one.
  ///
  /// A key that is open only because its row became live stays so when this opens nothing new for it (an expand to selection through it); a
  /// restore (`remember: false`) of such a key makes it the person's again: it came from their stored rows.
  void openAll(Iterable<String> keys, {bool remember = true}) {
    var changed = false;
    for (final k in keys) {
      final added = _open.add(k);
      if (added || !remember) _autoOpen.remove(k);
      changed = added || changed;
    }
    _opened(changed, remember: remember);
  }

  /// Empties the open keys (the root stays open: it always is).
  void closeAll() {
    _autoOpen.clear();
    final changed = _open.isNotEmpty;
    _open.clear();
    _opened(changed, deliberate: true);
  }

  /// The selected row key (any row: occurrence, group, feature, folder) or null. Kept across [merge] while the row still exists.
  String? selectedKey;

  /// The selected node's path, when the selection is an occurrence row.
  List<String>? get selectedPath {
    final k = selectedKey;
    if (k == null) return null;
    if (k.isEmpty) return const [];
    return _byKey[k]?.dto.path;
  }

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
  bool hasFeatures(List<String> path) => _features.containsKey(_keyOf(path)) || (_liveValid && _live!.key == _keyOf(path));

  // ----- The live part (spec section 13) -----

  /// The live part's inputs, or null. A live row whose key names no row of the tree, or a missing row, is ignored (nothing is added).
  AssemblyLivePart? get livePart => _live;
  /// The live part is set, its row exists, and it is shown ([livePartShown]): its rows are listed.
  bool get _liveValid => _liveShown && _liveDataValid;

  /// The live part is set and its row exists, shown or not: its keys name rows that exist (they are kept by [merge] and [setLivePart]).
  bool get _liveDataValid {
    final l = _live;
    if (l == null || _tree == null) return false;
    if (l.key.isEmpty) return true;
    final n = _byKey[l.key];
    return n != null && !n.missing;
  }

  /// The key of the row that is live now, or null (none set, or its row does not exist).
  String? get liveKey => _liveValid ? _live!.key : null;

  /// Makes [live] the live part: its folders and features replace what [setFeatures] gave that row. When the row becomes live (a different row
  /// from the one before) its key is added to the open keys so it shows open; that is not the person's change: nothing is reported,
  /// [openKeysTouched] stays as it was, and [keysToStore] leaves the key out until the person opens or closes it themselves. Later calls for the
  /// same row refresh the data and leave its open state. A refresh of the same live row drops, like [merge], a selected row and open folders the
  /// live part no longer has; clearing it, or making another row live, drops nothing (a clear then a set of the same row keeps its folders).
  void setLivePart(AssemblyLivePart? live) {
    final before = _live;
    _live = live;
    if (live == null) _liveOpenedFor = null;
    _invalidate();
    // Like merge(): what the refreshed live part no longer has goes (a selected row, a folder that emptied and so starts collapsed when it fills
    // again).
    if (_tree != null && before != null && live != null && before.key == live.key) {
      _open.removeWhere((k) => !_rowKeyExists(k));
      final sel = selectedKey;
      if (sel != null && !_selectionExists(sel)) selectedKey = null;
      _autoOpen.retainAll(_open);
    }
    _openLive();
  }

  void clearLivePart() => setLivePart(null);

  bool _liveShown = true;

  /// Whether the live part's rows are listed (P2: the Part lens shows them, the Assembly lens does not). Hidden, the live part keeps its inputs
  /// and nothing of it is listed (its row lists what [setFeatures] gave it, as any other part row), but its open folders and a selected live row
  /// are not dropped by [merge] or [setLivePart]: they name rows that come back when it is shown again. Switching it is not the person's change:
  /// nothing is reported or stored and [openKeysTouched] is unchanged. On by default.
  bool get livePartShown => _liveShown;
  set livePartShown(bool value) {
    if (value == _liveShown) return;
    _liveShown = value;
    _invalidate();
    if (value) _openLive();
  }

  void _openLive() {
    final l = _live;
    if (l == null || !_liveValid) return;
    if (_liveOpenedFor == l.key) return;
    _liveOpenedFor = l.key;
    if (l.key.isNotEmpty && !_open.contains(l.key)) {
      openAll([l.key], remember: false);
      _autoOpen.add(l.key);
    }
  }

  /// A feature row's key in the live part, for the id [featureId] (the build-order row); null when it is not a live feature.
  String? liveFeatureKey(String featureId) => _liveValid ? _liveMsMap[TreeMultiSelectKeys.feature(featureId)] : null;

  // ----- Multi-select keys (P1) -----

  /// The [TreeMultiSelectKeys] key (`feature:<id>`, `body:<id>`, `surface:<id>`, `curve:<id>`) of a live row, or null for any other row (an
  /// occurrence, a folder, a default plane). A plane feature listed in the Planes folder gives its feature's key, the same as its build-order row.
  String? multiSelectKeyOfRow(String rowKey) => _liveValid ? _liveRefMap[rowKey]?.ms : null;

  /// The row key of the live row a [TreeMultiSelectKeys] key names: the build-order row for a feature, else the body, surface or curve row; null
  /// when the live part has no such row.
  String? rowKeyOfMultiSelect(String key) => _liveValid ? _liveMsMap[key] : null;

  /// Every live row a [TreeMultiSelectKeys] key names: a plane feature has two (its build-order row and its row in the Planes folder), so a
  /// multi-select ticks both. Empty when the live part has none (or is not shown).
  List<String> rowKeysOfMultiSelect(String key) => !_liveValid
      ? const []
      : [
          for (final e in _liveRefMap.entries)
            if (e.value.ms == key) e.key
        ];

  Map<String, _LiveRef> get _liveRefMap => _liveRefs ??= _buildLiveRefs();
  Map<String, String> get _liveMsMap {
    _liveRefMap;
    return _liveMs!;
  }

  /// Every row key of the live part (what a walk with everything open lists), with its parent and multi-select key. Empty when no live part.
  Map<String, _LiveRef> _buildLiveRefs() {
    final refs = <String, _LiveRef>{};
    final ms = <String, String>{};
    _liveMs = ms;
    final l = _live;
    if (l == null || !_liveDataValid) return refs;
    final k = l.key;
    for (final f in l.features) {
      final key = '$k#feature:${f.id}';
      final m = TreeMultiSelectKeys.feature(f.id);
      refs[key] = _LiveRef(k, m);
      ms.putIfAbsent(m, () => key);
    }
    void items(String folder, String prefix, List<AssemblyLiveItem> list, String Function(String) msKey) {
      if (list.isEmpty) return;
      refs['$k#$folder'] = _LiveRef(k, null);
      for (final it in list) {
        final key = '$k#$prefix:${it.id}';
        final m = msKey(it.id);
        refs[key] = _LiveRef('$k#$folder', m);
        ms[m] = key;
      }
    }

    items('bodies', 'body', l.bodies, TreeMultiSelectKeys.body);
    refs['$k#planes'] = _LiveRef(k, null);
    for (final id in const ['xy', 'xz', 'yz']) {
      refs['$k#plane:$id'] = _LiveRef('$k#planes', null);
    }
    for (final f in l.planeFeatures) {
      refs['$k#plane:feature:${f.id}'] = _LiveRef('$k#planes', TreeMultiSelectKeys.feature(f.id));
    }
    items('surfaces', 'surface', l.surfaces, TreeMultiSelectKeys.surface);
    items('curves', 'curve', l.curves, TreeMultiSelectKeys.curve);
    return refs;
  }

  // ----- Pickers (P1) -----

  /// The picker that is open, or null. Set it to make every feature, body, surface, curve and default-plane row carry a pick state
  /// ([AssemblyTreeRow.pick]); the view shows the picker's banner in place of the selection bar.
  AssemblyPicker? get picker => _picker;
  void setPicker(AssemblyPicker? picker) {
    _picker = picker;
    _invalidate();
  }

  AssemblyTreeRow _withPick(AssemblyTreeRow r) {
    final p = _picker;
    if (p == null) return r;
    if (!(r.kind == AssemblyRowKind.feature || (r.live && !r.kind.isLiveFolder))) return r;
    final m = r.live ? _liveRefMap[r.key]?.ms : null;
    if (m != null) {
      if (p.picked.contains(m)) return r.withPick(AssemblyPickState.picked, null);
      if (p.pickable.contains(m)) return r.withPick(AssemblyPickState.pickable, null);
    }
    final why = (m == null ? null : p.lockedReasons[m]) ?? p.otherReason;
    return why == null ? r : r.withPick(AssemblyPickState.locked, why);
  }

  // ----- Mates and patterns under the root folders (A4) -----

  /// Sets what is listed under the root folder [folderKey] (`#mates` or `#patterns`) when it is open. The host reads `/mates` and
  /// `/component-patterns` (spec section 7, rule 8) and names the rows. Not part of the spec's rows: a model with none set lists
  /// exactly what the vectors say.
  void setFolderItems(String folderKey, List<AssemblyFolderItem> items) {
    _folderItems[folderKey] = List.unmodifiable(items);
    _invalidate();
  }

  /// What [setFolderItems] last set for [folderKey] (empty when nothing was).
  List<AssemblyFolderItem> folderItems(String folderKey) => _folderItems[folderKey] ?? const [];

  // ----- Hidden for this session (A4) -----

  /// Row keys hidden for this session only, on top of each node's own `hidden`: Hide on a nested row hides that placement alone (the
  /// backend's flag sits on the sub-assembly's occurrence, which every placement shares). Those rows read as hidden (the eye-off).
  Set<String> get sessionHiddenKeys => _sessionHidden;
  void setSessionHiddenKeys(Set<String> keys) {
    if (keys.length == _sessionHidden.length && keys.containsAll(_sessionHidden)) return;
    _sessionHidden = {...keys};
    _invalidate();
  }

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

  // ----- Expand to selection (spec section 12) -----

  /// The keys to open so the selected row is listed: [reveal] for an occurrence row, and for a feature row its owner too, for a group row
  /// its parent. Empty with no selection, for the root, or when the row is unknown. Does not change the open set.
  List<String> selectionRevealKeys() {
    final key = selectedKey;
    if (key == null || key.isEmpty) return const [];
    final path = selectedPath;
    if (path != null) return reveal(path);
    List<String> ownerKeys(String owner) {
      if (owner.isEmpty) return const [];
      final ownerPath = _byKey[owner]?.dto.path;
      return ownerPath == null ? const [] : [...reveal(ownerPath), owner];
    }

    final ref = _liveValid ? _liveRefMap[key] : null;
    if (ref != null) {
      final owner = _live!.key;
      return [...ownerKeys(owner), if (ref.parent != owner) ref.parent];
    }

    final f = key.indexOf('#feature:');
    if (f >= 0) return ownerKeys(key.substring(0, f));
    if (_groupsByKey.containsKey(key)) {
      final slash = key.lastIndexOf('/');
      return ownerKeys(slash < 0 ? '' : key.substring(0, slash));
    }
    return const [];
  }

  /// Opens what [selectionRevealKeys] returns; true when that changed anything.
  bool expandToSelection() {
    final before = _open.length;
    openAll(selectionRevealKeys());
    return _open.length != before;
  }

  // ----- Remembered open rows (spec section 12) -----

  /// The stored keys that still name a row that can open, in the order of the tree's rows with everything open and grouping on (so it
  /// is the same whatever the current grouping), at most [limit]. A group key is checked as if grouping were on, so switching grouping off
  /// and on loses nothing. Never kept: the root, feature keys. Does not change the open set: the host opens what this returns
  /// (`openAll(keys, remember: false)`). Empty with no tree.
  List<String> restoreOpenKeys(Iterable<String> stored, {int limit = kAssemblyTreeMaxStoredKeys}) {
    if (_tree == null) return const [];
    final wanted = stored is Set<String> ? stored : stored.toSet();
    if (wanted.isEmpty) return const [];
    // The live part's folders are restorable whether or not it is shown (the Assembly lens hides it; its folders come back with it).
    final rows = _walk(_Walk(open: const {}, grouping: true, openAll: true, liveHidden: true));
    const kinds = {
      AssemblyRowKind.assembly,
      AssemblyRowKind.part,
      AssemblyRowKind.group,
      AssemblyRowKind.matesFolder,
      AssemblyRowKind.patternsFolder,
      AssemblyRowKind.bodiesFolder,
      AssemblyRowKind.planesFolder,
      AssemblyRowKind.surfacesFolder,
      AssemblyRowKind.curvesFolder,
    };
    final kept = <String>[];
    for (final r in rows) {
      if (kept.length >= limit) break;
      if (r.expandable && kinds.contains(r.kind) && wanted.contains(r.key)) kept.add(r.key);
    }
    return kept;
  }

  /// The open keys to store: all of them, or past the cap the first [limit] in the order of [restoreOpenKeys].
  List<String> keysToStore({int limit = kAssemblyTreeMaxStoredKeys}) =>
      _storable().length <= limit ? _storable().toList() : restoreOpenKeys(_storable(), limit: limit);

  /// The open keys without a live row that is open only because it became live.
  Set<String> _storable() => _autoOpen.isEmpty ? _open : _open.difference(_autoOpen);

  // ----- Filter (spec section 11) -----

  /// The rows for [query]: the root, every row that matches, and every ancestor of a match (with grouping on, the group a match sits in),
  /// each with `match` set; an empty query is no filter (the ordinary rows). Words starting with `:` are tokens (`:errors`...); an unknown
  /// one is listed in `unknown`. The open keys are not changed and the Mates and Patterns folders are not listed. Cached until something changes.
  AssemblyFilterResult filteredRows(String query) {
    final cached = _filtered[query];
    if (cached != null) return cached;
    final result = _filter(query);
    if (_filtered.length >= 16) _filtered.remove(_filtered.keys.first);
    return _filtered[query] = result;
  }

  AssemblyFilterResult _filter(String query) {
    if (_tree == null) return const AssemblyFilterResult([], [], active: false);
    final terms = <String>[];
    final tokens = <String>[];
    final unknown = <String>[];
    for (final word in query.toLowerCase().split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final bucket = word.startsWith(':') ? (_filterTokens.containsKey(word) ? tokens : unknown) : terms;
      if (!bucket.contains(word)) bucket.add(word);
    }
    if (terms.isEmpty && tokens.isEmpty && unknown.isEmpty) return AssemblyFilterResult(visibleRows(), const [], active: false);

    final everything = _everything ??= _everythingWalk();
    final trace = everything.trace!;
    final matches = <String>{};
    if (terms.isNotEmpty || tokens.isNotEmpty) {
      for (final r in everything.rows) {
        if (_nonMatchingKinds.contains(r.kind)) continue;
        final label = r.label.toLowerCase();
        if (terms.every(label.contains) && tokens.every((t) => _filterTokens[t]!(r, trace[r.key]!.fixed))) matches.add(r.key);
      }
    }
    final listed = <String>{''};
    for (final m in matches) {
      String? k = m;
      while (k != null && listed.add(k)) {
        k = trace[k]!.parent;
      }
    }
    // A listed row is open when something below it is listed.
    final open = {
      for (final k in listed)
        if (k.isNotEmpty) trace[k]!.parent!
    };
    final rows = _walk(_Walk(open: open, grouping: _grouping, listed: listed));
    return AssemblyFilterResult(
      List.unmodifiable([for (final r in rows) _withPick(r.withMatch(matches.contains(r.key)))]),
      unknown,
      active: true,
      featuresNotRead: _featuresNotRead(),
    );
  }

  bool _featuresNotRead() {
    if ((_tree?.featureCount ?? 0) > 0 && !hasFeatures(const [])) return true;
    for (final n in _preorder) {
      if (!n.missing && (n.dto.featureCount ?? 0) > 0 && !hasFeatures(n.dto.path)) return true;
    }
    return false;
  }

  _Walk _everythingWalk() {
    final w = _Walk(open: const {}, grouping: _grouping, openAll: true, trace: {});
    _walk(w);
    return w;
  }

  // ----- Refresh -----

  /// Loads the first response, or replaces the tree with a newer one (a structure refresh, or the `status=true` answer arriving after the
  /// structure) and keeps what the person had: the open keys, the selection and the fetched features, dropping those whose rows no longer
  /// exist (spec section 8). A group key changes when its first member is deleted, so that group starts collapsed.
  void merge(AssemblyTreeResponseDto newTree) {
    _load(newTree);
    _open.removeWhere((k) => !_rowKeyExists(k));
    _autoOpen.retainAll(_open);
    _features.removeWhere((k, _) => !_ownerExists(k));
    final sel = selectedKey;
    if (sel != null && !_selectionExists(sel)) selectedKey = null;
    _invalidate();
    _openLive(); // a live part set before the tree arrived opens its row now
  }

  // ----- Internals -----

  static String _keyOf(List<String> path) => path.join('/');

  void _invalidate() {
    _liveRefs = null;
    _liveMs = null;
    _rows = null;
    _index = null;
    _everything = null;
    _filtered.clear();
  }

  bool _ownerExists(String key) => key.isEmpty || _byKey.containsKey(key);

  bool _rowKeyExists(String key) {
    if (_byKey.containsKey(key)) return true;
    if (_groupsByKey.containsKey(key)) return true; // whatever the grouping switch says: it may be turned back on
    final t = _tree;
    if (t == null) return false;
    if (key == '#mates') return (t.mates?.count ?? 0) > 0;
    if (key == '#patterns') return (t.patterns?.count ?? 0) > 0;
    final ref = _liveRefMap[key];
    return ref != null && ref.ms == null && _liveFolderKey(key); // a live folder (the only live rows that can open)
  }

  bool _liveFolderKey(String key) {
    final k = _live!.key;
    return key == '$k#bodies' || key == '$k#planes' || key == '$k#surfaces' || key == '$k#curves';
  }

  bool _selectionExists(String key) {
    if (key.isEmpty || _rowKeyExists(key) || _liveRefMap.containsKey(key)) return true;
    for (final folder in const ['#mates', '#patterns']) {
      final prefix = '$folder#item:';
      if (key.startsWith(prefix)) return _folderItems[folder]?.any((it) => '$prefix${it.id}' == key) ?? false;
    }
    final i = key.indexOf('#feature:');
    if (i < 0) return false;
    final owner = key.substring(0, i);
    // The live row's features are the live part's (checked above): what [setFeatures] once gave that row does not keep a deleted one selected.
    if (_liveDataValid && owner == _live!.key) return false;
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
    _liveRefs = null;
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
    if (_tree == null) return const [];
    return List.unmodifiable([for (final r in _walk(_Walk(open: _open, grouping: _grouping))) _withPick(r)]);
  }

  /// Spec section 7 for one [_Walk]: the root, its children, the Mates and Patterns folders (not while a filter lists rows), the root's features.
  List<AssemblyTreeRow> _walk(_Walk w) {
    final t = _tree!;
    w.add(
      AssemblyTreeRow(
        key: '',
        kind: AssemblyRowKind.root,
        depth: 0,
        label: t.partName,
        state: _unsaved.contains(t.partId) ? AssemblyRowState.unsaved : AssemblyRowState.none,
        open: true,
        path: const [],
        statusFailed: t.statusFailed,
      ),
      null,
    );
    _emitLevel(w.grouping ? _topLayout : _top, 1, '', w);
    if (w.listed == null) {
      final mates = t.mates;
      if (mates != null && mates.count > 0) {
        final open = w.isOpen('#mates');
        w.add(
          AssemblyTreeRow(
            key: '#mates',
            kind: AssemblyRowKind.matesFolder,
            depth: 1,
            label: 'Mates',
            state: AssemblyRowState.none,
            bubble: _bubbleFrom(mates.broken ?? 0, mates.near ?? 0, 0),
            expandable: true,
            open: open,
            count: mates.count,
            statusFailed: t.statusFailed,
          ),
          '',
        );
        if (open && !w.openAll) _emitItems('#mates', AssemblyRowKind.mate, w);
      }
      final patterns = t.patterns;
      if (patterns != null && patterns.count > 0) {
        final open = w.isOpen('#patterns');
        w.add(
          AssemblyTreeRow(
            key: '#patterns',
            kind: AssemblyRowKind.patternsFolder,
            depth: 1,
            label: 'Patterns',
            state: AssemblyRowState.none,
            expandable: true,
            open: open,
            count: patterns.count,
          ),
          '',
        );
        if (open && !w.openAll) _emitItems('#patterns', AssemblyRowKind.pattern, w);
      }
    }
    _emitTail('', 1, w);
    return w.rows;
  }

  void _emitLevel(List<Object> items, int depth, String parentKey, _Walk w) {
    for (final item in items) {
      if (item is _G) {
        _emitGroup(item, depth, parentKey, w);
      } else {
        _emitNode(item as _N, depth, parentKey, w);
      }
    }
  }

  void _emitNode(_N n, int depth, String parentKey, _Walk w) {
    final d = n.dto;
    final expandable = _canOpen(n) || (_liveIn(w) && _live!.key == n.key);
    final open = expandable && w.isOpen(n.key);
    AssemblyBubble? bubble;
    if (expandable) {
      bubble = open
          ? _bubbleFrom(d.mates?.broken ?? 0, d.mates?.near ?? 0, 0)
          : _bubbleFrom(_problemErrors(d.problems), d.problems?.near ?? 0, n.unsavedBelow);
    }
    final shown = w.add(
      AssemblyTreeRow(
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
        hidden: d.hidden || _sessionHidden.contains(n.key),
        suppressed: d.suppressed,
        statusFailed: d.statusFailed,
      ),
      parentKey,
      fixed: d.fixed,
    );
    if (!shown || !open) return;
    _emitLevel(w.grouping ? n.layout : n.children, depth + 1, n.key, w);
    _emitTail(n.key, depth + 1, w);
  }

  void _emitGroup(_G g, int depth, String parentKey, _Walk w) {
    final open = w.isOpen(g.key);
    final live = [
      for (final m in g.members)
        if (!m.dto.suppressed) m
    ];
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
      hidden = hidden && (m.dto.hidden || _sessionHidden.contains(m.key));
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
    final shown = w.add(
      AssemblyTreeRow(
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
      ),
      parentKey,
    );
    if (!shown || !open) return;
    for (final m in g.members) {
      _emitNode(m, depth + 1, g.key, w);
    }
  }

  void _emitItems(String folderKey, AssemblyRowKind kind, _Walk w) {
    final items = _folderItems[folderKey];
    if (items == null) return;
    for (final it in items) {
      w.add(
        AssemblyTreeRow(
          key: '$folderKey#item:${it.id}',
          kind: kind,
          depth: 2,
          label: it.label,
          state: AssemblyRowState.none,
          suppressed: it.suppressed,
          itemId: it.id,
          note: it.note,
          tone: it.tone,
        ),
        folderKey,
      );
    }
  }

  /// What follows a row's occurrences: the live row's folders and features (spec section 13), else the features fetched for it.
  /// Whether [w] lists the live part: shown, or the restore walk over a hidden one.
  bool _liveIn(_Walk w) => w.liveHidden ? _liveDataValid : _liveValid;

  void _emitTail(String ownerKey, int depth, _Walk w) {
    if (_liveIn(w) && _live!.key == ownerKey) {
      _emitLive(ownerKey, depth, w);
    } else {
      _emitFeatures(ownerKey, depth, w);
    }
  }

  void _emitLive(String k, int depth, _Walk w) {
    final l = _live!;
    AssemblyTreeRow item(String key, AssemblyRowKind kind, int d, AssemblyLiveItem it) => AssemblyTreeRow(
          key: key,
          kind: kind,
          live: true,
          depth: d,
          label: it.label,
          state: it.hidden ? AssemblyRowState.hidden : AssemblyRowState.none,
          hidden: it.hidden,
          itemId: it.id,
        );
    AssemblyTreeRow feature(String key, int d, AssemblyLiveFeature f) => AssemblyTreeRow(
          key: key,
          kind: AssemblyRowKind.feature,
          live: true,
          depth: d,
          label: f.label,
          state: f.state,
          lostReason: f.lostReference,
          hidden: f.hidden,
          featureId: f.id,
          type: f.type,
        );
    // The folders in order; Planes always, the others only with something in them.
    final folders = [
      ('bodies', 'Bodies', AssemblyRowKind.bodiesFolder, l.bodies.length),
      ('planes', 'Planes', AssemblyRowKind.planesFolder, 3 + l.planeFeatures.length),
      ('surfaces', 'Surfaces', AssemblyRowKind.surfacesFolder, l.surfaces.length),
      ('curves', 'Curves', AssemblyRowKind.curvesFolder, l.curves.length),
    ];
    for (final (name, label, kind, count) in folders) {
      if (count == 0) continue;
      final fkey = '$k#$name';
      final open = w.isOpen(fkey);
      final shown = w.add(
        AssemblyTreeRow(
          key: fkey,
          kind: kind,
          live: true,
          depth: depth,
          label: label,
          state: AssemblyRowState.none,
          expandable: true,
          open: open,
          count: count,
        ),
        k,
      );
      if (!shown || !open) continue;
      switch (name) {
        case 'planes':
          const planes = [('xy', 'XY plane'), ('xz', 'XZ plane'), ('yz', 'YZ plane')];
          for (final (id, plabel) in planes) {
            w.add(item('$k#plane:$id', AssemblyRowKind.defaultPlane, depth + 1, AssemblyLiveItem(id, plabel, hidden: l.hiddenDefaultPlanes.contains(id))), fkey);
          }
          for (final f in l.planeFeatures) {
            w.add(feature('$k#plane:feature:${f.id}', depth + 1, f), fkey);
          }
        case 'bodies':
          for (final it in l.bodies) {
            w.add(item('$k#body:${it.id}', AssemblyRowKind.body, depth + 1, it), fkey);
          }
        case 'surfaces':
          for (final it in l.surfaces) {
            w.add(item('$k#surface:${it.id}', AssemblyRowKind.surface, depth + 1, it), fkey);
          }
        default:
          for (final it in l.curves) {
            w.add(item('$k#curve:${it.id}', AssemblyRowKind.curve, depth + 1, it), fkey);
          }
      }
    }
    for (final f in l.features) {
      w.add(feature('$k#feature:${f.id}', depth, f), k);
    }
  }

  void _emitFeatures(String ownerKey, int depth, _Walk w) {
    final fs = _features[ownerKey];
    if (fs == null) return;
    for (final f in fs) {
      w.add(
        AssemblyTreeRow(
          key: '$ownerKey#feature:${f.id}',
          kind: AssemblyRowKind.feature,
          depth: depth,
          label: f.label,
          state: AssemblyRowState.none,
          featureId: f.id,
        ),
        ownerKey,
      );
    }
  }
}
