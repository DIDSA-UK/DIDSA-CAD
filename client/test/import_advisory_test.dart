import 'package:didsa_cad_client/viewport3d/import_advisory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sizes read as KB below a megabyte and MB above', () {
    expect(ImportAdvisory.sizeText(340 * 1024), '340 KB');
    expect(ImportAdvisory.sizeText(18174808), '17.3 MB');
  });

  test('a small file just names the step', () {
    expect(ImportAdvisory.reading('Part1.IGS', 68798), 'Reading Part1.IGS (68 KB) on the server...');
    expect(ImportAdvisory.importing('Part1.IGS', 68798), 'Importing Part1.IGS (68 KB): building the geometry...');
  });

  test('a large file also says it can take a minute or more', () {
    expect(ImportAdvisory.reading('big.igs', 18174808), contains('can take a minute or more'));
    expect(ImportAdvisory.importing('big.igs', 18174808), contains('17.3 MB'));
    expect(ImportAdvisory.importing('big.igs', 18174808), contains('can take a minute or more'));
  });
}
