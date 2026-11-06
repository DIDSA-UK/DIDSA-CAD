import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/viewport3d/view_preferences.dart';

void main() {
  test('bodies start 60% transparent (40% opaque) in the 3D sketch view, apart from the Part view setting', () {
    expect(kSketchEntryBodyOpacity, 0.40);
    expect(kSketchEntryBodyOpacity, lessThan(1.0));
    // The Part view's own stored default is untouched by the sketch view.
    expect(ViewPreferences.defaultBodyOpacity, 1.0);
  });
}
