import 'dart:io';

/// Where the desktop client finds Core and its API token.
///
/// Overrides (no secrets in code or config files):
/// * `AER_CORE_URL` — Core base URL, default `http://127.0.0.1:8787`.
/// * `AER_CORE_TOKEN_FILE` — token file, default is the local Core data dir,
///   matching core/internal/foundation/config.
class CoreEndpoint {
  const CoreEndpoint({required this.baseUri, required this.tokenFile});

  factory CoreEndpoint.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final url = e['AER_CORE_URL'];
    return CoreEndpoint(
      baseUri: Uri.parse(url == null || url.isEmpty ? defaultUrl : url),
      tokenFile: e['AER_CORE_TOKEN_FILE'] ?? _defaultTokenFile(e),
    );
  }

  static const defaultUrl = 'http://127.0.0.1:8787';

  final Uri baseUri;

  /// Null when no sensible default exists (no HOME / LOCALAPPDATA).
  final String? tokenFile;

  /// Reads the token file; null if it does not exist yet.
  Future<String?> readToken() async {
    final path = tokenFile;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return (await file.readAsString()).trim();
  }

  static String? _defaultTokenFile(Map<String, String> e) {
    String join(List<String> parts) => parts.join(Platform.pathSeparator);
    if (Platform.isWindows) {
      final local = e['LOCALAPPDATA'];
      return local == null
          ? null
          : join([local, 'aer-home', 'core', 'core.token']);
    }
    final xdg = e['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return join([xdg, 'aer-home', 'core', 'core.token']);
    }
    final home = e['HOME'];
    return home == null
        ? null
        : join([home, '.local', 'share', 'aer-home', 'core', 'core.token']);
  }
}
