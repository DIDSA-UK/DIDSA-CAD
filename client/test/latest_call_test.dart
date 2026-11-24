import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:didsa_cad_client/viewport3d/latest_call.dart';

void main() {
  test('a superseded call waits for the newer one and gets its error; only the newer answer would apply', () async {
    final latest = LatestCall();
    final first = Completer<int>();
    final second = Completer<int>();
    final applied = <int>[];
    final older = latest.run(() => first.future, applied.add);
    final newer = latest.run(() => second.future, applied.add);
    Object? olderError;
    final olderDone = older.catchError((Object e) => olderError = e);
    first.complete(1); // the older answer lands first: dropped, and the older call now waits for the newer
    await Future<void>.delayed(Duration.zero);
    expect(applied, isEmpty);
    second.completeError(StateError('newer failed'));
    await expectLater(newer, throwsStateError);
    await olderDone;
    expect(olderError, isA<StateError>(), reason: 'the older caller does not carry on as if its features were current');
    expect(applied, isEmpty);
  });
}
