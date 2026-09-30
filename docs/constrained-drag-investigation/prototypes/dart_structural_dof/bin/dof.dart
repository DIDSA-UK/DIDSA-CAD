import 'dart:convert';
import 'dart:io';
import 'package:didsa_probe/api/sketch_api_client.dart';
import 'package:didsa_probe/sketch/dof_analysis.dart';

void main(List<String> args) {
  final data = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final out = <String, dynamic>{};
  for (final entry in data.entries) {
    final s = entry.value as Map<String, dynamic>;
    final points = (s['points'] as Map<String, dynamic>).keys.toList();
    final lines = s['lines'] as Map<String, dynamic>;
    final constraints = [for (final c in s['constraints'] as List) ConstraintDto.fromJson(c as Map<String, dynamic>)];
    final rig = SketchRigidity.analyze(
      pointIds: points,
      fixedPointIds: {s['origin'] as String},
      lineStartPointId: {for (final e in lines.entries) e.key: (e.value as List)[0] as String},
      lineEndPointId: {for (final e in lines.entries) e.key: (e.value as List)[1] as String},
      constraints: constraints,
    );
    out[entry.key] = {
      for (final p in points)
        p: {
          'fully': rig.isPointFullyConstrained(p),
          'over': rig.isPointOverConstrained(p),
          'grounded': rig.isPointGrounded(p),
          'pinned': rig.isPointPinned(p),
        }
    };
  }
  stdout.write(jsonEncode(out));
}
