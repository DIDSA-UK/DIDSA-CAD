/// A generic push/pop stack for temporarily overriding some value, with
/// popping always restoring exactly whatever was active before the
/// corresponding push - generalizes the ad hoc single-level "temporary mode,
/// Cancel restores prior state" pattern [PartScreen]'s plane-selection mode
/// (Stage 10b) and Sketch-picker mode (Prompt D) each hand-roll as a single
/// `bool` field into a reusable, nestable primitive (Prompt A2).
///
/// No Flutter dependency - a plain Dart class so it's trivially
/// unit-testable without a widget test harness, and reusable for any `T`
/// (see [PartScreen]'s `SelectionFilterState` override stack, the first
/// real user of this).
class OverrideStack<T> {
  final List<T> _stack = [];

  /// The currently active override, or null if nothing has been pushed.
  T? get current => _stack.isEmpty ? null : _stack.last;

  bool get isActive => _stack.isNotEmpty;

  int get depth => _stack.length;

  void push(T value) => _stack.add(value);

  /// Pops the most recent override, restoring whatever was active before it
  /// (the new top of the stack, or nothing if this was the last one). A
  /// no-op (returns null) if the stack is already empty - same "cancel is
  /// safe even if there's nothing to cancel" idempotence the hand-rolled
  /// `bool`-based modes this generalizes already relied on.
  T? pop() => _stack.isEmpty ? null : _stack.removeLast();

  void clear() => _stack.clear();
}
