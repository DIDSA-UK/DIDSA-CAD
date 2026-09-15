import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/focus_stack.dart';

void main() {
  group('AssemblyFocusStack', () {
    test('starts focused on the root Part, not focused past it, depth 0', () {
      final stack = AssemblyFocusStack('root');
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.depth, 0);
    });

    test('pushing a Part id makes it current and marks focused', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bolt');
      expect(stack.current, 'bolt');
      expect(stack.isFocused, isTrue);
      expect(stack.depth, 1);
    });

    test('popping the only push restores the root Part', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bolt');
      final popped = stack.pop();
      expect(popped, 'bolt');
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.depth, 0);
    });

    test('popping at the root is a safe no-op and never pops the root away', () {
      final stack = AssemblyFocusStack('root');
      expect(stack.pop(), isNull);
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
    });

    test('nested focus: current is always the most recently focused Part', () {
      final stack = AssemblyFocusStack('root');
      stack.push('bracket');
      stack.push('bolt');
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
      stack.push('bracket');
      stack.push('bolt');
      stack.clear();
      expect(stack.current, 'root');
      expect(stack.isFocused, isFalse);
      expect(stack.depth, 0);
    });
  });
}
