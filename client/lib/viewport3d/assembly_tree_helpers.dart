import 'package:material_ui/material_ui.dart';

import '../api/document_api_client.dart';
import '../assembly/assembly_tree_model.dart' show AssemblyFolderItem, AssemblyItemTone, AssemblyTreeModel, AssemblyTreeNaming;
import '../assembly/occurrence_visibility.dart' show topLevelOccurrenceId;
import 'mate_panel.dart' show mateValueSummary;
import 'mate_reference_state.dart';
import 'width_pick.dart' show isSymmetricMate, isWidthMate;

// The pure helpers the Assembly tree's callers share (names, rigid-set text, mate and pattern labels). They used to live in
// `assembly_tree_panel.dart`; A4 of `docs/assembly-tree-overhaul-scope.md` moved them here when the old panel was removed.

/// Display names for [occurrences], a list of siblings (one Part's own Occurrences), by the spec's rules
/// (`docs/assembly-tree/spec.md` section 3), through [AssemblyTreeNaming]: the name the user gave, else the file name when a
/// person chose it (not a UUID or a run of hex), else `Component N` (N = the position among the siblings); a Part placed more than
/// once among them reads `Bolt <2>`. A renamed one is never numbered and is not counted. The tree itself names its rows in
/// `AssemblyTreeModel` with the same rules (and also knows the Part's own name, which an [OccurrenceDto] does not carry); where a
/// tree is loaded, prefer its label.
List<String> occurrenceDisplayNameList(List<OccurrenceDto> occurrences) {
  final cached = _nameCache;
  if (cached != null && identical(cached.$1, occurrences) && cached.$2.length == occurrences.length) return cached.$2;
  String? instanceKey(OccurrenceDto o) => o.resolvedPartId != null ? 'p:${o.resolvedPartId}' : (o.externalRef == null ? null : 'f:${o.externalRef}');
  final groups = <String, List<OccurrenceDto>>{};
  for (final o in occurrences) {
    if (AssemblyTreeNaming.hasOverride(o.nameOverride)) continue;
    final k = instanceKey(o);
    if (k != null) (groups[k] ??= []).add(o);
  }
  final bases = <String, String?>{};
  for (final e in groups.entries) {
    String? base;
    for (final m in e.value) {
      final f = AssemblyTreeNaming.fileBaseName(m.externalRef);
      if (!AssemblyTreeNaming.looksGenerated(f)) {
        base = f;
        break;
      }
    }
    bases[e.key] = base;
  }
  final numbered = <String, int>{};
  final names = <String>[];
  for (var i = 0; i < occurrences.length; i++) {
    final o = occurrences[i];
    if (AssemblyTreeNaming.hasOverride(o.nameOverride)) {
      names.add(o.nameOverride!);
      continue;
    }
    final k = instanceKey(o);
    final base = k == null ? null : bases[k];
    if (base == null) {
      names.add('Component ${i + 1}');
    } else if (groups[k]!.length >= 2) {
      final next = (numbered[k!] ?? 0) + 1;
      numbered[k] = next;
      names.add('$base <$next>');
    } else {
      names.add(base);
    }
  }
  _nameCache = (occurrences, names);
  return names;
}

(List<OccurrenceDto>, List<String>)? _nameCache;

/// The display name for the Occurrence at [index] in [occurrences] (see [occurrenceDisplayNameList]). Shared by the tree's own rows'
/// fallback and everywhere else that has to name a component the same way.
String occurrenceDisplayName(List<OccurrenceDto> occurrences, int index) => occurrenceDisplayNameList(occurrences)[index];

/// A generated id (a UUID, `part-<hex>`) is not a name a person chose: the spec's rule, [AssemblyTreeNaming.looksGenerated].
bool looksGeneratedName(String name) => AssemblyTreeNaming.looksGenerated(name);

/// Default width fraction of the Assembly tree when it floats over the viewport (the old panel's default, kept): 66% on a portrait phone
/// (shorter side < 600 logical px and taller than wide), 40% everywhere else.
double assemblyTreeDefaultWidthFraction(Size screenSize) => isPhonePortrait(screenSize) ? 0.66 : 0.4;

/// A phone held upright: narrower than 600 logical px and taller than wide. B4: the phone layout draws the tree as a bottom sheet then;
/// landscape and tablets keep the side panel.
bool isPhonePortrait(Size screenSize) => screenSize.width < 600 && screenSize.height > screenSize.width;

