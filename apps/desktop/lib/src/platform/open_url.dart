import 'dart:io';

/// Opens an http(s) link in the system browser. Other schemes are refused:
/// a link from configuration must never start an arbitrary program.
typedef UrlOpener = Future<bool> Function(Uri uri);

Future<bool> openExternalUrl(Uri uri) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  try {
    final r = switch (Platform.operatingSystem) {
      'windows' => await Process.run('rundll32', [
        'url.dll,FileProtocolHandler',
        uri.toString(),
      ]),
      'macos' => await Process.run('open', [uri.toString()]),
      _ => await Process.run('xdg-open', [uri.toString()]),
    };
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  }
}
