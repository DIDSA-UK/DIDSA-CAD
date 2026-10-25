// Timing is reported by the suite, never a pass / fail gate on a shared CI runner.
//
// A wall-clock ceiling on a test fails whenever the machine is slow (a cold runner, a busy neighbour, another architecture) and says nothing about
// the code. [expectWithin] always prints the measurement and enforces the ceiling only when DIDSA_ENFORCE_TIMING=1 (a developer's own machine, a
// benchmark job). What a test is really about is asserted by its other, deterministic expectations.
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';

bool get timingEnforced => Platform.environment['DIDSA_ENFORCE_TIMING'] == '1';

void expectWithin(num measured, num ceiling, String label, {String unit = 'ms'}) {
  // ignore: avoid_print
  print('TIMING $label: ${measured.toStringAsFixed(1)} $unit (ceiling $ceiling $unit, ${timingEnforced ? 'enforced' : 'reported only'})');
  if (timingEnforced) expect(measured, lessThan(ceiling), reason: label);
}