/// M5: the occurrence ids of every member of rigid set [setId] (`ConstraintStatusDto.rigidSet`), in the order [occurrences] lists them.
List<String> rigidSetMemberIds(List<OccurrenceDto> occurrences, Map<String, ConstraintStatusDto> status, String setId) =>
    [for (final o in occurrences) if (status[o.id]?.rigidSet == setId) o.id];

/// M5: what an occurrence's row says about its rigid set, or null when it is in none. The set's lead (the occurrence named by the set id) reads
/// "Moves with N other part(s)"; every other member "Moves with" and the lead's name. Parts the mates lock together move as one: dragging any of them moves
/// the set, and this is the answer to "why did that other part move?".
String? rigidSetSubtitle(List<OccurrenceDto> occurrences, Map<String, ConstraintStatusDto> status, int index) {
  final id = occurrences[index].id;
  final setId = status[id]?.rigidSet;
  if (setId == null) return null;
  if (setId == id) {
    final others = rigidSetMemberIds(occurrences, status, setId).length - 1;
    if (others < 1) return null;
    return 'Moves with $others other part${others == 1 ? '' : 's'}';
  }
  final lead = occurrences.indexWhere((o) => o.id == setId);
  return lead < 0 ? 'Moves as one with other parts' : 'Moves with ${occurrenceDisplayName(occurrences, lead)}';
}

/// M5: a colour for the bracket on the left of every row of rigid set [setId]: one per set, by the set's place among the sets listed
/// (sorted by id so it does not change as parts are hidden or reordered).
Color rigidSetBracketColour(Map<String, ConstraintStatusDto> status, String setId) {
  const palette = <Color>[Color(0xFF1E88E5), Color(0xFFF4511E), Color(0xFF43A047), Color(0xFF8E24AA), Color(0xFFFDD835), Color(0xFF00ACC1)];
  final ids = <String>{for (final s in status.values) if (s.rigidSet != null) s.rigidSet!}.toList()..sort();
  final at = ids.indexOf(setId);
  return palette[(at < 0 ? 0 : at) % palette.length];
}

/// M5: the sentence shown when a drag grabs a member of a rigid set ([grabbedId]); null when it is in none (or alone).
String? rigidSetGrabNotice(List<OccurrenceDto> occurrences, Map<String, ConstraintStatusDto> status, String grabbedId) {
  final setId = status[grabbedId]?.rigidSet;
  if (setId == null) return null;
  final names = <String>[
    for (var i = 0; i < occurrences.length; i++)
      if (occurrences[i].id != grabbedId && status[occurrences[i].id]?.rigidSet == setId) occurrenceDisplayName(occurrences, i),
  ];
  if (names.isEmpty) return null;
  final shown = names.length > 3 ? '${names.take(3).join(', ')} and ${names.length - 3} more' : names.join(', ');
  return 'Moves as one with $shown: the mates lock them together.';
}

/// B4: the name of the instance at `path` (an occurrence id, a `/`-joined nested path, or a pattern copy
/// `<src>#pattern:<pid>:<i>`): a copy reads `Source [Linear 1 #2]`, a nested path shows its last segment's name.
/// Segments that cannot be resolved fall back to the raw segment.
String occurrencePathDisplayName(
  String path,
  List<OccurrenceDto> occurrences, {
  List<ComponentPatternDto> patterns = const [],
}) {
  final last = path.split('/').last;
  final marker = last.indexOf('#pattern:');
  final sourceId = marker < 0 ? last : last.substring(0, marker);
  final index = occurrences.indexWhere((o) => o.id == sourceId);
  final base = index < 0 ? sourceId : occurrenceDisplayName(occurrences, index);
  if (marker < 0) return base;
  final rest = last.substring(marker + '#pattern:'.length);
  final colon = rest.lastIndexOf(':');
  if (colon < 0) return base;
  final patternId = rest.substring(0, colon);
  final copyIndex = int.tryParse(rest.substring(colon + 1));
  final patternPosition = patterns.indexWhere((p) => p.id == patternId);
  final patternName = patternPosition < 0 ? 'Pattern' : componentPatternDisplayName(patterns, patternPosition);
  return copyIndex == null ? '$base [$patternName]' : '$base [$patternName #${copyIndex + 1}]';
}

