import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'device.dart';

abstract interface class ConnectStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Separate ProductName AER Connect and key; current-user DPAPI on Windows.
class ConnectSecureStore implements ConnectStore {
  ConnectSecureStore([this.key = profileKey]);
  static const profileKey = 'aer-connect.remote.profile.v1';

  /// AER Connect Anywhere device (ADR-018): number, both credentials, key.
  static const deviceKey = 'aer-connect.device.v2';
  final String key;
  final _store = const FlutterSecureStorage();
  @override
  Future<String?> read() => _store.read(key: key);
  @override
  Future<void> write(String value) => _store.write(key: key, value: value);
  @override
  Future<void> delete() => _store.delete(key: key);
}

typedef ViewerFactory = InteractiveRemoteViewer Function(
  Future<bool> Function(),
);

/// Server preset of an owner-built installer (`connect.json` next to the
/// EXE): address and certificate fingerprint, never a secret.
class ServerPreset {
  const ServerPreset(this.address, this.fingerprint);
  final String address, fingerprint;

  static ServerPreset? read(String path) {
    try {
      final j =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final a = (j['gateway'] as String? ?? '').trim();
      final f = (j['fingerprint'] as String? ?? '').trim();
      if (a.isEmpty || normalizeFingerprint(f).length != 64) return null;
      return ServerPreset(a, f);
    } catch (_) {
      return null;
    }
  }
}

class ConnectController extends ChangeNotifier {
  ConnectController({
    required this.store,
    required this.viewerFactory,
    GatewayClient Function(GatewayServer)? client,
    Future<String> Function(Uri)? probe,
    this.poll = const Duration(seconds: 2),
    ConnectStore? deviceStore,
    this.hostRuntime,
    HostTools? tools,
    this.preset,
  }) : _client = client ?? GatewayClient.new,
       _probe = probe ?? probeFingerprint,
       deviceStore = deviceStore ?? _NoDeviceStore(),
       tools = tools ?? HostTools();
  final ConnectStore store;

  /// AER Connect Anywhere (ADR-018).
  final ConnectStore deviceStore;
  final HostTools tools;
  final HostRuntimeFactory? hostRuntime;
  final ServerPreset? preset;
  DeviceProfile? device;
  HostView host = const HostView();
  HostRuntime? _runtime;
  StreamSubscription<HostView>? _hostSub;
  StreamSubscription<HostReply>? _replySub;
  Completer<String?>? _permanentReply;
  bool deviceRevoked = false;
  bool autostart = false;
  final ViewerFactory viewerFactory;
  final GatewayClient Function(GatewayServer) _client;
  final Future<String> Function(Uri) _probe;
  final Duration poll;
  GatewayClient? api;
  RemoteConnection? connection;
  InteractiveRemoteViewer? viewer;
  RemoteFilesClient? files;
  List<RemoteHostSummary> hosts = [];
  String address = '', fingerprint = '', clientName = '', hostName = '';
  String? error;
  String message = '';
  bool busy = false, paired = false, unauthorized = false;
  RemoteState state = RemoteState.disconnected;
  bool _disposed = false;
  int _generation = 0;
  StreamSubscription<ConnectionUpdate>? _updates;
  bool get live => connection != null && !state.terminal;
  DeviceTrust? trust;
  String trustError = '', identityFingerprint = '';

  Future<void> refreshTrust() async {
    if (device == null || api == null) return;
    try {
      trust = await api!.trust();
      trustError = '';
    } catch (e) {
      trust = null;
      trustError = describe(e);
    }
    changed();
  }

  Future<void> setUnattended(bool enabled) async {
    trust = await api!.setUnattended(enabled);
    trustError = '';
    changed();
  }

  Future<TrustedDevice> trustCandidate(String number) =>
      api!.trustCandidate(number);
  Future<void> grantTrust(TrustedDevice candidate) async {
    trust = await api!.grantTrust(candidate);
    trustError = '';
    changed();
  }

