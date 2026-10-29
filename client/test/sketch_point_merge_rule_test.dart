import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/point_merge_rule.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same cases as the backend's `test_sketch_point_merge.py` kept-point tests: anchored, then most constraints, then selection order.
void main() {
  const noLines = <String, (String, String)>{};

  test('a pinned Point is kept even when listed second', () {
    final order = mergeKeepOrder(pointIds: ['loose', 'pinned'], anchoredIds: {'pinned'}, constraints: const [], lineEnds: noLines);
    expect(order, ['pinned', 'loose']);
  });

  test('a tie keeps the first selected Point', () {
    expect(mergeKeepOrder(pointIds: ['b', 'a'], anchoredIds: {}, constraints: const [], lineEnds: noLines), ['b', 'a']);
  });

  test('the Point with more constraints is kept whatever the order', () {
    const constraints = [
      HorizontalConstraintDto(id: 'h', lineId: 'l', pointAId: 'corner', pointBId: 'far'),
      VerticalConstraintDto(id: 'v', lineId: 'm', pointAId: 'corner', pointBId: 'up'),
    ];
    expect(mergeKeepOrder(pointIds: ['loose', 'corner'], anchoredIds: {}, constraints: constraints, lineEnds: noLines).first, 'corner');
    expect(mergeKeepOrder(pointIds: ['corner', 'loose'], anchoredIds: {}, constraints: constraints, lineEnds: noLines).first, 'corner');
  });

  test('a provisional dimension and a Coincident between the pair are not counted', () {
    const constraints = [
      DistanceConstraintDto(id: 'd', pointAId: 'a', pointBId: 'x', distance: 7, provisional: true),
      CoincidentConstraintDto(id: 'c', pointAId: 'a', pointBId: 'b'),
    ];
    // Neither counts, so it is a tie and the first selected stays.
    expect(mergeKeepOrder(pointIds: ['b', 'a'], anchoredIds: {}, constraints: constraints, lineEnds: noLines).first, 'b');
    expect(mergeKeepOrder(pointIds: ['a', 'b'], anchoredIds: {}, constraints: constraints, lineEnds: noLines).first, 'a');
    // A real dimension on b does count.
    final withReal = [...constraints, const DistanceConstraintDto(id: 'd2', pointAId: 'b', pointBId: 'y', distance: 9)];
    expect(mergeKeepOrder(pointIds: ['a', 'b'], anchoredIds: {}, constraints: withReal, lineEnds: noLines).first, 'b');
  });

  test('a line-pair constraint counts for the ends of its lines', () {
    const constraints = [ParallelConstraintDto(id: 'p', line1Id: 'l1', line2Id: 'l2')];
    const lineEnds = {'l1': ('s1', 'e1'), 'l2': ('s2', 'e2')};
    expect(mergeKeepOrder(pointIds: ['free', 'e1'], anchoredIds: {}, constraints: constraints, lineEnds: lineEnds).first, 'e1');
  });
}