/// Occurrence id -> [occurrenceDisplayName] for every occurrence: the map the selection drawers / "select other" sheet
/// read, merged into the same `bodyNames` map the Bodies use, so a component is called the same thing everywhere.
Map<String, String> occurrenceDisplayNames(
  List<OccurrenceDto> occurrences, {
  List<ComponentPatternDto> patterns = const [],
  Iterable<String> extraPaths = const [],
}) =>
    {
      for (var i = 0; i < occurrences.length; i++) occurrences[i].id: occurrenceDisplayName(occurrences, i),
      // Every other instance path (pattern copies, nested occurrences) so no consumer falls back to "Body".
      for (final path in extraPaths)
        if (!occurrences.any((o) => o.id == path)) path: occurrencePathDisplayName(path, occurrences, patterns: patterns),
    };

/// The display name for the ComponentPattern at [index] in [patterns] -
/// mirrors [mateDisplayName]'s own "Type N" convention (a
/// [ComponentPatternDto] has no user-chosen name field of its own either),
/// plus a short parameter summary so two patterns of the same type are
/// distinguishable at a glance without opening anything.
String componentPatternDisplayName(List<ComponentPatternDto> patterns, int index) {
  final pattern = patterns[index];
  final label = switch (pattern.patternType) {
    'linear' => 'Linear',
    'circular' => 'Circular',
    _ => pattern.patternType,
  };
  final ordinal = patterns.take(index + 1).where((p) => p.patternType == pattern.patternType).length;
  return '$label $ordinal';
}

/// A short summary of [pattern]'s own instance count, shown as a
/// [componentPatternDisplayName] row's subtitle - "×3" for a 3-instance
/// Linear pattern, "×4 (270°)" for a Circular one swept less than a full
/// turn (the common, expected 360° case omits the redundant angle).
String componentPatternSummary(ComponentPatternDto pattern) {
  if (pattern.patternType == 'circular') {
    final angleSuffix = pattern.angleTotal == 360.0 ? '' : ' (${pattern.angleTotal.toStringAsFixed(0)}°)';
    return '×${pattern.countAngular}$angleSuffix';
  }
  return '×${pattern.count}';
}

/// The subtitle of a broken mate's row (the Assembly tree).
const String kBrokenMateText = "Broken - can't be satisfied";

/// B1: what the tooltip of a `near` mate says it means.
const String kNearMateTooltip =
    'These mates over-define the part and disagree by this much. Remove one, or make the geometry exact.';

/// B1: "Within tolerance: 0.006 mm / 0.0002°" for a `near` mate (the backend's `status_residual_mm` / `status_residual_deg`).
String nearMateText(MateDto mate) {
  String fmt(double? v, int digits) {
    if (v == null) return '?';
    final s = v.toStringAsFixed(digits);
    return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
  }

  return 'Within tolerance: ${fmt(mate.statusResidualMm, 3)} mm / ${fmt(mate.statusResidualDeg, 4)}°';
}

/// B1: true when [occurrenceId] is over-constrained only by `near` mates: it has at least one, and none of the mates that touch
/// it (by their top-level occurrence) is broken. Its constraint badge is then amber instead of red.
bool occurrenceConflictsAreAllNear(List<MateDto> mates, String occurrenceId) {
  var near = 0;
  for (final mate in mates) {
    if (mate.suppressed) continue;
    final touches = mate.references.any((r) => topLevelOccurrenceId(r.occurrenceId) == occurrenceId);
    if (!touches) continue;
    if (mate.isBroken) return false;
    if (mate.isNear) near++;
  }
  return near > 0;
}

/// The display name for the Mate at [index] in [mates] - mirrors
/// [occurrenceDisplayName]/`featureDisplayName`'s "Type N" convention
/// (ordinal counts only same-type mates up to and including [index]), since a
/// [MateDto] has no user-chosen name field of its own (unlike
/// [OccurrenceDto.nameOverride]).
String mateDisplayName(List<MateDto> mates, int index) {
  final mate = mates[index];
  // A Width mate (mid-plane references) is listed as "Width N", counted apart from the plain coincident / distance mates.
  if (isSymmetricMate(mate)) {
    return 'Symmetric ${mates.take(index + 1).where(isSymmetricMate).length}';
  }
  if (isWidthMate(mate)) {
    return 'Width ${mates.take(index + 1).where(isWidthMate).length}';
  }
  final label = switch (mate.type) {
    'coincident' => 'Coincident',
    'concentric' => 'Concentric',
    'parallel' => 'Parallel',
    'distance' => 'Distance',
    'angle' => 'Angle',
    'gear' => 'Gear',
    'rack_pinion' => 'Rack and pinion',
    'screw' => 'Screw',
    'limit_distance' => 'Limit distance',
    'limit_angle' => 'Limit angle',
    _ => mate.type,
  };
  final ordinal = mates.take(index + 1).where((m) => m.type == mate.type && !isWidthMate(m) && !isSymmetricMate(m)).length;
  return '$label $ordinal';
}

