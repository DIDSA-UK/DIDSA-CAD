import 'package:material_ui/material_ui.dart';

import '../api/document_api_client.dart';
import 'pattern_mirror_seed.dart';

/// The two tabs of the Pattern and Mirror tools (bug report 2026-11-17 items 2B / M.3): what a picked face adds to the scope.
enum SeedScopeTab {
  /// The feature that made the face (a cut's wall gives the cut). The default.
  feature,

  /// The body the face belongs to.
  body,
}

/// The scope of a Pattern or a Mirror: ONE class for both tools (item M.4), so the per-tab state, the face → feature / body rule and
/// the seed rule are written once.
///
/// Each tab keeps its own list, so switching tabs loses nothing; the request uses the active tab's list only ([seed]). A face picked on
/// the Feature tab asks the backend which feature made it ([pickFace]); on the Body tab it is its body straight away. Picking the same
/// thing again removes it. [scopeActive] says whether viewport picks go to the scope (true on opening) or to the tool's other field
/// (direction / axis / mirror plane).
class SeedScopeController extends ChangeNotifier {
  SeedScopeTab _tab = SeedScopeTab.feature;
  List<String> _featureIds = [];
  List<String> _bodyIds = [];
  bool _scopeActive = true;
  String? _pickError;

  /// Bumped by [reset]: a face-owner answer that comes back after the tool was reset (closed, reopened) is dropped.
  int _generation = 0;

  SeedScopeTab get tab => _tab;
  List<String> get featureIds => List.unmodifiable(_featureIds);
  List<String> get bodyIds => List.unmodifiable(_bodyIds);
  bool get scopeActive => _scopeActive;

  /// The last face pick that could not be resolved (the backend refused it), shown in the panel until the next pick.
  String? get pickError => _pickError;

  /// The active tab's list is empty.
  bool get isEmpty => _tab == SeedScopeTab.feature ? _featureIds.isEmpty : _bodyIds.isEmpty;

  /// Starts a session: [tab] with [features] / [bodies] already in scope, the scope field active.
  void reset({SeedScopeTab tab = SeedScopeTab.feature, List<String> features = const [], List<String> bodies = const []}) {
    _generation++;
    _tab = tab;
    _featureIds = _unique(features);
    _bodyIds = _unique(bodies);
    _scopeActive = true;
    _pickError = null;
    notifyListeners();
  }

  void setTab(SeedScopeTab tab) {
    if (tab == _tab) return;
    _tab = tab;
    _pickError = null;
    notifyListeners();
  }

  void setScopeActive(bool active) {
    if (active == _scopeActive) return;
    _scopeActive = active;
    notifyListeners();
  }

  /// The Feature tab's whole list, as the Build tree picker ("Add from Tree") leaves it.
  void setFeatures(List<String> ids) {
    _featureIds = _unique(ids);
    notifyListeners();
  }

  void toggleFeature(String id) {
    _featureIds = _featureIds.contains(id) ? [for (final f in _featureIds) if (f != id) f] : [..._featureIds, id];
    notifyListeners();
  }

  void toggleBody(String id) {
    _bodyIds = _bodyIds.contains(id) ? [for (final b in _bodyIds) if (b != id) b] : [..._bodyIds, id];
    notifyListeners();
  }

  /// Removes [id] from the active tab's list (a chip's ×).
  void remove(String id) {
    if (_tab == SeedScopeTab.feature) {
      if (_featureIds.contains(id)) toggleFeature(id);
    } else if (_bodyIds.contains(id)) {
      toggleBody(id);
    }
  }

  /// A face picked while the scope is active: on the Body tab its [bodyId] is toggled at once; on the Feature tab [featureOwner] (the
  /// backend's face → feature answer) is awaited and that feature toggled. One request per tap; an answer that arrives after a
  /// [reset] is dropped. A failed answer sets [pickError] and changes nothing.
  Future<void> pickFace({required String bodyId, required Future<String> Function() featureOwner}) async {
    _pickError = null;
    if (_tab == SeedScopeTab.body) {
      toggleBody(bodyId);
      return;
    }
    final generation = _generation;
    try {
      final owner = await featureOwner();
      if (generation != _generation) return;
      toggleFeature(owner);
    } on Object catch (e) {
      if (generation != _generation) return;
      _pickError = 'Could not tell which feature made that face: $e';
      notifyListeners();
    }
  }

