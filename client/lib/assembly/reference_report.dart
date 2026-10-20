import 'file_lookup_rule.dart';

/// What opening an assembly found out about one reference whose file was not simply where the path said
/// (`docs/moved-files-scope.md` sections 2 and 4).
enum ReferenceOutcome {
  /// Found by its id in a new place: used, and the corrected path is an unsaved change.
  movedById,

  /// Several files carry the id: nothing is loaded until the user picks one.
  ask,

  /// A file with the same name (or a file at the path with another id) is offered, never used without a click.
  suggest,

  /// Nothing found: unresolved, with Locate...
  missing,
}

class ReferenceReport {
  const ReferenceReport({
    required this.parentPartId,
    required this.parentPath,
    required this.occurrenceId,
    required this.requestedPath,
    required this.storedPartId,
    required this.outcome,
    this.foundPath,
    this.candidates = const [],
    this.pathMismatch = false,
    this.staleCopy = false,
  });

  /// The session Part that holds the Occurrence, and the file that Part came from.
  final String parentPartId;
  final String parentPath;
  final String occurrenceId;

  /// The path the file stored (`external_ref`), and the Part id it placed there (null for an older reference).
  final String requestedPath;
  final String? storedPartId;
  final ReferenceOutcome outcome;

  /// [ReferenceOutcome.movedById]: where it was found.
  final String? foundPath;

  /// [ReferenceOutcome.ask] / [ReferenceOutcome.suggest]: the files to choose from.
  final List<String> candidates;

  /// A file is at [requestedPath] but is not the placed part (another id).
  final bool pathMismatch;

  /// The file could not be read live, so the last cached copy is loaded in its place (marked stale).
  final bool staleCopy;

  /// True when the user has something to decide; a reference found by id needs nothing.
  bool get needsYou => outcome != ReferenceOutcome.movedById;

  /// The file name the reference was placed under, for display.
  String get fileName {
    final normalised = requestedPath.replaceAll(r'\', '/');
    return normalised.substring(normalised.lastIndexOf('/') + 1);
  }

  static ReferenceOutcome outcomeOf(LookupResult result) => switch (result) {
        LookupResult.found => ReferenceOutcome.movedById,
        LookupResult.ask => ReferenceOutcome.ask,
        LookupResult.suggest => ReferenceOutcome.suggest,
        LookupResult.missing => ReferenceOutcome.missing,
      };
}

/// "2 files were found in new places, 1 needs you" - the banner's text, or null when there is nothing to say.
String? referenceSummary(List<ReferenceReport> reports) {
  final moved = reports.where((r) => !r.needsYou).length;
  final open = reports.length - moved;
  if (moved == 0 && open == 0) return null;
  final parts = <String>[
    if (moved > 0) '$moved ${moved == 1 ? 'file was' : 'files were'} found in new places',
    if (open > 0) '$open ${open == 1 ? 'needs' : 'need'} you',
  ];
  return parts.join(', ');
}