// ----- Building and patching tree responses (A4) -----

/// A copy of [n] with some fields changed. [clearConstraint] drops the constraint (a state that is not known any more reads as absent,
/// not as the old one); [children] replaces the subtree.
AssemblyTreeNodeDto copyAssemblyTreeNode(
  AssemblyTreeNodeDto n, {
  bool? fixed,
  bool? hidden,
  bool clearConstraint = false,
  List<AssemblyTreeNodeDto>? children,
}) =>
    AssemblyTreeNodeDto(
      occurrenceId: n.occurrenceId,
      path: n.path,
      externalRef: n.externalRef,
      refPartId: n.refPartId,
      resolvedPartId: n.resolvedPartId,
      partName: n.partName,
      nameOverride: n.nameOverride,
      kind: n.kind,
      fixed: fixed ?? n.fixed,
      hidden: hidden ?? n.hidden,
      suppressed: n.suppressed,
      color: n.color,
      constraint: clearConstraint ? null : n.constraint,
      featureCount: n.featureCount,
      placements: n.placements,
      cycle: n.cycle,
      truncated: n.truncated,
      statusFailed: n.statusFailed,
      mates: n.mates,
      patterns: n.patterns,
      problems: n.problems,
      children: children ?? n.children,
    );

/// [tree] with the node at [path] replaced by [update] of it. Only the nodes along the path are new; the rest are shared. [tree] itself
/// when the path names no node.
AssemblyTreeResponseDto assemblyTreeWithNode(
  AssemblyTreeResponseDto tree,
  List<String> path,
  AssemblyTreeNodeDto Function(AssemblyTreeNodeDto node) update,
) {
  List<AssemblyTreeNodeDto>? rebuild(List<AssemblyTreeNodeDto> level, int depth) {
    for (var i = 0; i < level.length; i++) {
      final n = level[i];
      if (n.occurrenceId != path[depth]) continue;
      final AssemblyTreeNodeDto replaced;
      if (depth == path.length - 1) {
        replaced = update(n);
      } else {
        final below = rebuild(n.children, depth + 1);
        if (below == null) return null;
        replaced = copyAssemblyTreeNode(n, children: below);
      }
      return [...level.sublist(0, i), replaced, ...level.sublist(i + 1)];
    }
    return null;
  }

  if (path.isEmpty) return tree;
  final children = rebuild(tree.children, 0);
  if (children == null) return tree;
  return AssemblyTreeResponseDto(
    partId: tree.partId,
    partName: tree.partName,
    kind: tree.kind,
    featureCount: tree.featureCount,
    statusIncluded: tree.statusIncluded,
    mates: tree.mates,
    patterns: tree.patterns,
    problems: tree.problems,
    children: children,
    truncated: tree.truncated,
    nodeCount: tree.nodeCount,
    maxDepth: tree.maxDepth,
    maxNodes: tree.maxNodes,
    truncatedDepth: tree.truncatedDepth,
    truncatedNodes: tree.truncatedNodes,
    statusFailed: tree.statusFailed,
    statusIncomplete: tree.statusIncomplete,
  );
}

/// One level of a tree from the flat lists a backend without `GET /parts/{id}/assembly-tree` still answers (`/occurrences`, `/mates`,
/// `/component-patterns`): no nesting, no status. Only used when the endpoint is missing, so the tree still shows the components.
AssemblyTreeResponseDto assemblyTreeFromLists({
  required String partId,
  required String partName,
  required List<OccurrenceDto> occurrences,
  required List<MateDto> mates,
  required List<ComponentPatternDto> patterns,
}) {
  final placements = <String, int>{};
  for (final o in occurrences) {
    final k = o.resolvedPartId ?? o.externalRef;
    if (k != null) placements[k] = (placements[k] ?? 0) + 1;
  }
  return AssemblyTreeResponseDto(
    partId: partId,
    partName: partName,
    kind: occurrences.isEmpty ? 'part' : 'assembly',
    mates: mates.isEmpty ? null : AssemblyTreeMatesDto(count: mates.length),
    patterns: patterns.isEmpty ? null : AssemblyTreePatternsDto(count: patterns.length),
    nodeCount: occurrences.length,
    children: [
      for (final o in occurrences)
        AssemblyTreeNodeDto(
          occurrenceId: o.id,
          path: [o.id],
          externalRef: o.externalRef,
          resolvedPartId: o.resolvedPartId,
          nameOverride: o.nameOverride,
          kind: o.resolvedPartId == null ? 'missing' : 'part',
          fixed: o.fixed,
          hidden: o.hidden,
          suppressed: o.suppressed,
          color: o.color,
          placements: (o.resolvedPartId ?? o.externalRef) == null ? null : placements[o.resolvedPartId ?? o.externalRef],
        ),
    ],
  );
}