  /// What the active tab's scope means for the request (`pattern_mirror_seed.dart`): the Feature tab's features split into tool
  /// features (cuts, bosses into a body) and body-making ones; the Body tab's bodies. [PatternMirrorSeed.error] when the Feature tab
  /// mixes the two kinds.
  PatternMirrorSeed seed({required List<FeatureDto> features, required bool Function(FeatureDto) isToolFeature}) {
    if (_tab == SeedScopeTab.body) return resolveSeed(bodyIds: _bodyIds, features: const [], isToolFeature: isToolFeature);
    final byId = {for (final f in features) f.id: f};
    return resolveSeed(
      bodyIds: const [],
      features: [for (final id in _featureIds) if (byId[id] != null) byId[id]!],
      isToolFeature: isToolFeature,
    );
  }

  static List<String> _unique(List<String> ids) => [...{...ids}];
}

/// One entry of the scope field: an id and the name shown on its chip (a feature's Build tree name, or a body's name).
typedef SeedScopeChip = ({String id, String label});

/// The top of the Pattern and Mirror panels (items 2B / M.3 / M.4): the **Feature | Body** tabs and the **Scope** field, the same widget
/// in both. The field says "Pick faces" while empty, else one chip per entry with a remove ×; it is highlighted while it is where
/// viewport picks go ([active]) and tapping it makes it so ([onActivate]). [error] (the seed rule refusing a mix of cuts and bodies,
/// or a failed face pick) shows under it. [onAddFromTree] adds a second way to fill the Feature tab ("Add from Tree"); it is hidden on
/// the Body tab. Keys: `$keyPrefix-tab-feature`, `$keyPrefix-tab-body`, `$keyPrefix-scope-field`.
class SeedScopeSection extends StatelessWidget {
  final String keyPrefix;
  final SeedScopeTab tab;
  final void Function(SeedScopeTab tab) onTabChanged;
  final List<SeedScopeChip> chips;
  final void Function(String id) onRemove;
  final bool active;
  final VoidCallback onActivate;
  final String? error;
  final VoidCallback? onAddFromTree;

  /// The tabs cannot change while editing a saved feature (the backend keeps its seed kind).
  final bool canChangeTab;

  const SeedScopeSection({
    super.key,
    required this.keyPrefix,
    required this.tab,
    required this.onTabChanged,
    required this.chips,
    required this.onRemove,
    required this.active,
    required this.onActivate,
    this.error,
    this.onAddFromTree,
    this.canChangeTab = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<SeedScopeTab>(
          segments: [
            ButtonSegment(value: SeedScopeTab.feature, label: Text('Feature', key: ValueKey('$keyPrefix-tab-feature'))),
            ButtonSegment(value: SeedScopeTab.body, label: Text('Body', key: ValueKey('$keyPrefix-tab-body'))),
          ],
          selected: {tab},
          onSelectionChanged: canChangeTab ? (selection) => onTabChanged(selection.first) : null,
        ),
        const SizedBox(height: 8),
        InkWell(
          key: ValueKey('$keyPrefix-scope-field'),
          onTap: onActivate,
          borderRadius: BorderRadius.circular(8),
          child: InputDecorator(
            isFocused: active,
            decoration: InputDecoration(
              labelText: 'Scope',
              border: const OutlineInputBorder(),
              isDense: true,
              helperText: active ? (tab == SeedScopeTab.feature ? 'Tap faces: each adds the feature that made it' : 'Tap faces: each adds its body') : null,
            ),
            child: chips.isEmpty
                ? Text('Pick faces', style: TextStyle(color: scheme.onSurfaceVariant))
                : Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final chip in chips)
                        InputChip(
                          key: ValueKey('$keyPrefix-scope-chip-${chip.id}'),
                          label: Text(chip.label),
                          visualDensity: VisualDensity.compact,
                          onDeleted: () => onRemove(chip.id),
                        ),
                    ],
                  ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error!,
              key: ValueKey('$keyPrefix-scope-error'),
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ),
        if (tab == SeedScopeTab.feature && onAddFromTree != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onAddFromTree,
              icon: const Icon(Icons.account_tree_outlined, size: 16),
              label: const Text('Add from Tree'),
            ),
          ),
      ],
    );
  }
}
