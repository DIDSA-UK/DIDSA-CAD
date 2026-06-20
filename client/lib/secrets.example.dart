// Template for the gitignored lib/secrets.dart that this app imports for
// its real configuration. To set up local/dev credentials:
//
//   1. Copy this file to lib/secrets.dart (same directory).
//   2. Fill in the real apiKey value below (matches the backend's
//      CAD_API_KEY environment variable - see backend/app/auth.py).
//   3. Leave apiBaseUrlOverride as null to talk to the production backend,
//      or set it to e.g. 'http://localhost:8000' for local development.
//
// lib/secrets.dart is listed in .gitignore and must never be committed.

/// The shared static API key sent as the `X-API-Key` header on every
/// backend request.
const String apiKey = 'REPLACE_WITH_REAL_API_KEY';

/// Optional override of the backend base URL. Leave null to use the
/// production URL defined in lib/config.dart.
const String? apiBaseUrlOverride = null;