/// The per-occurrence constraint status of the tree's top level, in the shape `constraint-status` has (what the rest of the screen reads:
/// the grab notice of a rigid set). Empty without status.
Map<String, ConstraintStatusDto> topLevelConstraintStatus(AssemblyTreeResponseDto tree) => constraintStatusOfChildren(tree.children);

/// [topLevelConstraintStatus] for any level (B3: the tree keeps the whole assembly while a level is focused, and the screen's own map is the
/// focused level's): the status of each of [children] that has one, by occurrence id.
Map<String, ConstraintStatusDto> constraintStatusOfChildren(Iterable<AssemblyTreeNodeDto> children) => {
      for (final n in children)
        if (n.constraint != null) n.occurrenceId: ConstraintStatusDto(state: n.constraint!.status, dof: n.constraint!.dof, rigidSet: n.constraint!.rigidSet),
    };

/// The rows under the tree's Mates folder: what the old panel's mate tiles said, as one row each (a title and a note). A broken mate is
/// red, a `near` one amber, a lost face red, a held one amber (check this mate), a followed reference an info line; a suppressed one is dimmed.
List<AssemblyFolderItem> mateFolderItems(List<MateDto> mates) {
  final items = <AssemblyFolderItem>[];
  for (var i = 0; i < mates.length; i++) {
    final mate = mates[i];
    // The backend computes broken (`MateDto.status`); a suppressed mate is never broken (it says `ok`).
    final broken = mate.isBroken && !mate.suppressed;
    final near = mate.isNear && !mate.suppressed;
    final summary = mateValueSummary(mate);
    final refNote = mateReferenceNote(mate);
    final lost = refNote.kind == MateReferenceKind.lost;
    final held = refNote.kind == MateReferenceKind.held;
    final followed = refNote.kind == MateReferenceKind.followed;
    // A held mate reads amber even when the backend also reports it `broken` (the part still sits on the old face): that is the very
    // state "check this mate" is about, and Confirm is its way out. Only a lost face is red.
    final AssemblyItemTone? tone = lost
        ? AssemblyItemTone.error
        : held
            ? AssemblyItemTone.warning
            : broken
                ? AssemblyItemTone.error
                : near
                    ? AssemblyItemTone.warning
                    : followed
                        ? AssemblyItemTone.info
                        : null;
    String? join(String text) => summary == null ? text : '$text · $summary';
    final String? note = lost || held
        ? join(refNote.text)
        : broken
            ? join(kBrokenMateText)
            : near
                ? join(nearMateText(mate))
                : followed
                    ? join(refNote.text)
                    : summary;
    items.add(AssemblyFolderItem(mate.id, mateDisplayName(mates, i), note: note, tone: tone, suppressed: mate.suppressed));
  }
  return items;
}

/// The rows under the tree's Patterns folder.
List<AssemblyFolderItem> patternFolderItems(List<ComponentPatternDto> patterns) => [
      for (var i = 0; i < patterns.length; i++)
        AssemblyFolderItem(patterns[i].id, componentPatternDisplayName(patterns, i),
            note: componentPatternSummary(patterns[i]), suppressed: patterns[i].suppressed),
    ];

/// What the seeded tree of a part opened alone (its root only, P2) does with the rows [stored] for its document: whether there is anything to
/// restore, and whether that is all of [stored] (otherwise the seed is provisional until a real tree answer). The root's folders are not rows
/// until the model's live part is set (the part's features or mesh still on their way): while it is not, they count as restorable, since the
/// host opens them when it is set (P2 review: a stored list of only those must still be restored).
({bool restore, bool complete}) seededTreeRestore(AssemblyTreeModel model, List<String>? stored) {
  if (stored == null || stored.isEmpty) return (restore: false, complete: true);
  final keys = model.restoreOpenKeys(stored);
  final waitingFolders =
      model.livePart == null ? stored.where(const {'#bodies', '#planes', '#surfaces', '#curves'}.contains).length : 0;
  return (restore: keys.isNotEmpty || waitingFolders > 0, complete: keys.length + waitingFolders == stored.length);
}
