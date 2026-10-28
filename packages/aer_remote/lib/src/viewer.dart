/// Where a viewer connects and what it must enforce. For the relay route
/// [host] is 127.0.0.1 (the engine's local port); for the direct route it
/// is the host's LAN address.
class ViewerTarget {
  const ViewerTarget({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.certPem,
    required this.certSha256,
    required this.clipboard,
  });

  final String host;
  final int port;
  final String username;
  final String password;

  /// The host's RDP certificate: a viewer must refuse any other.
  final String certPem;
  final String certSha256;

  /// The session's clipboard right; a viewer must not exchange the
  /// clipboard when false (gnome-remote-desktop cannot switch it off).
  final bool clipboard;
}

/// Platform adapter that shows a remote desktop (ADR-017): the built-in
/// FreeRDP viewer (M14.3) or an external client as a fallback
/// (Remmina/FreeRDP on Linux, mstsc on Windows). The engine never depends
/// on a particular one.
abstract interface class RemoteViewer {
  /// Short id: `embedded-freerdp`, `remmina`, `mstsc`.
  String get id;

  /// Whether this viewer can run here (library/binary present).
  Future<bool> available();

  /// Whether it pins [ViewerTarget.certSha256] itself. mstsc cannot: the
  /// UI then shows the fingerprint for a manual comparison.
  bool get pinsCertificate;

  /// Whether it can honour clipboard=false.
  bool get enforcesClipboard;

  Future<void> open(ViewerTarget target);

  Future<void> close();
}

/// A viewer that renders inside the app (the built-in one): the UI paints
/// [frameData] and forwards input; status and clipboard rules
/// stay in the engine.
abstract interface class InteractiveRemoteViewer implements RemoteViewer {
  /// BGRA frames (width, height, bytes, sequence).
  Stream<({int width, int height, List<int> bgra, int seq})> get frameData;

  Stream<String> get statusNames;

  /// connecting | connected | reconnecting | closed | failed
  String get statusName;

  String get lastError;

  /// The session's clipboard right (false: nothing is exchanged).
  bool get clipboardAllowed;

  /// Text the remote side copied (only with the clipboard right).
  Stream<String> get remoteClipboard;

  void mouse(int flags, int x, int y);

  void key(int scancode, bool down);

  /// Offers local text to the remote clipboard; false when not allowed.
  bool pushClipboard(String text);
}
