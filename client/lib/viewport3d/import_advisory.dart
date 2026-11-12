/// The wording shown while a STEP / IGES / mesh file is being brought in: it says which step is running and that a large file takes a while,
/// so a long wait does not look like a hang. Pure, so it is unit tested.
class ImportAdvisory {
  ImportAdvisory._();

  /// "12.4 MB" / "340 KB".
  static String sizeText(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).ceil()} KB';
  }

  /// Step 1: the server reads the file to see what is in it (before anything is imported).
  static String reading(String fileName, int bytes) {
    final base = 'Reading $fileName (${sizeText(bytes)}) on the server...';
    return bytes >= _largeBytes ? '$base large CAD files can take a minute or more.' : base;
  }

  /// Step 2: the server builds the geometry (repairs surfaces, makes solids).
  static String importing(String fileName, int bytes) {
    final base = 'Importing $fileName (${sizeText(bytes)}): building the geometry...';
    return bytes >= _largeBytes ? '$base large CAD files can take a minute or more.' : base;
  }

  static const int _largeBytes = 2 * 1024 * 1024;
}
