import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/config.dart';

/// [ApiConfig.localApiKey] round-trip tests - added alongside the Server
/// Management "Use Local Server" button (connection_screen.dart), which
/// reads this value rather than [ApiConfig.apiKey] specifically because the
/// latter can point at a different, remote server by the time anything
/// reads it back. `shared_preferences` mocked the same way
/// `gear_preset_store_test.dart`'s own setUp does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('localApiKey starts empty before anything has been saved', () async {
    await ApiConfig.load();
    expect(ApiConfig.localApiKey, isEmpty);
  });

  test('saveLocalApiKey persists independently of save (baseUrl/apiKey)', () async {
    await ApiConfig.load();
    await ApiConfig.save(baseUrl: 'https://cad-api.snail-shell.uk', apiKey: 'remote-key');
    await ApiConfig.saveLocalApiKey('local-key');

    expect(ApiConfig.apiKey, 'remote-key');
    expect(ApiConfig.localApiKey, 'local-key');

    // Simulate a fresh app session - shared_preferences (the mock) still
    // holds both values, independently of each other.
    await ApiConfig.load();
    expect(ApiConfig.apiKey, 'remote-key');
    expect(ApiConfig.localApiKey, 'local-key');
  });

  test('saveLocalApiKey does not change apiKey/baseUrl, and vice versa', () async {
    await ApiConfig.load();
    await ApiConfig.saveLocalApiKey('local-key');
    expect(ApiConfig.apiKey, isEmpty);
    expect(ApiConfig.baseUrl, isEmpty);

    await ApiConfig.save(baseUrl: 'https://cad-api.snail-shell.uk', apiKey: 'remote-key');
    expect(ApiConfig.localApiKey, 'local-key');
  });
}