  Future<void> revokeTrust(String number) async {
    trust = await api!.revokeTrust(number);
    trustError = '';
    changed();
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final d = await deviceStore.read();
      if (d != null) {
        await _useDevice(
          DeviceProfile.fromJson(jsonDecode(d) as Map<String, dynamic>),
        );
        try {
          autostart = await tools.autostart();
        } catch (_) {}
        return;
      }
    } catch (_) {
      error = 'Не удалось прочитать защищённый профиль устройства. Удалите регистрацию и зарегистрируйте компьютер снова.';
      changed();
      return;
    }
    try {
      final raw = await store.read();
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final s = GatewayServer.parse(
        j['address'] as String,
        j['fingerprint'] as String,
      );
      final credential = j['credential'] as String;
      if (!credential.startsWith('aerc1.')) {
        throw const FormatException('Invalid client credential');
      }
      api = _client(s)..credential = credential;
      address = s.base.toString();
      fingerprint = j['fingerprint'] as String;
      clientName = j['name'] as String;
      paired = true;
      await refresh();
    } catch (_) {
      error = 'Не удалось прочитать защищённый профиль. Удалите сервер и сопрягите заново.';
    } finally {
      changed();
    }
  }

  Future<String> probe(String address) =>
      _probe(GatewayServer.parse(address, '').base);

  // ---- AER Connect Anywhere: this computer as a device ----

  Future<void> _useDevice(DeviceProfile d) async {
    trust = null;
    trustError = '';
    identityFingerprint = '';
    device = d;
    final s = GatewayServer.parse(d.address, d.fingerprint);
    api?.close();
    api = _client(s)..credential = d.clientCredential;
    address = s.base.toString();
    fingerprint = d.fingerprint;
    clientName = d.name;
    paired = true;
    unauthorized = false;
    deviceRevoked = false;
    changed();
    await _startHost();
    await refresh();
    identityFingerprint = await installationFingerprint(d.boxKey);
    await refreshTrust();
  }

  Future<void> _startHost() async {
    await _stopHost();
    final d = device;
    if (d == null) return;
    final factory = hostRuntime;
    if (factory == null && !tools.hostAvailable) {
      host = const HostView(
        link: HostLink.unavailable,
        error:
            'Входящие подключения недоступны: в установке нет компонента Host.',
      );
      changed();
      return;
    }
    final r = factory != null ? factory() : ProcessHostRuntime(tools);
    _runtime = r;
    _hostSub = r.updates.listen((v) {
      host = v;
      if (v.link == HostLink.revoked) deviceRevoked = true;
      changed();
    });
    _replySub = r.replies.listen((m) {
      if (m.type != 'permanent') return;
      final p = _permanentReply;
      _permanentReply = null;
      final v = m.data['verifier'];
      if (v is Map) {
        d.permanent = v.cast<String, Object?>();
        unawaited(_saveDevice());
        p?.complete(null);
      } else {
        p?.complete(m.data['problem'] as String? ?? 'Пароль не принят');
      }
    });
    await r.start(d.hostInit(tools.stateDir, tools.shadowExe));
  }

  Future<void> _stopHost() async {
    final r = _runtime;
    _runtime = null;
    await _hostSub?.cancel();
    await _replySub?.cancel();
    _hostSub = _replySub = null;
    await r?.stop();
  }

  Future<void> _saveDevice() async {
    final d = device;
    if (d != null) await deviceStore.write(jsonEncode(d.toJson()));
  }

  /// Registers this computer with the owner's enrollment code: one device
  /// key and install id are created here, credentials arrive once.
  Future<void> enroll(
    String address,
    String pin,
    String code,
    String name,
  ) async {
    final server = GatewayServer.parse(address, pin);
    final next = _client(server);
    try {
      final key = await tools.keygen();
      final installId = HostTools.newInstallId();
      final e = await next.enroll(
        code: code,
        deviceName: name.trim().isEmpty ? Platform.localHostname : name.trim(),
        boxPub: key.publicKey,
        instance: await tools.instance(installId),
      );
      final d = DeviceProfile(
        address: server.base.toString(),
        fingerprint: pin,
        deviceId: e.deviceId,
        number: e.number,
        name: e.name,
        agentToken: e.agentToken,
        clientCredential: e.clientCredential,
        boxKey: key.privateKey,
        installId: installId,
      );
      await deviceStore.write(jsonEncode(d.toJson()));
      next.close();
      await _useDevice(d);
    } catch (_) {
      next.close();
      rethrow;
    } finally {
      changed();
    }
  }

  void rotatePassword() => _runtime?.send({'cmd': 'rotate'});

  /// Turns the permanent password on or changes it; returns a problem text
  /// when the password is too weak. Only the verifier is stored.
  Future<String?> setPermanent(String password) async {
    final r = _runtime;
    if (r == null) return 'Компонент входящих подключений не запущен';
    _permanentReply?.complete('Отменено');
    final c = _permanentReply = Completer<String?>();
    r.send({'cmd': 'setPermanent', 'password': password});
    return c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => 'Нет ответа от компонента входящих подключений',
    );
  }

  Future<void> clearPermanent() async {
    device?.permanent = null;
    await _saveDevice();
    _runtime?.send({'cmd': 'clearPermanent'});
    changed();
  }

  Future<void> setIncoming(bool on) async {
    device?.allowIncoming = on;
    await _saveDevice();
    _runtime?.send({'cmd': 'allowIncoming', 'value': on});
    changed();
  }

  /// Ends the incoming session at once (the remote side loses the screen).
  void stopIncoming() => _runtime?.send({'cmd': 'stopSession'});

  /// Changes a host permission; the host restarts (never mid-session).
  Future<void> setHostOptions({
    bool? clipboard,
    bool? files,
    String? filesDir,
    bool? viewOnly,
  }) async {
    final d = device;
    if (d == null) return;
    if (host.session != null) {
      error = 'Сначала остановите текущее входящее подключение';
      changed();
      return;
    }
    d.clipboard = clipboard ?? d.clipboard;
    d.files = files ?? d.files;
    d.filesDir = filesDir ?? d.filesDir;
    d.viewOnly = viewOnly ?? d.viewOnly;
    await _saveDevice();
    await _startHost();
    changed();
  }

  Future<void> setAutostart(bool on) async {
    try {
      await tools.setAutostart(on);
      autostart = await tools.autostart();
    } catch (e) {
      error = describe(e);
    }
    changed();
  }

  /// Connects to another computer by its ID and password.
  Future<void> connectById(String number, String password) async {
    if (busy || live || api == null) return;
    final n = normalizeDeviceNumber(number);
    if (!validDeviceNumber(n)) {
      error = 'ID компьютера — 9 цифр';
      changed();
      return;
    }
    if (password.isEmpty) {
      error = 'Введите пароль удалённого компьютера';
      changed();
      return;
    }
    busy = true;
    error = null;
    hostName = 'ID ${formatDeviceNumber(n)}';
    final generation = ++_generation;
    state = RemoteState.pending;
    message = 'Проверяем пароль…';
    changed();
    final current = api!;
    final conn = RemoteConnection(current, poll: poll);
    connection = conn;
    _updates = conn.updates.listen((u) {
      if (generation != _generation) return;
      state = u.state;
      message = u.state == RemoteState.awaitingApproval
          ? 'Ждём подтверждения на удалённом компьютере…'
          : u.message;
      if (u.state.terminal) unawaited(_release());
      changed();
    });
    try {
      await conn.startWith(() async {
        final ch = await current.challenge(n);
        hostName = ch.name.isEmpty
            ? 'ID ${formatDeviceNumber(n)}'
            : '${ch.name} · ${formatDeviceNumber(n)}';
        changed();
        return current.connectDevice(
          await sealPassword(ch, password, installationKey: device?.boxKey),
        );
      });
      if (generation != _generation) {
        await conn.end();
        return;
      }
      _openFiles();
      await _show();
    } catch (e) {
      if (generation == _generation) {
        error = describe(e);
        message = error!;
        state = RemoteState.failed;
        await _release();
        connection = null;
        await conn.end();
      }
    } finally {
      if (generation == _generation) busy = false;
      changed();
    }
  }

  /// Removes this computer's registration from this installation. The
  /// owner can revoke it on the server; a new registration gets a new ID.
  Future<void> forgetDevice() async {
    await end();
    await _stopHost();
    await deviceStore.delete();
    device = null;
    host = const HostView();
    api?.close();
    api = null;
    hosts = [];
    paired = false;
    deviceRevoked = false;
    address = '';
    fingerprint = '';
    error = null;
    changed();
  }

  Future<void> pair(String address, String pin, String code) async {
    final server = GatewayServer.parse(address, pin);
    final next = _client(server);
    try {
      final r = await next.pair(
        code.trim(),
        deviceName: 'AER Connect (${Platform.localHostname})',
      );
      await store.write(
        jsonEncode({
          'address': server.base.toString(),
          'fingerprint': pin,
          'name': r.name,
          'credential': r.credential,
        }),
      );
      api?.close();
      api = next;
      this.address = server.base.toString();
      fingerprint = pin;
      clientName = r.name;
      paired = true;
      unauthorized = false;
      await refresh();
    } catch (_) {
      next.close();
      rethrow;
    } finally {
      changed();
    }
  }

  Future<void> refresh() async {
    final current = api;
    if (current == null) return;
    try {
      hosts = await current.hosts();
      error = null;
    } catch (e) {
      error = describe(e);
      if (e is RemoteEngineException && e.unauthorized && device != null) {
        deviceRevoked = true;
        error = 'Регистрация этого компьютера отозвана владельцем сервера.';
        await _release();
        hosts = [];
      } else if (e is RemoteEngineException && e.unauthorized) {
        unauthorized = true;
        hosts = [];
        await _release();
        state = RemoteState.revoked;
        message = 'Доступ отозван владельцем';
      }
    } finally {
      changed();
    }
  }

  Future<void> connect(RemoteHostSummary host) async {
    if (busy || live || api == null) return;
    busy = true;
    error = null;
    hostName = host.name;
    final generation = ++_generation;
    state = RemoteState.pending;
    message = 'Запрашиваем сеанс…';
    changed();
    final conn = RemoteConnection(api!, poll: poll);
    connection = conn;
    _updates = conn.updates.listen((u) {
      if (generation != _generation) return;
      state = u.state;
      message = u.message;
      if (u.state.terminal) {
        unawaited(_release());
        if (u.state == RemoteState.revoked) unauthorized = true;
      }
      changed();
    });
    try {
      await conn.start(host.entityId);
      if (generation != _generation) {
        await conn.end();
        return;
      }
      _openFiles();
      await _show();
    } catch (e) {
      if (generation == _generation) {
        error = describe(e);
        message = error!;
        state = RemoteState.failed;
        await _release();
        await conn.end();
      }
    } finally {
      if (generation == _generation) busy = false;
      changed();
    }
  }

  void _openFiles() {
    final conn = connection!, grant = conn.grant!;
    if (grant.files && conn.files != null) {
      files = RemoteFilesClient(
        baseUrl: 'https://127.0.0.1:${conn.files!.port}',
        token: grant.filesToken!,
        certSha256: grant.certSha256,
      );
    }
  }

  Future<void> _show() async {
    final conn = connection!, g = conn.grant!, current = api!;
    final v = viewerFactory(() async {
      try {
        return !(await current.session(conn.session!.id)).state.terminal;
      } catch (_) {
        return false;
      }
    });
    viewer = v;
    await v.open(
      ViewerTarget(
        host: '127.0.0.1',
        port: conn.rdp!.port,
        username: g.username,
        password: g.password,
        certPem: g.certPem,
        certSha256: g.certSha256,
        clipboard: g.clipboard,
      ),
    );
  }

  Future<void> _release() async {
    final v = viewer;
    viewer = null;
    files?.close();
    files = null;
    connection?.rdp?.drop();
    changed();
    await v?.close();
  }

  Future<void> reconnect() async {
    if (!live || connection?.grant == null || busy) return;
    busy = true;
    changed();
    try {
      await _release();
      _openFiles();
      await _show();
      error = null;
    } catch (e) {
      error = describe(e);
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> end() async {
    ++_generation;
    final conn = connection;
    connection = null;
    await _updates?.cancel();
    _updates = null;
    await _release();
    await conn?.end();
    state = RemoteState.disconnected;
    busy = false;
    message = 'Сеанс завершён';
    changed();
  }

  Future<void> forget() async {
    await end();
    await store.delete();
    api?.close();
    api = null;
    hosts = [];
    paired = false;
    unauthorized = false;
    address = '';
    fingerprint = '';
    error = null;
    changed();
  }

  Future<void> shutdown() async {
    await end();
    await _stopHost();
    api?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  static String describe(Object e) => switch (e) {
    PinMismatchException() || HandshakeException() => 'Сертификат не совпадает с закреплённым — подключение запрещено. Сверьте отпечаток в AER HOME.',
    RemoteEngineException(reason: 'bad_password') => 'Неверный пароль.',
    RemoteEngineException(reason: 'unknown_device') =>
      'Компьютер с таким ID не найден. Проверьте цифры.',
    RemoteEngineException(reason: 'offline') =>
      'Компьютер не в сети: он выключен или AER Connect на нём не запущен.',
    RemoteEngineException(reason: 'busy') =>
      'К этому компьютеру уже подключаются. Повторите позже.',
    RemoteEngineException(reason: 'incoming_disabled') =>
      'На удалённом компьютере выключены входящие подключения.',
    RemoteEngineException(reason: 'locked' || 'host_locked') => 'Слишком много неверных паролей — вход к этому компьютеру временно закрыт.',
    RemoteEngineException(reason: 'self') => 'Это ID этого компьютера.',
    RemoteEngineException(reason: 'bad_code') => 'Код неверен, истёк или уже использован. Получите новый код у владельца сервера.',
    RemoteEngineException(reason: 'timeout') =>
      'Удалённый компьютер не ответил вовремя.',
    RemoteEngineException(status: 401) => 'Учётные данные не приняты: код неверен или доступ отозван. Нужно новое сопряжение.',
    RemoteEngineException(status: 429) =>
      'Слишком много попыток. Повторите позже.',
    RemoteEngineException(:final message) => message,
    SocketException() ||
    TimeoutException() => 'Сервер недоступен. Проверьте адрес и соединение.',
    FormatException() => 'Проверьте адрес сервера и отпечаток сертификата.',
    StateError(:final message) => message,
    _ => 'Не удалось выполнить действие. Проверьте соединение и повторите.',
  };
}

class _NoDeviceStore implements ConnectStore {
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String value) async => _v = value;
  @override
  Future<void> delete() async => _v = null;
}
