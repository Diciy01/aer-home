/// An error answer of the Gateway (or Core behind it).
class RemoteEngineException implements Exception {
  const RemoteEngineException(this.status, this.code, this.message);

  /// HTTP status; 0 when the server was not reached.
  final int status;

  /// Machine code from the error envelope (UNAUTHORIZED, CONFLICT, …).
  final String code;
  final String message;

  /// The credential is wrong, revoked or the address is banned: pairing
  /// again is the only way forward.
  bool get unauthorized => status == 401;

  bool get rateLimited => status == 429;

  @override
  String toString() => 'RemoteEngineException($status $code: $message)';
}

/// The server's certificate is not the pinned one. Never retried.
class PinMismatchException implements Exception {
  const PinMismatchException(this.expected, this.actual);
  final String expected;
  final String actual;

  @override
  String toString() =>
      'PinMismatchException: сертификат сервера не совпадает с закреплённым';
}
