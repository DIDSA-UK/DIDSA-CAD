import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/override_stack.dart';

void main() {
  group('OverrideStack', () {
    test('starts empty: current is null, not active, depth 0', () {
      final stack = OverrideStack<String>();
      expect(stack.current, isNull);
      expect(stack.isActive, isFalse);
      expect(stack.depth, 0);
    });

    test('a single push makes it the current value and marks active', () {
      final stack = OverrideStack<String>();
      stack.push('bodies-only');
      expect(stack.current, 'bodies-only');
      expect(stack.isActive, isTrue);
      expect(stack.depth, 1);
    });

    test('popping the only push restores the empty state', () {
      final stack = OverrideStack<String>();
      stack.push('bodies-only');
      final popped = stack.pop();
      expect(popped, 'bodies-only');
      expect(stack.current, isNull);
      expect(stack.isActive, isFalse);
      expect(stack.depth, 0);
    });

    test('popping an empty stack is a safe no-op and returns null', () {
      final stack = OverrideStack<String>();
      expect(stack.pop(), isNull);
      expect(stack.isActive, isFalse);
    });

    test('nested pushes: current is always the most recent push', () {
      final stack = OverrideStack<int>();
      stack.push(1);
      stack.push(2);
      stack.push(3);
      expect(stack.current, 3);
      expect(stack.depth, 3);
    });

    test('popping restores exactly what was active before the last push, in order', () {
      final stack = OverrideStack<int>();
      stack.push(1);
      stack.push(2);
      stack.push(3);

      expect(stack.pop(), 3);
      expect(stack.current, 2);

      expect(stack.pop(), 2);
      expect(stack.current, 1);

      expect(stack.pop(), 1);
      expect(stack.current, isNull);
      expect(stack.isActive, isFalse);
    });

    test('clear empties the stack regardless of depth', () {
      final stack = OverrideStack<int>();
      stack.push(1);
      stack.push(2);
      stack.clear();
      expect(stack.isActive, isFalse);
      expect(stack.depth, 0);
    });

    test('push/pop/push again after fully draining works like a fresh stack', () {
      final stack = OverrideStack<String>();
      stack.push('a');
      stack.pop();
      stack.push('b');
      expect(stack.current, 'b');
      expect(stack.depth, 1);
    });

    test('is generic - works with a non-primitive value type', () {
      final stack = OverrideStack<List<int>>();
      stack.push([1, 2, 3]);
      expect(stack.current, [1, 2, 3]);
    });
  });
}
