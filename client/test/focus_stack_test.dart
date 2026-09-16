import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/focus_stack.dart';

void main() {
  group('AssemblyFocusStack', () {
    test('starts focused on the root Part, not focused past it, depth 0', () {
      final stack = AssemblyFocusStack('root');
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.depth, 0);
      expect(stack.currentOccurrencePath, isEmpty);
    });

    test('pushing a Part id makes it current and marks focused', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bolt', 'occ-bolt', 'Bolt');
      expect(stack.current, 'bolt');
      expect(stack.isFocused, isTrue);
      expect(stack.depth, 1);
      expect(stack.currentOccurrencePath, ['occ-bolt']);
    });

    // Bug fix: `currentLabel` backs `AssemblyTreePanel`'s own breadcrumb row
    // - the only way back out of a focused Part with no Occurrences of its
    // own to long-press "Exit Focus" on.
    group('currentLabel', () {
      test('null while unfocused', () {
        final stack = AssemblyFocusStack('root');
        expect(stack.currentLabel, isNull);
      });

      test('the most recently pushed display name', () {
        final stack = AssemblyFocusStack('root');
        stack.push('bracket', 'occ-bracket', 'Bracket');
        stack.push('bolt', 'occ-bolt', 'Bolt');
        expect(stack.currentLabel, 'Bolt');
        stack.pop();
        expect(stack.currentLabel, 'Bracket');
        stack.pop();
        expect(stack.currentLabel, isNull);
      });

      test('cleared back to null by clear()', () {
        final stack = AssemblyFocusStack('root');
        stack.push('bolt', 'occ-bolt', 'Bolt');
        stack.clear();
        expect(stack.currentLabel, isNull);
      });
    });

    test('popping the only push restores the root Part', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bolt', 'occ-bolt', 'Bolt');
      final popped = stack.pop();
      expect(popped, 'bolt');
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.depth, 0);
      expect(stack.currentOccurrencePath, isEmpty);
    });

    test('popping at the root is a safe no-op and never pops the root away', () {
      final stack = AssemblyFocusStack('root');
      expect(stack.pop(), isNull);
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.currentOccurrencePath, isEmpty);
    });

    test('nested focus: current is always the most recently focused Part', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bracket', 'occ-bracket', 'Bracket');
      stack.push('bolt', 'occ-bolt', 'Bolt');
      expect(stack.current, 'bolt');
      expect(stack.depth, 2);

      expect(stack.pop(), 'bolt');
      expect(stack.current, 'bracket');

      expect(stack.pop(), 'bracket');
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
    });

    test('clear un-focuses all the way back to root regardless of depth', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bracket', 'occ-bracket', 'Bracket');
      stack.push('bolt', 'occ-bolt', 'Bolt');
      stack.clear();
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.depth, 0);
      expect(stack.currentOccurrencePath, isEmpty);
    });

    // Phase 4 fix (`docs/assembly-scope.md` §5 appendix item 4): the whole
    // point of `currentOccurrencePath` existing at all - it must record the
    // *full chain* down to the focused Occurrence, not just the most recent
    // push, so a caller can tell a nested instance apart from a genuine peer.
    group('currentOccurrencePath', () {
      test('nested focus accumulates the full chain, not just the last push', () {
        final stack = AssemblyFocusStack('root');
        stack.push('bracket', 'occ-bracket', 'Bracket');
        stack.push('bolt', 'occ-bolt', 'Bolt');
        expect(stack.currentOccurrencePath, ['occ-bracket', 'occ-bolt']);
      });

      test('popping one level removes only the last path segment', () {
        final stack = AssemblyFocusStack('root');
        stack.push('bracket', 'occ-bracket', 'Bracket');
        stack.push('bolt', 'occ-bolt', 'Bolt');
        stack.pop();
        expect(stack.currentOccurrencePath, ['occ-bracket']);
      });

      test('returns the exact same List instance across reads with no intervening push/pop/clear', () {
        // The change-detection contract this exists for
        // (`PartViewport.didUpdateWidget`'s `!=` is identity-based for a
        // List) - a fresh list on every read would defeat it.
        final stack = AssemblyFocusStack('root');
        stack.push('bracket', 'occ-bracket', 'Bracket');
        expect(identical(stack.currentOccurrencePath, stack.currentOccurrencePath), isTrue);
      });

      test('a fresh, unfocused stack always returns the same canonical empty list', () {
        final a = AssemblyFocusStack('root-a');
        final b = AssemblyFocusStack('root-b');
        expect(identical(a.currentOccurrencePath, b.currentOccurrencePath), isTrue);
      });
    });
  });
}
