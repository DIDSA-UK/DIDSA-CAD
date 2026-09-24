import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_part_naming.dart';

/// Multi-part/assembly overhaul, Phase C
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`):
/// [nextAvailablePartName]'s own collision-avoidance logic.
void main() {
  test('with no existing files, returns sequence 1, zero-padded to 3 digits', () {
    expect(nextAvailablePartName(const [], typePrefix: 'PLATE'), 'PLATE_001');
  });

  test('skips past the highest existing sequence number for the same prefix', () {
    final existing = ['PLATE_001.DIDSAprt', 'PLATE_002.DIDSAprt', 'TUBE_001.DIDSAprt'];
    expect(nextAvailablePartName(existing, typePrefix: 'PLATE'), 'PLATE_003');
    expect(nextAvailablePartName(existing, typePrefix: 'TUBE'), 'TUBE_002');
  });

  test('a gap in the sequence is not reused - always the max + 1, never the lowest free slot', () {
    final existing = ['PLATE_001.DIDSAprt', 'PLATE_003.DIDSAprt'];
    expect(nextAvailablePartName(existing, typePrefix: 'PLATE'), 'PLATE_004');
  });

  test('prefix matching is case-insensitive', () {
    final existing = ['plate_005.DIDSAprt'];
    expect(nextAvailablePartName(existing, typePrefix: 'PLATE'), 'PLATE_006');
  });

  test('ignores files under a different prefix, files in subdirectories, and non-sequenced names', () {
    final existing = ['subdir/PLATE_002.DIDSAprt', 'notes.txt', 'MyPart.DIDSAprt', 'BRACKET_009.DIDSAprt'];
    expect(nextAvailablePartName(existing, typePrefix: 'PLATE'), 'PLATE_003');
  });

  test('sanitizes a loosely-formatted LLM-proposed prefix into a clean, conventional one', () {
    expect(nextAvailablePartName(const [], typePrefix: 'mounting plate'), 'MOUNTING_PLATE_001');
    expect(nextAvailablePartName(const [], typePrefix: '  shs-tube  '), 'SHS_TUBE_001');
  });

  test('padWidth is configurable', () {
    expect(nextAvailablePartName(const [], typePrefix: 'PLATE', padWidth: 4), 'PLATE_0001');
  });

  test('a double-digit-or-more existing sequence is still found correctly (no lexicographic-only comparison)', () {
    final existing = ['PLATE_009.DIDSAprt', 'PLATE_010.DIDSAprt'];
    expect(nextAvailablePartName(existing, typePrefix: 'PLATE'), 'PLATE_011');
  });
}
